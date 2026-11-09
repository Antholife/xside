import AppKit
import IOKit.ps
import os
import XSideCore

/// Keeps installed apps alive without user action: polls devices, starts the refreshes
/// `RefreshPlanner` says are due, and notifies a failure once per (app, device, cause).
@MainActor
final class BackgroundEngine {
    private static let logger = Log("engine")
    /// Device polling while the popover is open / closed.
    static let fastPoll: Duration = .seconds(15)
    static let slowPoll: Duration = .seconds(60)
    /// Periodic due evaluation (also run on device changes and on wake).
    static let evaluationInterval: Duration = .seconds(5 * 60)
    /// Hidden debug setting (days): `defaults write io.github.xside.XSide debugThresholdDays 7`
    /// (`io.github.xside.XSide.debug` for the debug bundle).
    static let debugThresholdKey = "debugThresholdDays"

    private let model: AppModel
    private let notifier: Notifier
    private let gateStore: NotificationGateStore
    private var gate: NotificationGate
    private var successGate = SuccessNotificationGate()
    private var unreachable = UnreachableTracker()
    private var started = false
    private var tasks: [Task<Void, Never>] = []
    private var wakeObserver: NSObjectProtocol?
    private var lastPoll = ContinuousClock.now
    /// The expiry reminders were reconciled with the library once since launch.
    private var remindersReconciled = false
    /// Periodic ticks since the last reconciliation (redone hourly: notifications may have been
    /// allowed since, or the clock changed).
    private var ticksSinceReconcile = 0

    init(model: AppModel) {
        self.model = model
        notifier = Notifier(developerDir: { [weak model] in model?.lastKnownDeveloperDir })
        gateStore = NotificationGateStore(libraryRoot: model.library.root)
        gate = gateStore.load()
    }

    /// Idempotent: the first call wires everything, later calls do nothing.
    func start() {
        guard !started else { return }
        started = true
        Self.logger.notice("engine started (threshold \(Self.threshold / 86_400) d)")
        notifier.start()
        announceInstalledUpdate()
        // At launch too, a minute later: past Sparkle's own start, and the login rush.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.model.updater.checkSoon("launch") }
        model.updater.onAvailable = { [weak self] version in
            guard let self else { return }
            Task { await self.notifier.updateAvailable(version: version) }
        }
        #if DEBUG
        // Debug-only: XSIDE_TEST_NOTIFICATIONS=1 posts a refresh failure about the first app, then
        // its expiry reminder a minute later, to try their buttons.
        if ProcessInfo.processInfo.environment["XSIDE_TEST_NOTIFICATIONS"] == "1" {
            Task { [weak self] in
                await NotificationPermission().request()
                try? await Task.sleep(for: .seconds(4))
                guard let self, let record = self.model.records.first,
                      let installation = record.installations.first else { return }
                let job = RefreshJob(recordID: record.id, deviceID: installation.deviceID)
                _ = await self.notifier.refreshFailed(appName: Self.appName(record), errorKey: XSideError.deviceUnavailable.key,
                                                      message: XSideError.deviceUnavailable.localizedMessage,
                                                      job: job, id: "test.failure")
                await self.notifier.scheduleExpiryReminder(recordID: record.id, deviceID: installation.deviceID,
                                                           appName: Self.appName(record), deviceName: "iPhone",
                                                           expiresAt: Date().addingTimeInterval(86_400 + 60))
            }
        }
        #endif

        model.onNeedsEvaluation = { [weak self] in self?.evaluate(reason: "change") }
        model.onPopoverShown = { [weak self] in self?.checkPresence(interval: PresenceCheck.panelInterval) }
        model.onDeviceRemoved = { [weak self] id in self?.forgetDevice(id) }
        model.onDeviceNotificationsChanged = { [weak self] in self?.reconcileReminders() }
        model.onInstallationRemoved = { [weak self] job in self?.forgetInstallation(job) }
        model.onRefreshResumed = { [weak self] job in self?.refreshResumed(job) }
        // Allowed only now (journey, Settings): the reminders couldn't be scheduled before.
        NotificationPermission.onBecameAuthorized = { [weak self] in self?.reconcileReminders() }
        model.onCrashFound = { [weak self] key, flag in self?.notifyCrash(key, flag: flag) }
        model.onJobFinished = { [weak self] job, error, automatic, wasRefresh in
            self?.jobFinished(job, error: error, automatic: automatic, wasRefresh: wasRefresh)
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }

        // Ticks every 15 s; lists devices every tick while the popover is open, every 60 s otherwise.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.fastPoll)
                await self?.pollTick()
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.evaluationInterval)
                self?.periodicTick()
            }
        })
    }

    /// Settings > General "Refresh … before it expires" (default 2 days), or the hidden debug override.
    static var threshold: TimeInterval {
        RefreshPlanner.threshold(daysBefore: UserDefaults.standard.integer(forKey: refreshDaysBeforeKey),
                                 debugDays: UserDefaults.standard.double(forKey: debugThresholdKey))
    }
    static let refreshDaysBeforeKey = "refreshDaysBefore"
    static let pausedUntilKey = "refreshPausedUntil"
    static let acOnlyKey = "refreshOnACOnly"
    static let preferredHoursKey = "refreshPreferredHours"

    /// Settings > General "Automatic refreshes".
    static var policy: RefreshPolicy {
        let defaults = UserDefaults.standard
        let paused = defaults.double(forKey: pausedUntilKey) // seconds since 1970, 0: not paused
        return RefreshPolicy(pausedUntil: paused > 0 ? Date(timeIntervalSince1970: paused) : nil,
                             acOnly: defaults.bool(forKey: acOnlyKey),
                             onBattery: onBattery,
                             preferredHours: defaults.string(forKey: preferredHoursKey).flatMap(RefreshPolicy.Hours.init))
    }

    /// The Mac runs on battery (a desktop Mac never does).
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }

    // MARK: - Triggers

    private func pollTick() async {
        // The crash logs' own schedule (every 2 min, 15 s after an install or a check-in).
        model.scanCrashesIfDue()
        let interval = model.isPopoverOpen ? Self.fastPoll : Self.slowPoll
        // Small tolerance so a 60 s poll isn't pushed to 75 s by tick jitter.
        guard ContinuousClock.now - lastPoll >= interval - .seconds(1) else { return }
        lastPoll = .now
        await model.listDevices() // a change calls `evaluate` through `onNeedsEvaluation`
    }

    private func periodicTick() {
        model.updateAttention() // an app may have expired since the last change
        ticksSinceReconcile += 1
        if ticksSinceReconcile * Int(Self.evaluationInterval.components.seconds) >= 3600 { reconcileReminders() }
        // Re-check the signing environment every tick: a break (Xcode removed, signed out,
        // certificate deleted) is reported within minutes, and a fix in Xcode is picked up by itself.
        model.recheckEnvironment()
        evaluate(reason: "timer")
    }

    private func didWake() {
        Self.logger.notice("wake: re-listing devices")
        Task {
            await model.listDevices()
            lastPoll = .now
            evaluate(reason: "wake")
        }
    }

    // MARK: - Evaluation

    private func dueJobs() -> [RefreshJob] {
        RefreshPlanner.dueJobs(model.records, devices: model.devices, now: Date(), threshold: Self.threshold,
                               prefs: model.devicePrefs, currentIdentitySHA1: model.signingEnvironment?.identitySHA1,
                               currentTeamID: model.signingEnvironment?.teamID)
            .filter { !model.removingDevices.contains($0.deviceID) }
    }

    private func evaluate(reason: String) {
        // A pause of one app for a while that is over (device feedback 3, E5): resumed, which
        // evaluates again through `onRefreshResumed`.
        if model.records.contains(where: { $0.installations.contains { $0.refreshPaused && ($0.pausedUntil ?? .distantFuture) <= Date() } }) {
            Task { await model.resumeEndedPauses() }
        }
        // The first evaluation comes after the library is loaded (see `AppModel.start`).
        if !remindersReconciled {
            remindersReconciled = true
            reconcileReminders()
        }
        reportEnvironment()
        reportMacBeta()
        checkPresence()
        model.scanCrashesIfDue()
        reportUnreachable()
        reportNeedsUSB()
        // Environment broken (or not probed yet): nothing can be refreshed. `reportEnvironment`
        // already notifies each problem once; no per-app notification on top of it.
        guard case .success? = model.environment else { return }
        let startable = RefreshPlanner.startable(dueJobs(), busy: model.busyJobs)
        // Settings may hold them back (pause, battery, preferred hours), never past `urgent`.
        let policy = Self.policy
        let now = Date()
        let due = startable.filter { job in
            guard let installation = model.records.first(where: { $0.id == job.recordID })?
                .installations.first(where: { $0.deviceID == job.deviceID }) else { return true }
            let changed = RefreshPlanner.certificateChanged(installation, currentIdentitySHA1: model.signingEnvironment?.identitySHA1,
                                                            currentTeamID: model.signingEnvironment?.teamID)
            return policy.allows(expiresAt: installation.expiresAt, now: now, certificateChanged: changed)
        }
        if due.count < startable.count {
            Self.logger.notice("\(reason): \(startable.count - due.count) job(s) held back by the settings")
        }
        guard !due.isEmpty else { return }
        Self.logger.notice("\(reason): \(due.count) job(s) due")
        for job in due where model.refreshNow(job, automatic: true) {
            Self.logger.notice("refresh started \(job.recordID.uuidString) on \(job.deviceID)")
        }
    }

    /// Due installations whose device stays unreachable can't be attempted: record the attempt
    /// (row hint, 30-min cadence) and notify once, so the app never expires silently.
    private func reportUnreachable() {
        let now = Date()
        let jobs = RefreshPlanner.startable(
            unreachable.evaluate(model.records, devices: model.devices, now: now, threshold: Self.threshold),
            busy: model.busyJobs)
            .filter { !model.removingDevices.contains($0.deviceID) }
        for job in jobs {
            Self.logger.notice("device unreachable for due \(job.recordID.uuidString) on \(job.deviceID)")
            Task {
                guard await model.recordUnreachable(job, at: now) else { return }
                let error = XSideError.deviceUnavailable
                notifyFailure(job, errorKey: error.key, message: error.localizedMessage)
            }
        }
    }

    /// Due installations whose device is on Wi-Fi only with Wi-Fi refresh off: nothing can be
    /// attempted, so ask once (gate key `needsUSB`) for a USB cable before the app expires.
    private func reportNeedsUSB() {
        let jobs = RefreshPlanner.blockedByWifiPref(
            model.records, devices: model.devices, now: Date(), threshold: Self.threshold, prefs: model.devicePrefs)
            .filter { !model.removingDevices.contains($0.deviceID) && !model.busyJobs.contains($0) }
        for job in jobs { notifyNeedsUSB(job) }
    }

    private func notifyNeedsUSB(_ job: RefreshJob) {
        guard model.devicePrefs.notifies(job.deviceID), let record = model.records.first(where: { $0.id == job.recordID }),
              let installation = record.installations.first(where: { $0.deviceID == job.deviceID }) else { return }
        let deviceName = deviceName(job.deviceID)
        let date = installation.expiresAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted).locale(appLocale))
        Task {
            guard await notifier.canDeliver() else { return }
            guard gate.shouldNotify(recordID: job.recordID, deviceID: job.deviceID, errorKey: Self.needsUSBKey) else { return }
            persistGate()
            let posted = await notifier.needsUSB(appName: Self.appName(record), deviceName: deviceName, date: date,
                                                 id: "refresh.\(job.recordID.uuidString).\(job.deviceID)")
            if !posted {
                gate.forget(recordID: job.recordID, deviceID: job.deviceID, errorKey: Self.needsUSBKey)
                persistGate()
            }
        }
    }

    static let needsUSBKey = "needsUSB"

    /// The version XSide last ran as: a different one at launch is an update just installed.
    static let lastLaunchedVersionKey = "lastLaunchedVersion"

    /// XSide was just updated (by Sparkle, or by hand): "XSide x.y was installed". Not on a first
    /// install (nothing ran before).
    private func announceInstalledUpdate() {
        let defaults = UserDefaults.standard
        let current = Bundle.main.shortVersion ?? ""
        let previous = defaults.string(forKey: Self.lastLaunchedVersionKey)
        defaults.set(current, forKey: Self.lastLaunchedVersionKey)
        guard let previous, previous != current, !current.isEmpty,
              defaults.bool(forKey: JourneyStep.completedKey) else { return }
        Self.logger.notice("updated from \(previous) to \(current)")
        Task { await notifier.updateInstalled(version: current) }
    }

    /// Environment problems already notified (their keys), each cleared once it's fixed.
    static let environmentWarnedKey = "environmentWarnedErrors"
    /// When each warned problem was last seen fixed: it's forgotten (and can be notified again)
    /// only once it stayed fixed this long. Xcode can drop its account, list it again for a
    /// moment, then drop it again: one notification, not one per flicker.
    static let environmentFixedSinceKey = "environmentFixedSince"
    static let environmentSettleTime: TimeInterval = 30 * 60

    /// After setup, the signing environment broke: one notification per problem until it's fixed
    /// for good, since no refresh can run meanwhile.
    private func reportEnvironment() {
        let defaults = UserDefaults.standard
        guard model.environment != nil else { return }
        let problems = model.environmentProblems
        let keys = Set(problems.map(\.key))
        let warned = Set(defaults.stringArray(forKey: Self.environmentWarnedKey) ?? [])
        var fixedSince = defaults.dictionary(forKey: Self.environmentFixedSinceKey) as? [String: Date] ?? [:]
        let now = Date()
        // Fixed problems are forgotten once they stayed fixed, and can then be notified again.
        var current = warned
        for key in warned {
            if keys.contains(key) {
                fixedSince[key] = nil // back (or still there): the clock restarts when it's fixed
            } else if let since = fixedSince[key] {
                if now.timeIntervalSince(since) >= Self.environmentSettleTime {
                    current.remove(key)
                    fixedSince[key] = nil
                }
            } else {
                fixedSince[key] = now
            }
        }
        defaults.set(fixedSince.filter { current.contains($0.key) }, forKey: Self.environmentFixedSinceKey)
        if current != warned { defaults.set(Array(current), forKey: Self.environmentWarnedKey) }
        guard defaults.bool(forKey: JourneyStep.completedKey) else { return }
        for error in problems where !current.contains(error.key) {
            markWarned(error.key, true)
            Task {
                guard await notifier.canDeliver(),
                      await notifier.environmentBroken(key: error.key, title: error.setupTitle,
                                                       message: error.environmentReason,
                                                       checkFailed: error.isSetupCheckFailure) else {
                    markWarned(error.key, false)
                    return
                }
            }
        }
    }

    private func markWarned(_ key: String, _ warned: Bool) {
        var keys = Set(UserDefaults.standard.stringArray(forKey: Self.environmentWarnedKey) ?? [])
        if warned { keys.insert(key) } else { keys.remove(key) }
        UserDefaults.standard.set(Array(keys), forKey: Self.environmentWarnedKey)
    }

    /// macOS build already warned about (macOS beta with a release Xcode).
    static let macBetaWarnedKey = "macBetaWarnedBuild"

    /// macOS beta with a release Xcode: one notification per macOS build, once setup is done.
    private func reportMacBeta() {
        let build = XcodeLauncher.macBuild
        guard model.macBetaWithReleaseXcode, UserDefaults.standard.bool(forKey: JourneyStep.completedKey),
              UserDefaults.standard.string(forKey: Self.macBetaWarnedKey) != build else { return }
        UserDefaults.standard.set(build, forKey: Self.macBetaWarnedKey)
        Task {
            guard await notifier.canDeliver() else {
                Self.logger.notice("macOS beta warning: notifications not authorized")
                UserDefaults.standard.removeObject(forKey: Self.macBetaWarnedKey)
                return
            }
            if !(await notifier.macBetaWithReleaseXcode()) {
                UserDefaults.standard.removeObject(forKey: Self.macBetaWarnedKey)
            }
        }
    }

    // MARK: - Outcomes

    /// The device was removed from XSide: its causes and renewals can be notified afresh if it comes back.
    private func forgetDevice(_ deviceID: String) {
        gate.forgetDevice(deviceID)
        persistGate()
        successGate.forgetDevice(deviceID)
        // Its installations are gone: so are their reminders, pending or shown.
        enqueueReminders { [notifier] in await notifier.removeExpiryReminders(forDevice: deviceID) }
        reconcileReminders()
    }

    /// An installation was uninstalled, removed from the list or paused: nothing is notified for
    /// it any more, and its reminder (pending or shown) goes.
    private func forgetInstallation(_ job: RefreshJob) {
        gate.reset(recordID: job.recordID, deviceID: job.deviceID)
        persistGate()
        successGate.forget(recordID: job.recordID, deviceID: job.deviceID)
        enqueueReminders { [notifier] in
            await notifier.removeExpiryReminder(recordID: job.recordID, deviceID: job.deviceID)
        }
    }

    /// A paused installation is refreshed again: its reminder comes back, and a due refresh starts now.
    private func refreshResumed(_ job: RefreshJob) {
        scheduleReminder(job)
        evaluate(reason: "resume")
    }

    // MARK: Expiry reminders

    /// Reminder work runs one operation at a time, in order: a reconciliation can't overwrite a
    /// reschedule that came after it.
    private var reminderTail: Task<Void, Never>?

    private func enqueueReminders(_ operation: @escaping @MainActor () async -> Void) {
        let previous = reminderTail
        reminderTail = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// One reminder per refreshed installation, scheduled with the system (see
    /// `Notifier.scheduleExpiryReminder`); reminders of installations gone or paused since are
    /// removed. Cheap: everything is simply re-added.
    private func reconcileReminders() {
        ticksSinceReconcile = 0
        enqueueReminders { [weak self] in
            guard let self else { return }
            let jobs = RefreshPlanner.refreshedJobs(model.records).filter { model.devicePrefs.notifies($0.deviceID) }
            await notifier.removeExpiryReminders(keeping: Set(jobs.map {
                ExpiryWatch.reminderID(recordID: $0.recordID, deviceID: $0.deviceID)
            }))
            // Each one read afresh: the library may have changed during the awaits.
            for job in jobs { await scheduleCurrentReminder(job) }
        }
    }

    /// Reschedules one installation's reminder for its new expiry (after an install or a refresh).
    private func scheduleReminder(_ job: RefreshJob) {
        enqueueReminders { [weak self] in await self?.scheduleCurrentReminder(job) }
    }

    /// Schedules the reminder of the installation as it is now; nothing if it's gone or paused.
    private func scheduleCurrentReminder(_ job: RefreshJob) async {
        guard let record = model.records.first(where: { $0.id == job.recordID }),
              let installation = record.installations.first(where: { $0.deviceID == job.deviceID }),
              !installation.refreshPaused, model.devicePrefs.notifies(job.deviceID) else {
            await notifier.removeExpiryReminder(recordID: job.recordID, deviceID: job.deviceID)
            return
        }
        await notifier.scheduleExpiryReminder(recordID: record.id, deviceID: job.deviceID, appName: Self.appName(record),
                                              deviceName: deviceName(job.deviceID), expiresAt: installation.expiresAt)
    }

    /// The name shown for the app: the custom one from the install options, else the app's own.
    private static func appName(_ record: AppRecord) -> String {
        record.options.displayName ?? record.displayName
    }

    private func deviceName(_ deviceID: String) -> String {
        model.devices.first { $0.id == deviceID }?.name
            ?? model.cachedNames[deviceID] ?? L("notification.refreshed.genericDevice")
    }

    private func jobFinished(_ job: RefreshJob, error: (any Error)?, automatic: Bool, wasRefresh: Bool) {
        guard let error else {
            // Any success (install, manual or automatic refresh) re-arms notifications for the row.
            Self.logger.notice("refresh succeeded \(job.recordID.uuidString)")
            var updated = gate
            updated.reset(recordID: job.recordID, deviceID: job.deviceID)
            if updated != gate { gate = updated; persistGate() }
            notifySuccess(job, wasRefresh: wasRefresh)
            scheduleReminder(job)
            if wasRefresh { model.updater.checkSoon("after a refresh") }
            return
        }
        // Cancelled by the user: nothing failed, nothing to report.
        if error is CancellationError { return }
        // Deleted from the device: XSide forgot it there (see `AppModel.run`); say so, once.
        if error as? XSideError == .appRemovedFromDevice {
            notifyRemoved(job, appName: model.records.first { $0.id == job.recordID }.map(Self.appName) ?? "XSide")
            return
        }
        // Manual actions show their error in the UI; only background failures notify.
        guard automatic else { return }
        // The environment broke while the job waited: `reportEnvironment` notifies it, once.
        // A failed check of the environment (`security`, `openssl`) is reported the same way.
        if let e = error as? XSideError,
           [.xcodeMissing, .xcodeNotSignedIn, .noSigningIdentity].contains(e)
            || (e.isSetupCheckFailure && e == model.environmentError)
            || Self.isProbeFailure(e) { return }
        // The device was removed from XSide meanwhile, or the refresh paused: nothing to report.
        guard let installation = model.records.first(where: { $0.id == job.recordID })?
            .installations.first(where: { $0.deviceID == job.deviceID }),
              !installation.refreshPaused else { return }
        let key = installation.lastErrorKey ?? (error as? XSideError)?.key ?? "unknown"
        Self.logger.notice("refresh failed \(job.recordID.uuidString): \(key)")
        notifyFailure(job, errorKey: key, message: Self.backgroundMessage(error) ?? localizedRowError(key: key))
    }

    /// A tool only the environment probe runs (`openssl`). A `security` failure counts only while
    /// it is the environment's own (above): the pipeline runs `security` too.
    private static func isProbeFailure(_ error: XSideError) -> Bool {
        if case .commandFailed(let tool, _) = error { return tool == "openssl" }
        return false
    }

    /// The error's message for a background job: a stopped tool is retried by XSide itself.
    private static func backgroundMessage(_ error: any Error) -> String? {
        guard let error = error as? XSideError else { return nil }
        if case .timedOut(let tool) = error { return L("error.timedOut.auto", tool) }
        return error.localizedMessage
    }

    /// Success of a refresh of an existing installation (automatic or manual), unless disabled in
    /// Settings. At most one per (app, device, expiresAt).
    private func notifySuccess(_ job: RefreshJob, wasRefresh: Bool) {
        guard wasRefresh, model.devicePrefs.notifies(job.deviceID), UserDefaults.standard.object(forKey: Notifier.notifyRefreshSuccessKey) as? Bool ?? true,
              let record = model.records.first(where: { $0.id == job.recordID }),
              let installation = record.installations.first(where: { $0.deviceID == job.deviceID }) else { return }
        let deviceName = deviceName(job.deviceID)
        Task {
            guard await notifier.canDeliver() else { return }
            guard successGate.shouldNotify(recordID: job.recordID, deviceID: job.deviceID,
                                           expiresAt: installation.expiresAt, wasRefresh: wasRefresh) else { return }
            let date = installation.expiresAt.formatted(
                Date.FormatStyle(date: .abbreviated, time: .omitted).locale(appLocale))
            let posted = await notifier.refreshSucceeded(
                appName: Self.appName(record), deviceName: deviceName, date: date,
                id: "refreshed.\(job.recordID.uuidString).\(job.deviceID)")
            if !posted { successGate.forget(recordID: job.recordID, deviceID: job.deviceID) }
        }
    }

    /// A crash XSide hadn't told about (the model dedups by crash file), unless turned off in
    /// Settings or for that device, or the install window on screen already shows it.
    private func notifyCrash(_ key: JobKey, flag: CrashFlag) {
        guard AppModel.setting(AppModel.notifyCrashKey), model.devicePrefs.notifies(key.deviceID),
              let record = model.records.first(where: { $0.id == key.recordID }) else { return }
        if model.isInstallWindowOpen, let flow = model.install,
           flow.runs.contains(where: { $0.deviceID == key.deviceID && $0.crash?.fileName == flag.fileName }) { return }
        let appName = Self.appName(record)
        let cause = CrashWording(flag.diagnosis, app: appName).title
        let device = deviceName(key.deviceID)
        Task { [notifier] in
            guard await notifier.canDeliver() else { return }
            await notifier.crashFound(appName: appName, deviceName: device, cause: cause, duringUse: flag.duringUse == true,
                                      job: RefreshJob(recordID: key.recordID, deviceID: key.deviceID))
        }
    }

    private func notifyRemoved(_ job: RefreshJob, appName: String) {
        guard AppModel.setting(AppModel.notifyAppRemovedKey), model.devicePrefs.notifies(job.deviceID) else { return }
        let device = deviceName(job.deviceID)
        Task { [notifier] in
            await notifier.appRemoved(appName: appName, deviceName: device,
                                      id: "removed.\(job.recordID.uuidString).\(job.deviceID)")
        }
    }

    /// When each device's app list was last read (see `checkPresence`).
    private var presenceChecked: [String: Date] = [:]

    /// Every 10 minutes, as soon as a device shows up, and when the panel opens (at most once a
    /// minute): apps deleted from a reachable device are forgotten there (see
    /// `AppModel.forgetDeletedApps`).
    private func checkPresence(interval: TimeInterval = PresenceCheck.interval) {
        let now = Date()
        for id in PresenceCheck.devicesToCheck(model.devices, records: model.records,
                                               lastChecked: presenceChecked, now: now, interval: interval) {
            presenceChecked[id] = now
            Task { [weak self] in
                guard let self else { return }
                for removed in await model.forgetDeletedApps(on: id) {
                    notifyRemoved(removed.job, appName: removed.appName)
                }
            }
        }
    }

    /// The gate is consumed only for a notification the system accepted: with notifications
    /// denied, the cause is still notified once the user enables them.
    private func notifyFailure(_ job: RefreshJob, errorKey: String, message: String) {
        guard model.devicePrefs.notifies(job.deviceID) else { return } // a device notifications were turned off for
        Task {
            guard await notifier.canDeliver() else {
                Self.logger.notice("notifications not authorized: \(errorKey) not notified")
                return
            }
            guard gate.shouldNotify(recordID: job.recordID, deviceID: job.deviceID, errorKey: errorKey) else { return }
            persistGate()
            let name = model.records.first { $0.id == job.recordID }.map(Self.appName) ?? "XSide"
            let posted = await notifier.refreshFailed(appName: name, errorKey: errorKey, message: message, job: job,
                                                      id: "refresh.\(job.recordID.uuidString).\(job.deviceID)")
            if !posted {
                gate.forget(recordID: job.recordID, deviceID: job.deviceID, errorKey: errorKey)
                persistGate()
            }
        }
    }

    private func persistGate() {
        do {
            try gateStore.save(gate)
        } catch {
            Self.logger.error("saving notifications.json failed: \(String(describing: error))")
        }
    }
}
