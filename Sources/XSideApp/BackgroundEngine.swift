import AppKit
import os
import XSideCore

/// Keeps installed apps alive without user action: polls devices, starts the refreshes
/// `RefreshPlanner` says are due, and notifies a failure once per (app, device, cause).
@MainActor
final class BackgroundEngine {
    private static let logger = Logger(subsystem: "io.github.xside.XSide", category: "engine")
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
        Self.logger.notice("engine started (threshold \(Self.threshold / 86_400, privacy: .public) d)")
        notifier.start()

        model.onNeedsEvaluation = { [weak self] in self?.evaluate(reason: "change") }
        model.onDeviceRemoved = { [weak self] id in self?.forgetDevice(id) }
        model.onInstallationRemoved = { [weak self] job in self?.forgetInstallation(job) }
        // Allowed only now (journey, Settings): the reminders couldn't be scheduled before.
        NotificationPermission.onBecameAuthorized = { [weak self] in self?.reconcileReminders() }
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

    /// Default 2 days, or the hidden debug override. Never shown in the UI.
    static var threshold: TimeInterval {
        RefreshPlanner.threshold(debugDays: UserDefaults.standard.double(forKey: debugThresholdKey))
    }

    // MARK: - Triggers

    private func pollTick() async {
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
        // The first evaluation comes after the library is loaded (see `AppModel.start`).
        if !remindersReconciled {
            remindersReconciled = true
            reconcileReminders()
        }
        reportEnvironment()
        reportMacBeta()
        reportUnreachable()
        reportNeedsUSB()
        // Environment broken (or not probed yet): nothing can be refreshed. `reportEnvironment`
        // already notifies each problem once; no per-app notification on top of it.
        guard case .success? = model.environment else { return }
        let due = RefreshPlanner.startable(dueJobs(), busy: model.busyJobs)
        guard !due.isEmpty else { return }
        Self.logger.notice("\(reason, privacy: .public): \(due.count, privacy: .public) job(s) due")
        for job in due where model.refreshNow(job, automatic: true) {
            Self.logger.notice("refresh started \(job.recordID.uuidString, privacy: .public) on \(job.deviceID, privacy: .public)")
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
            Self.logger.notice("device unreachable for due \(job.recordID.uuidString, privacy: .public) on \(job.deviceID, privacy: .public)")
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
        guard let record = model.records.first(where: { $0.id == job.recordID }),
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

    /// Environment problems already notified (their keys), each cleared once it's fixed.
    static let environmentWarnedKey = "environmentWarnedErrors"

    /// After setup, the signing environment broke: one notification per problem until it's fixed,
    /// since no refresh can run meanwhile.
    private func reportEnvironment() {
        let defaults = UserDefaults.standard
        guard model.environment != nil else { return }
        let problems = model.environmentProblems
        let warned = Set(defaults.stringArray(forKey: Self.environmentWarnedKey) ?? [])
        // Fixed problems can be notified again if they come back.
        let current = warned.intersection(problems.map(\.key))
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

    /// An installation was uninstalled or is no longer refreshed: nothing is notified for it any
    /// more, and its reminder (pending or shown) goes.
    private func forgetInstallation(_ job: RefreshJob) {
        gate.reset(recordID: job.recordID, deviceID: job.deviceID)
        persistGate()
        successGate.forget(recordID: job.recordID, deviceID: job.deviceID)
        enqueueReminders { [notifier] in
            await notifier.removeExpiryReminder(recordID: job.recordID, deviceID: job.deviceID)
        }
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

    /// One reminder per installation, scheduled with the system (see `Notifier.scheduleExpiryReminder`);
    /// reminders of installations gone since are removed. Cheap: everything is simply re-added.
    private func reconcileReminders() {
        ticksSinceReconcile = 0
        enqueueReminders { [weak self] in
            guard let self else { return }
            let jobs = model.records.flatMap { record in
                record.installations.map { RefreshJob(recordID: record.id, deviceID: $0.deviceID) }
            }
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

    /// Schedules the reminder of the installation as it is now; nothing if it's gone.
    private func scheduleCurrentReminder(_ job: RefreshJob) async {
        guard let record = model.records.first(where: { $0.id == job.recordID }),
              let installation = record.installations.first(where: { $0.deviceID == job.deviceID }) else { return }
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
            Self.logger.notice("refresh succeeded \(job.recordID.uuidString, privacy: .public)")
            var updated = gate
            updated.reset(recordID: job.recordID, deviceID: job.deviceID)
            if updated != gate { gate = updated; persistGate() }
            notifySuccess(job, wasRefresh: wasRefresh)
            scheduleReminder(job)
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
        // The device was removed from XSide meanwhile: nothing to report.
        guard model.records.first(where: { $0.id == job.recordID })?
            .installations.contains(where: { $0.deviceID == job.deviceID }) == true else { return }
        let installation = model.records.first { $0.id == job.recordID }?
            .installations.first { $0.deviceID == job.deviceID }
        let key = installation?.lastErrorKey ?? (error as? XSideError)?.key ?? "unknown"
        Self.logger.notice("refresh failed \(job.recordID.uuidString, privacy: .public): \(key, privacy: .public)")
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
        guard wasRefresh, UserDefaults.standard.object(forKey: Notifier.notifyRefreshSuccessKey) as? Bool ?? true,
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

    /// The gate is consumed only for a notification the system accepted: with notifications
    /// denied, the cause is still notified once the user enables them.
    private func notifyFailure(_ job: RefreshJob, errorKey: String, message: String) {
        Task {
            guard await notifier.canDeliver() else {
                Self.logger.notice("notifications not authorized: \(errorKey, privacy: .public) not notified")
                return
            }
            guard gate.shouldNotify(recordID: job.recordID, deviceID: job.deviceID, errorKey: errorKey) else { return }
            persistGate()
            let name = model.records.first { $0.id == job.recordID }.map(Self.appName) ?? "XSide"
            let posted = await notifier.refreshFailed(appName: name, errorKey: errorKey, message: message,
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
            Self.logger.error("saving notifications.json failed: \(String(describing: error), privacy: .public)")
        }
    }
}
