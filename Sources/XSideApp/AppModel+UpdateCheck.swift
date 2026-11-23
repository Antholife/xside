import Foundation
import os
import XSideCore

/// What the engine notifies for a release found but not installed by itself.
struct AppUpdateNotice: Sendable, Equatable {
    let appName: String
    let version: String
    let job: RefreshJob
    /// One per app or tweak: a newer notice replaces the older instead of stacking.
    let id: String
}

/// How a manual check ended for one app or tweak (the fiche shows it).
enum UpdateCheckResult: Sendable, Equatable {
    case upToDate
    case installed(version: String)
    /// A release is out but was not installed by itself (notify mode, prerelease, or a guardrail).
    /// `reason` says why it waits (a prerelease, a suspect content, or just the notify mode).
    case available(version: String, reason: NotifyReason, tag: String, asset: String)
    /// Several files fit the variant: the person picks (only a manual check says so).
    case needsVariantChoice
    /// The release changed between the card and the click: nothing was installed; check again.
    case changed
    case failed(String)
}

struct UpdateCheckReport: Sendable, Equatable {
    let name: String
    let result: UpdateCheckResult
    /// The tweak's package id; nil for the app itself.
    var tweakPackageID: String? = nil
    /// Unique within one check (names can repeat).
    var key: String { tweakPackageID ?? "app" }
}

extension AppModel {
    static let updateLogger = Logger(subsystem: "app.xside", category: "updates")

    /// One thing to look at: an app (`.ipa`) or one of its pool tweaks (`.deb`). For an app, `device`
    /// is the installation whose per-device baseline this target checks (each device has its own, so
    /// one target per installed device); nil for a tweak (its baseline stays on the source).
    private struct UpdateTarget {
        let record: AppRecord
        let tweak: TweakPackage?
        var device: Installation? = nil
        var source: UpdateSource? { tweak?.updateSource ?? record.updateSource }
        var kind: ReleaseKind { tweak == nil ? .ipa : .deb }
        var installedVersion: String? { tweak == nil ? record.version : tweak?.version }
        /// The per-device baseline (the release this device is on), falling back to the source's shared
        /// one; a tweak uses the source's.
        var baselineTag: String? { device?.installedTag ?? source?.installedTag }
        var baselineTrigger: String? { device?.installedTrigger ?? source?.installedTrigger }
        var name: String {
            let app = record.options.displayName ?? record.displayName
            return tweak.map { "\($0.name) (\(app))" } ?? app
        }
        var noticeID: String { "appUpdate.\(record.id.uuidString).\(tweak?.packageID ?? "app")" }
    }

    private func updateTargets(of record: AppRecord) -> [UpdateTarget] {
        var targets: [UpdateTarget] = []
        if record.updateSource != nil {
            // One per installed device: each has its own baseline. No installation yet (just imported):
            // one record-level target on the source's baseline.
            if record.installations.isEmpty {
                targets.append(UpdateTarget(record: record, tweak: nil))
            } else {
                for inst in record.installations { targets.append(UpdateTarget(record: record, tweak: nil, device: inst)) }
            }
        }
        for tweak in record.tweaks ?? [] where tweak.updateSource != nil {
            targets.append(UpdateTarget(record: record, tweak: tweak))
        }
        return targets
    }

    /// Groups the targets that share one update source: an app's per-device targets share the record's
    /// source (keyed by record id), while each tweak has its own (keyed by record id + tweak id). Used
    /// to check a whole source together and to stamp its `lastCheckedAt` once.
    private func updateGroupKey(_ target: UpdateTarget) -> String {
        "\(target.record.id)|\(target.tweak?.id ?? "")"
    }

    /// The check cadence for a target: this device's own frequency (its inApp) now, falling back to
    /// the source's shared interval (a tweak, or a device with no inApp yet). The last-check time
    /// stays shared on the source (one look at the one repo).
    private func targetCheckInterval(_ target: UpdateTarget) -> TimeInterval? {
        if target.tweak == nil, let freq = target.device?.inApp?.updateFrequency.value {
            return freq.checkInterval(current: target.source?.checkInterval)
        }
        return target.source?.checkInterval
    }

    /// The daily pass (the engine ticks it): once per `UpdateSchedule.interval`, looks at every app
    /// and tweak with a GitHub source, installs a stable release of those on auto, and notifies the
    /// rest. Runs as a task; one failing source never stops the others. A variant to choose is
    /// skipped here (the fiche asks).
    /// Debug-only: `XSIDE_FAST_UPDATES=1` honors short per-app check intervals (down to 20 s) instead
    /// of the 15-minute floor, to test the automatic update notification without waiting.
    static let fastUpdateCadence: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["XSIDE_FAST_UPDATES"] == "1"
        #else
        return false
        #endif
    }()

    /// Shortest gap between two update checks of the same source on a launch check (`atLaunch`): a
    /// fresh check when XSide opens, but not again if it was checked in the last few minutes (a quick
    /// restart shouldn't hammer the GitHub API).
    static var launchRecheckFloor: TimeInterval { 10 * 60 }

    /// `atLaunch`: run once when XSide starts — check every source (ignoring its cadence) so opening
    /// XSide gives fresh results and auto-installs where set, skipping only a source checked in the
    /// last `launchRecheckFloor`. Otherwise the periodic tick: each source on its own cadence.
    func checkUpdatesIfDue(atLaunch: Bool = false) {
        let now = Date()
        guard hasLoadedRecords, !updateCheckRunning else { return }
        // Global back-off after a pass where everything failed (offline, rate limited): don't hammer
        // the API at every tick, whatever each source's own cadence says.
        if let f = lastUpdateFailure, f <= now, now.timeIntervalSince(f) < UpdateSchedule.failureInterval { return }
        let globalDefault = Self.updateCheckInterval
        func isDueNow(_ target: UpdateTarget) -> Bool {
            let cadence = targetCheckInterval(target) // per device now (its frequency), else the source's
            // "At refresh" sources are not on the time cadence: they are checked when the app refreshes.
            if UpdateSchedule.checksAtRefresh(cadence, default: globalDefault) { return false }
            if atLaunch {
                guard let last = target.source?.lastCheckedAt else { return true }
                return now.timeIntervalSince(last) >= Self.launchRecheckFloor
            }
            let interval = Self.fastUpdateCadence
                ? max(cadence ?? globalDefault, 20) // debug: honor short intervals
                : UpdateSchedule.effectiveInterval(cadence, default: globalDefault)
            return UpdateSchedule.isDue(lastChecked: target.source?.lastCheckedAt, interval: interval, now: now)
        }
        // A source is checked when ANY of its device-targets is due (shortest cadence wins); then ALL
        // its device-targets are evaluated against the one fetched release list. Otherwise a device on
        // a longer interval, sharing the source with a shorter-interval one that keeps resetting the
        // shared lastCheckedAt, would never come due and would miss its updates.
        let allTargets = records.flatMap(updateTargets(of:))
        let dueGroups = Set(allTargets.filter(isDueNow).map(updateGroupKey))
        let due = allTargets.filter { dueGroups.contains(updateGroupKey($0)) }
        guard !due.isEmpty else { return }
        updateCheckRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { updateCheckRunning = false }
            let reports = await runUpdateChecks(due)
            // Advance the cadence only for the sources we actually reached: a failed one (offline,
            // rate limited) stays due so it's retried, under the global back-off above.
            let reachedTargets = zip(due, reports).compactMap { target, report -> UpdateTarget? in
                if case .failed = report.result { nil } else { target }
            }
            await markChecked(reachedTargets, at: now)
            let reached = reports.contains { if case .failed = $0.result { false } else { true } }
            lastUpdateFailure = reached ? nil : now
            lastUpdateCheck = now
        }
    }

    /// Runs an update check for an app whose source is set to "at refresh", right after it refreshed.
    /// Notifies / auto-installs like the background pass (not user-initiated).
    func checkUpdatesAtRefresh(recordID: UUID) {
        guard hasLoadedRecords, !updateCheckRunning, let record = records.first(where: { $0.id == recordID }) else { return }
        let globalDefault = Self.updateCheckInterval
        let targets = updateTargets(of: record).filter {
            UpdateSchedule.checksAtRefresh(targetCheckInterval($0), default: globalDefault)
        }
        guard !targets.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let reports = await runUpdateChecks(targets)
            let reached = zip(targets, reports).compactMap { t, r -> UpdateTarget? in
                if case .failed = r.result { nil } else { t }
            }
            await markChecked(reached, at: Date())
        }
    }

    /// « Vérifier maintenant » asked from the iPhone: check every source of this record now, whatever
    /// its cadence, and notify / auto-install like the background pass.
    func checkUpdatesForRecord(recordID: UUID) {
        guard hasLoadedRecords, !updateCheckRunning, let record = records.first(where: { $0.id == recordID }) else { return }
        let targets = updateTargets(of: record)
        guard !targets.isEmpty else { return }
        updateCheckRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { updateCheckRunning = false }
            let reports = await runUpdateChecks(targets)
            let reached = zip(targets, reports).compactMap { t, r -> UpdateTarget? in
                if case .failed = r.result { nil } else { t }
            }
            await markChecked(reached, at: Date())
        }
    }

    /// Stamps `lastCheckedAt` on each source's library entry so its own cadence advances.
    private func markChecked(_ targets: [UpdateTarget], at now: Date) async {
        guard !targets.isEmpty else { return }
        let records = await library.records()
        var wrote = false
        // One write per distinct source: an app's per-device targets all share the record's source, so
        // without this an N-device app did N identical saves per pass.
        var doneRecords = Set<UUID>()
        var doneTweaks = Set<String>()
        for target in targets {
            do {
                if let old = target.tweak {
                    guard let record = records.first(where: { $0.id == target.record.id }),
                          let tweak = record.tweaks?.first(where: { $0.packageID == old.packageID && $0.updateSource != nil }),
                          var source = tweak.updateSource, doneTweaks.insert(tweak.id).inserted else { continue }
                    source.lastCheckedAt = now
                    try await library.setUpdateSource(source, forTweak: tweak.id, recordID: record.id)
                    wrote = true
                } else {
                    guard let record = records.first(where: { $0.id == target.record.id }),
                          var source = record.updateSource, doneRecords.insert(record.id).inserted else { continue }
                    source.lastCheckedAt = now
                    try await library.setUpdateSource(source, forRecord: record.id)
                    wrote = true
                }
            } catch {
                Self.updateLogger.error("lastChecked not saved: \(String(describing: error), privacy: .public)")
            }
        }
        if wrote { await reloadRecords() }
    }

    /// A manual check of one app and its tweaks (the fiche's button), whatever the schedule says.
    /// Unlike the background pass it reports a variant to choose and every failure.
    func checkUpdatesNow(_ entry: AppEntry) async -> [UpdateCheckReport] {
        // The view's `entry.record` can be stale (a source added moments ago lives in `records`
        // already, not yet in the entry the view holds): check the fresh record, like installUpdateNow.
        let record = records.first(where: { $0.id == entry.record.id }) ?? entry.record
        return await runUpdateChecks(updateTargets(of: record), userInitiated: true)
    }

    /// The row menu's « Vérifier les mises à jour »: the check, then a toast when there is nothing
    /// to look at (up to date, installed by itself, failed). True when something waits for the
    /// person, so the caller opens the app's Mises à jour tab.
    func checkUpdatesFromMenu(_ entry: AppEntry) async -> Bool {
        let reports = await checkUpdatesNow(entry)
        var failure: String?
        var needsLook = false
        for report in reports {
            switch report.result {
            case .upToDate, .installed: break
            case .failed(let message): failure = failure ?? message
            case .available, .needsVariantChoice, .changed: needsLook = true
            }
        }
        if needsLook { return true }
        showToast(failure.map { L("update.toast.failed", $0) } ?? L("update.toast.upToDate"))
        return false
    }

    private func runUpdateChecks(_ targets: [UpdateTarget], userInitiated: Bool = false) async -> [UpdateCheckReport] {
        let work = libraryRoot.appendingPathComponent(AppLibrary.stagingFolder).appendingPathComponent("updates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let checker = UpdateChecker(fetcher: repoFetcher, workDir: work)
        // Two sources asking the same of the same repo (same variant, kind and baseline tag) share
        // one look at the release list.
        var answers: [String: UpdateOutcome] = [:]
        var reports: [UpdateCheckReport] = []
        for target in targets {
            guard let source = target.source else { continue }
            // The baseline is per device now, so it is part of the dedup key (two devices on the same
            // tag still share one fetch).
            let key = "\(source.repo.id)|\(source.variant)|\(target.kind)|\(target.baselineTag ?? "")|\(target.baselineTrigger ?? "")"
            let outcome: UpdateOutcome
            if let known = answers[key] {
                outcome = known
            } else {
                outcome = await checker.check(source: source, kind: target.kind,
                                              installedTag: target.baselineTag, installedTrigger: target.baselineTrigger)
                answers[key] = outcome
            }
            reports.append(UpdateCheckReport(name: target.name, result: await route(outcome, for: target, userInitiated: userInitiated), tweakPackageID: target.tweak?.packageID))
        }
        return reports
    }

    /// The fiche's « Installer » / « Installer quand même »: looks at the source again and installs
    /// what it finds on the person's say-so (mode, prerelease and suspect-content guards do not
    /// apply; the bundle/package identity check does). `tweakPackageID` nil: the app itself.
    func installUpdateNow(_ entry: AppEntry, tweakPackageID: String?, expectedTag: String, expectedAsset: String,
                          approved: Set<NotifyReason>) async -> UpdateCheckResult {
        guard canManage(entry) else { return .failed("not allowed") }
        let record = records.first(where: { $0.id == entry.record.id }) ?? entry.record
        let tweak = tweakPackageID.flatMap { id in record.tweaks?.first { $0.packageID == id } }
        // The app's baseline is this device's own (markInstalled writes it there); a tweak's stays on
        // the source.
        let deviceInstallation = record.installations.first { $0.deviceID == entry.installation.deviceID }
        let target = UpdateTarget(record: record, tweak: tweak, device: tweak == nil ? deviceInstallation : nil)
        guard let source = target.source else { return .failed("no source") }
        guard let device = devices.first(where: { $0.id == entry.installation.deviceID }), device.isAvailable, device.isPaired else {
            return .failed("device unavailable")
        }
        let work = libraryRoot.appendingPathComponent(AppLibrary.stagingFolder).appendingPathComponent("updates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let checker = UpdateChecker(fetcher: repoFetcher, workDir: work)
        switch await checker.check(source: source, kind: target.kind,
                                   installedTag: target.baselineTag, installedTrigger: target.baselineTrigger) {
        case .upToDate: return .upToDate
        case .needsVariantChoice: return .needsVariantChoice
        case .failed(let reason): return .failed(reason)
        case .available(let found, _, let stable):
            // The release changed since the card: nothing installs under the earlier approval.
            guard found.tag == expectedTag, found.asset.name == expectedAsset else {
                return .changed
            }
            let key = Self.updateFractionKey(recordID: record.id, tweakPackageID: tweakPackageID)
            updateFraction[key] = 0
            defer { updateFraction[key] = nil }
            let progress: @Sendable (Double) -> Void = { [weak self] f in
                Task { @MainActor in self?.updateFraction[key] = f }
            }
            // Claim the job for the whole download + install (after canManage above, so its « jobs
            // must be nil » guard still passed), so the Mac panel shows activity and the spinner
            // animates throughout, not only once the install steps begin. Ref-counted: the install's
            // own claim nests inside this one.
            let jobKey = JobKey(recordID: record.id, deviceID: device.id)
            claim(jobKey, stage: .preparing)
            defer { release(jobKey) }
            switch await apply(target, device: device, found: found, stable: stable, userInitiated: true, approved: approved, progress: progress) {
            case .installed(let v):
                await markInstalled(found, for: target)
                return .installed(version: v)
            case .upToDate:
                await markInstalled(found, for: target)
                return .upToDate
            case .notify(let v, let r): return .available(version: v, reason: r, tag: found.tag, asset: found.asset.name)
            case .incompatible: return .failed("incompatible")
            case .failed(let m): return .failed(m)
            }
        }
    }

    // MARK: - Phone update modal (Slice 3)

    /// The phone asked to check for an update (its modal is up). A pure check of the APP's source (no
    /// auto-install: the person asked, so they confirm the install), as a `ChannelReply` to stream.
    /// Tweaks and variant choices are left to the Mac (`needsMac`), where their UI already lives.
    func modalUpdateCheckReply(recordID: UUID, deviceID: String) async -> ChannelReply {
        guard let record = records.first(where: { $0.id == recordID }), let source = record.updateSource else {
            return .update(state: "upToDate")
        }
        // Check against THIS device's baseline (the asking device), not the shared source — different
        // devices can be on different releases (Anthony).
        let installation = record.installations.first { $0.deviceID == deviceID }
        let work = libraryRoot.appendingPathComponent(AppLibrary.stagingFolder).appendingPathComponent("updates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        switch await UpdateChecker(fetcher: repoFetcher, workDir: work).check(source: source, kind: .ipa,
                                   installedTag: installation?.installedTag, installedTrigger: installation?.installedTrigger) {
        case .upToDate: return .update(state: "upToDate")
        case .needsVariantChoice: return .update(state: "needsMac")
        case .failed: return .failed(reasonKey: "updateFailed")
        case let .available(found, version, _):
            // A copy is KEPT in the person's chosen folder only when « Conserver les IPA téléchargés »
            // is on with a folder set; otherwise the download is temporary (XSide's cache) and nothing
            // is kept. Tell the phone which, and the folder, so the offer is accurate (Anthony: he had
            // chosen the Desktop, so « rien gardé » was wrong).
            let keptFolder = Self.keepDownloads ? Self.downloadsFolder?.path : nil
            return .update(state: "available", version: version, tag: found.tag, asset: found.asset.name,
                           downloadDir: keptFolder)
        }
    }

    /// The phone confirmed the offered update. Installs it (app only) and streams `downloading` with
    /// its percent, then the terminal state, through `frame`. `tag`/`asset` pin the offered release.
    func streamModalInstallUpdate(recordID: UUID, deviceID: String, tag: String, asset: String,
                                  frame: (ChannelReply) async -> Void) async {
        guard let record = records.first(where: { $0.id == recordID }),
              let installation = record.installations.first(where: { $0.deviceID == deviceID }) else {
            await frame(.failed(reasonKey: "updateFailed")); return
        }
        let entry = AppEntry(record: record, installation: installation)
        let key = Self.updateFractionKey(recordID: recordID, tweakPackageID: nil)
        let installKey = JobKey(recordID: recordID, deviceID: deviceID)
        let box = ModalInstallBox()
        let waiter = Task { @MainActor in
            box.result = await self.installUpdateNow(entry, tweakPackageID: nil, expectedTag: tag,
                                                     expectedAsset: asset, approved: [.notifyMode, .prerelease])
            box.done = true
        }
        phoneOpCancels[installKey] = { waiter.cancel() } // « Annuler » in the modal stops the update
        defer { phoneOpCancels[installKey] = nil }
        // NB: the job is claimed inside installUpdateNow, AFTER its canManage guard (which requires
        // jobs[key] == nil) — claiming here would make that guard fail (« not allowed »).
        // Download first (its %), then the install steps — streamed like a refresh so the modal shows
        // « Signature / Installation… · étape X/Y », not a frozen 100% (Anthony: « ça reste bloqué à
        // 100% au lieu de voir les steps d'install »). The install claims jobs[installKey] once it
        // starts; until then we're still downloading.
        // This device's own pre-update safety backup decision (per device): whether « Sauvegarder avant
        // une mise à jour » runs before the resign. Counted as the first step so « étape X/Y » is right.
        let preBackup = AppManagement.shouldBackUpBeforeUpdate(
            override: installation.inApp?.backupBeforeUpdate.value ?? record.options.backupBeforeUpdate,
            default: Self.setting(Self.backupBeforeUpdateDefaultKey),
            backupData: installation.inApp.map { $0.backupData.value } ?? record.options.backupData)
        AppModel.debugTrace("install-stream start key=\(installKey.recordID)|\(installKey.deviceID)")
        var last: ChannelReply?
        while !box.done {
            let next: ChannelReply?
            if dataBusy.contains(installKey) {
                // The pre-update safety backup runs before the resign: show it as the leading step.
                next = updateModalFrame(installKey, preBackup: preBackup, backing: true)
            } else if case .step = jobs[installKey] {
                next = updateModalFrame(installKey, preBackup: preBackup, backing: false) // a real resign step
            } else if let f = updateFraction[key], f < 1 {
                next = .update(state: "downloading", percent: max(0, min(99, Int((f * 100).rounded())))) // still downloading
            } else {
                // Download done, resign not yet reporting a step (inspecting the IPA / queued): show
                // « Préparation », not a frozen « download 100% » that made Anthony cancel every time.
                next = updateModalFrame(installKey, preBackup: preBackup, backing: false)
            }
            if let next, next != last { await frame(next); last = next; AppModel.debugTrace("stream frame: \(next) (jobs=\(String(describing: jobs[installKey])))") }
            try? await Task.sleep(for: .milliseconds(150))
        }
        AppModel.debugTrace("install-stream end result=\(box.result)")
        _ = await waiter.value
        if case let .failed(reason) = box.result {
            Self.updateLogger.error("phone update install failed for \(recordID, privacy: .public): \(reason, privacy: .public)")
        }
        await frame(Self.modalReply(for: box.result))
    }

    private final class ModalInstallBox: @unchecked Sendable {
        var result: UpdateCheckResult = .failed("updateFailed")
        var done = false
    }

    private static func modalReply(for result: UpdateCheckResult) -> ChannelReply {
        switch result {
        case let .installed(version): .update(state: "installed", version: version)
        case .upToDate: .update(state: "upToDate")
        case let .available(version, _, tag, asset): .update(state: "available", version: version, tag: tag, asset: asset)
        case .needsVariantChoice, .changed: .update(state: "needsMac")
        case let .failed(reason): .failed(reasonKey: updateFailureKey(reason))
        }
    }

    /// Maps the update install's free-form failure string to a reason key the phone can word plainly,
    /// so the modal says where it failed (download / file / install / …) instead of a flat
    /// « erreur inattendue » (Anthony: « l'installation a encore échoué »). The raw reason is logged.
    private static func updateFailureKey(_ reason: String) -> String {
        let r = reason.lowercased()
        if r.contains("cancel") { return "cancelled" } // « Annuler » from the modal, surfaced as cancelled
        if r.hasPrefix("download") { return "updateDownloadFailed" }
        if r.hasPrefix("inspect") || r.hasPrefix("analyze") { return "updateFileUnreadable" }
        if r.hasPrefix("install") { return "installFailed" }
        if r.hasPrefix("update not applied") { return "updateNotApplied" }
        if r.contains("incompatible") { return "updateIncompatible" }
        if r.contains("device") { return "deviceUnavailable" }
        if r.contains("not allowed") { return "updateBusy" } // canManage false: a job is already running
        if r.contains("gone") || r.contains("no source") { return "recordNotFound" }
        return "updateFailed"
    }

    private func route(_ outcome: UpdateOutcome, for target: UpdateTarget, userInitiated: Bool = false) async -> UpdateCheckResult {
        switch outcome {
        case .upToDate(let trigger):
            // Learn the baseline trigger on the first check (for rolling tags like `nightly`, where
            // the tag alone never changes): store the current release's trigger as the reference, on
            // this device's baseline (or the source's, for a tweak / record-level target).
            if let trigger, (target.baselineTag?.isEmpty == false), target.baselineTrigger == nil {
                if target.tweak == nil, let deviceID = target.device?.deviceID {
                    try? await library.setInstalledRelease(tag: nil, name: target.device?.installedName,
                                                           trigger: trigger, recordID: target.record.id, deviceID: deviceID)
                    await reloadRecords()
                } else {
                    await mutateSource(for: target) { $0.installedTrigger = trigger }
                }
            }
            return .upToDate
        case .needsVariantChoice:
            return .needsVariantChoice
        case .failed(let reason):
            // Tried again next time. The reason is the checker's, never a release's contents.
            Self.updateLogger.notice("update check failed for \(target.name, privacy: .public): \(reason, privacy: .public)")
            return .failed(reason)
        case .available(let found, let version, let stable):
            var result = UpdateCheckResult.available(version: version, reason: stable ? .notifyMode : .prerelease, tag: found.tag, asset: found.asset.name)
            // Per device: this device's own « notify / auto » (its inApp), falling back to the source's
            // shared default for a tweak or a device with no inApp yet.
            let deviceMode = target.device?.inApp?.updateMode.value ?? target.source?.mode
            let auto = stable && deviceMode == .auto
            if auto, let device = autoUpdateDevice(for: target) {
                // Report progress so the « Mises à jour » tab shows it, and notify so a tap goes there.
                let key = Self.updateFractionKey(recordID: target.record.id, tweakPackageID: target.tweak?.packageID)
                updateFraction[key] = 0
                defer { updateFraction[key] = nil }
                let progress: @Sendable (Double) -> Void = { [weak self] f in Task { @MainActor in self?.updateFraction[key] = f } }
                notifyInstalling(target, version: version)
                // Run in a stored task so « Annuler » in the tab can cancel the download/install.
                let jobKey = JobKey(recordID: target.record.id, deviceID: device.id)
                let installTask = Task { await self.apply(target, device: device, found: found, stable: stable, progress: progress) }
                autoInstallTasks[jobKey] = installTask
                defer { autoInstallTasks[jobKey] = nil }
                switch await installTask.value {
                case .installed(let installed):
                    await markInstalled(found, for: target)
                    notifyUpdated(target, version: installed) // Auto mode: tell the person XSide did it
                    return .installed(version: installed)
                case .upToDate: await markInstalled(found, for: target); return .upToDate
                case .notify(let v, let reason): result = .available(version: v, reason: reason, tag: found.tag, asset: found.asset.name)
                case .incompatible: break
                case .failed(let reason):
                    Self.updateLogger.notice("auto update failed for \(target.name, privacy: .public): \(reason, privacy: .public)")
                }
            }
            // The background pass announces a release once (deduped on the trigger); a manual check
            // shows the card itself, no extra notice.
            let alreadyAnnounced = target.source?.lastSeenTrigger == found.trigger
            if !userInitiated, !alreadyAnnounced, case .available(let v, _, _, _) = result {
                // Auto mode but no reachable device: say the update is pending (it installs by itself
                // when the device is back), rather than the plain « disponible » of notify mode.
                let autoPending = auto && autoUpdateDevice(for: target) == nil
                let delivered = autoPending ? await notifyAutoPending(target, version: v)
                                            : await notify(target, version: v)
                // Mark announced only when the notification was actually delivered: a dropped one
                // (permission off, device notifies off) is retried on the next check.
                if delivered { await markAnnounced(found.trigger, for: target) }
            }
            return result
        }
    }

    enum Applied { case installed(String), upToDate, notify(String, NotifyReason), incompatible, failed(String) }

    /// A stable key for this app/tweak's download progress (`AppModel.updateFraction`).
    static func updateFractionKey(recordID: UUID, tweakPackageID: String?) -> String {
        "\(recordID.uuidString)|\(tweakPackageID ?? "app")"
    }

    private func apply(_ target: UpdateTarget, device: Device, found: FoundRelease, stable: Bool, userInitiated: Bool = false, approved: Set<NotifyReason> = [], progress: (@Sendable (Double) -> Void)? = nil) async -> Applied {
        if let tweak = target.tweak {
            switch await applyTweakUpdate(old: tweak, recordID: target.record.id, device: device, found: found, stable: stable, userInitiated: userInitiated, approved: approved, progress: progress) {
            case .installed(let v): return .installed(v)
            case .upToDate: return .upToDate
            case .notify(let v, let r): return .notify(v, r)
            case .incompatible: return .incompatible
            case .failed(let m): return .failed(m)
            }
        }
        switch await applyAppUpdate(record: target.record, device: device, found: found, stable: stable, userInitiated: userInitiated, approved: approved, progress: progress) {
        case .installed(let v): return .installed(v)
        case .notify(let v, let r): return .notify(v, r)
        case .incompatible: return .incompatible
        case .failed(let m): return .failed(m)
        }
    }

    /// An installation's device that can take the update now; none (absent) means the update is
    /// announced instead of installed by itself.
    private func deviceForAutoUpdate(_ record: AppRecord) -> Device? {
        for installation in record.installations {
            if let d = devices.first(where: { $0.id == installation.deviceID }), d.isAvailable, d.isPaired { return d }
        }
        return nil
    }

    /// The device to auto-install a target's update on: for a per-device app target, that device (if
    /// reachable); otherwise (a tweak / record-level target) the first reachable installed device.
    private func autoUpdateDevice(for target: UpdateTarget) -> Device? {
        if target.tweak == nil, let deviceID = target.device?.deviceID {
            guard let d = devices.first(where: { $0.id == deviceID }), d.isAvailable, d.isPaired else { return nil }
            return d
        }
        return deviceForAutoUpdate(target.record)
    }

    /// Posts the "update available" notification; returns whether it was actually delivered.
    private func notify(_ target: UpdateTarget, version: String) async -> Bool {
        guard let installation = target.record.installations.first else { return false }
        // Per-device target: route and gate the notice by THIS device, not installations.first (that
        // sent a second device's update notice to the first, gated by the wrong device's prefs).
        let job = RefreshJob(recordID: target.record.id, deviceID: target.device?.deviceID ?? installation.deviceID)
        return await onAppUpdateAvailable?(AppUpdateNotice(appName: target.name, version: version, job: job, id: target.noticeID)) ?? false
    }

    /// Cancels a background auto-install for an app (from « Annuler » in the « Mises à jour » tab).
    /// Best-effort: it cancels the download, then the install at its next cancellation point.
    func cancelAutoInstall(recordID: UUID) {
        for (key, task) in autoInstallTasks where key.recordID == recordID { task.cancel() }
        // A phone-started update (or refresh) runs as a held-connection op, not an auto-install, so
        // cancel those too — otherwise « Annuler » on the Mac did nothing for an iPhone-launched update.
        for (key, cancel) in phoneOpCancels where key.recordID == recordID { cancel() }
    }

    /// Auto mode but no reachable device: notify that the update is pending. Returns whether delivered.
    private func notifyAutoPending(_ target: UpdateTarget, version: String) async -> Bool {
        guard let installation = target.record.installations.first else { return false }
        // Per-device target: route and gate the notice by THIS device, not installations.first (that
        // sent a second device's update notice to the first, gated by the wrong device's prefs).
        let job = RefreshJob(recordID: target.record.id, deviceID: target.device?.deviceID ?? installation.deviceID)
        return await onAppUpdatePending?(AppUpdateNotice(appName: target.name, version: version, job: job, id: target.noticeID)) ?? false
    }

    /// XSide started an auto-install: a notification whose tap opens the tab to watch the progress.
    private func notifyInstalling(_ target: UpdateTarget, version: String) {
        guard let installation = target.record.installations.first else { return }
        // Per-device target: route and gate the notice by THIS device, not installations.first (that
        // sent a second device's update notice to the first, gated by the wrong device's prefs).
        let job = RefreshJob(recordID: target.record.id, deviceID: target.device?.deviceID ?? installation.deviceID)
        onAppInstalling?(AppUpdateNotice(appName: target.name, version: version, job: job, id: target.noticeID))
    }

    /// XSide auto-installed an update: a confirmation notification (it replaces the "available" one).
    private func notifyUpdated(_ target: UpdateTarget, version: String) {
        guard let installation = target.record.installations.first else { return }
        // Per-device target: route and gate the notice by THIS device, not installations.first (that
        // sent a second device's update notice to the first, gated by the wrong device's prefs).
        let job = RefreshJob(recordID: target.record.id, deviceID: target.device?.deviceID ?? installation.deviceID)
        onAppUpdated?(AppUpdateNotice(appName: target.name, version: version, job: job, id: target.noticeID))
    }

    /// The release was announced to the person (notify-dedup): the next pass won't notify it again.
    private func markAnnounced(_ trigger: String, for target: UpdateTarget) async {
        await mutateSource(for: target) { $0.lastSeenTrigger = trigger }
    }

    /// XSide installed this release: it becomes the baseline, so a check is up to date until a newer
    /// release appears. Its trigger is marked announced too (no stale "available" notice).
    private func markInstalled(_ found: FoundRelease, for target: UpdateTarget) async {
        if target.tweak == nil, let deviceID = target.device?.deviceID {
            // Per-device baseline for the app: write this device's installation, not the shared source.
            try? await library.setInstalledRelease(tag: found.tag, name: found.name, trigger: found.trigger,
                                                   recordID: target.record.id, deviceID: deviceID)
            await mutateSource(for: target) { $0.lastSeenTrigger = found.trigger } // shared notify-dedup
        } else {
            await mutateSource(for: target) { $0.installedTag = found.tag; $0.installedName = found.name; $0.installedTrigger = found.trigger; $0.lastSeenTrigger = found.trigger }
        }
    }

    /// Reads the source again (an update that swapped a tweak changed its id), applies `change`, and
    /// writes it back only when something actually changed.
    private func mutateSource(for target: UpdateTarget, _ change: (inout UpdateSource) -> Void) async {
        do {
            let records = await library.records()
            if let old = target.tweak {
                guard let record = records.first(where: { $0.id == target.record.id }),
                      let tweak = record.tweaks?.first(where: { $0.packageID == old.packageID && $0.updateSource != nil }),
                      var source = tweak.updateSource else { return }
                let before = source
                change(&source)
                guard source != before else { return }
                try await library.setUpdateSource(source, forTweak: tweak.id, recordID: record.id)
            } else {
                guard let record = records.first(where: { $0.id == target.record.id }),
                      var source = record.updateSource else { return }
                let before = source
                change(&source)
                guard source != before else { return }
                try await library.setUpdateSource(source, forRecord: record.id)
            }
            await reloadRecords()
        } catch {
            Self.updateLogger.error("update source not saved: \(String(describing: error), privacy: .public)")
        }
    }
}


extension AppModel {
    /// The `.ipa` assets of a repo's releases, newest first, for the install window's
    /// "Source de mise à jour" (the fetch runs off the main actor).
    func installableIPAs(of repo: GitHubSource) async throws -> [(tag: String, isPrerelease: Bool, asset: ReleaseAsset, name: String?)] {
        let work = libraryRoot.appendingPathComponent(AppLibrary.stagingFolder).appendingPathComponent("updates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        return try await ReleaseFinder.fetchInstallableAssets(source: repo, kind: .ipa, fetcher: repoFetcher, workDir: work)
    }

    /// After the import: the install window's GitHub link, mode and chosen variant become the
    /// record's update source. Nothing without a valid link and a chosen variant.
    func persistUpdateSource(from draft: OptionsDraft, recordID: UUID) {
        guard let repo = GitHubSource.parse(draft.updateSourceURL), let variant = draft.updateVariant else { return }
        // The installed tag/name is PER DEVICE now (written on the installation by the install loop /
        // markInstalled), so this must NOT stamp the shared source with this one device's tag: that
        // was the leak where reinstalling the iPad at 1.1.5 changed the tag the iPhone shows. Keep the
        // shared source's own baseline as it was, seeding it from this install only when the source is
        // brand new (so a single-device app still has a fallback). Same for the notify/cadence bookkeeping.
        let existing = records.first(where: { $0.id == recordID })?.updateSource
        let source = UpdateSource(repo: repo, variant: variant, mode: draft.updateMode,
                                  lastSeenTrigger: existing?.lastSeenTrigger,
                                  installedTag: existing?.installedTag ?? draft.updateInstalledTag,
                                  installedName: existing?.installedName ?? draft.updateInstalledName,
                                  installedTrigger: existing?.installedTrigger,
                                  checkInterval: draft.updateInterval, lastCheckedAt: existing?.lastCheckedAt)
        Task {
            do {
                try await library.setUpdateSource(source, forRecord: recordID)
                await reloadRecords()
            } catch {
                Log("updates").error("could not save the update source: \(error)")
            }
        }
    }
}
