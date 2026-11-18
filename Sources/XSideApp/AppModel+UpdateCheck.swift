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

    /// One thing to look at: an app (`.ipa`) or one of its pool tweaks (`.deb`).
    private struct UpdateTarget {
        let record: AppRecord
        let tweak: TweakPackage?
        var source: UpdateSource? { tweak?.updateSource ?? record.updateSource }
        var kind: ReleaseKind { tweak == nil ? .ipa : .deb }
        var installedVersion: String? { tweak == nil ? record.version : tweak?.version }
        var name: String {
            let app = record.options.displayName ?? record.displayName
            return tweak.map { "\($0.name) (\(app))" } ?? app
        }
        var noticeID: String { "appUpdate.\(record.id.uuidString).\(tweak?.packageID ?? "app")" }
    }

    private func updateTargets(of record: AppRecord) -> [UpdateTarget] {
        var targets: [UpdateTarget] = []
        if record.updateSource != nil { targets.append(UpdateTarget(record: record, tweak: nil)) }
        for tweak in record.tweaks ?? [] where tweak.updateSource != nil {
            targets.append(UpdateTarget(record: record, tweak: tweak))
        }
        return targets
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

    func checkUpdatesIfDue() {
        let now = Date()
        guard hasLoadedRecords, !updateCheckRunning else { return }
        // Global back-off after a pass where everything failed (offline, rate limited): don't hammer
        // the API at every tick, whatever each source's own cadence says.
        if let f = lastUpdateFailure, f <= now, now.timeIntervalSince(f) < UpdateSchedule.failureInterval { return }
        let globalDefault = Self.updateCheckInterval
        // Each source on its own cadence (per-app override, else the global default; « never » is skipped).
        let due = records.flatMap(updateTargets(of:)).filter { target in
            // "At refresh" sources are not on the time cadence: they are checked when the app refreshes.
            if UpdateSchedule.checksAtRefresh(target.source?.checkInterval, default: globalDefault) { return false }
            let interval = Self.fastUpdateCadence
                ? max(target.source?.checkInterval ?? globalDefault, 20) // debug: honor short intervals
                : UpdateSchedule.effectiveInterval(target.source?.checkInterval, default: globalDefault)
            return UpdateSchedule.isDue(lastChecked: target.source?.lastCheckedAt, interval: interval, now: now)
        }
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
            UpdateSchedule.checksAtRefresh($0.source?.checkInterval, default: globalDefault)
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
        for target in targets {
            do {
                if let old = target.tweak {
                    guard let record = records.first(where: { $0.id == target.record.id }),
                          let tweak = record.tweaks?.first(where: { $0.packageID == old.packageID && $0.updateSource != nil }),
                          var source = tweak.updateSource else { continue }
                    source.lastCheckedAt = now
                    try await library.setUpdateSource(source, forTweak: tweak.id, recordID: record.id)
                    wrote = true
                } else {
                    guard let record = records.first(where: { $0.id == target.record.id }),
                          var source = record.updateSource else { continue }
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
            let key = "\(source.repo.id)|\(source.variant)|\(target.kind)|\(source.installedTag ?? "")"
            let outcome: UpdateOutcome
            if let known = answers[key] {
                outcome = known
            } else {
                outcome = await checker.check(source: source, kind: target.kind)
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
        let target = UpdateTarget(record: record, tweak: tweak)
        guard let source = target.source else { return .failed("no source") }
        guard let device = devices.first(where: { $0.id == entry.installation.deviceID }), device.isAvailable, device.isPaired else {
            return .failed("device unavailable")
        }
        let work = libraryRoot.appendingPathComponent(AppLibrary.stagingFolder).appendingPathComponent("updates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let checker = UpdateChecker(fetcher: repoFetcher, workDir: work)
        switch await checker.check(source: source, kind: target.kind) {
        case .upToDate: return .upToDate
        case .needsVariantChoice: return .needsVariantChoice
        case .failed(let reason): return .failed(reason)
        case .available(let found, let version, let stable):
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

    private func route(_ outcome: UpdateOutcome, for target: UpdateTarget, userInitiated: Bool = false) async -> UpdateCheckResult {
        switch outcome {
        case .upToDate(let trigger):
            // Learn the baseline trigger on the first check (for rolling tags like `nightly`, where
            // the tag alone never changes): store the current release's trigger as the reference.
            if let trigger, target.source?.installedTag?.isEmpty == false, target.source?.installedTrigger == nil {
                await mutateSource(for: target) { $0.installedTrigger = trigger }
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
            let auto = stable && target.source?.mode == .auto
            if auto, let device = deviceForAutoUpdate(target.record) {
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
                let autoPending = auto && deviceForAutoUpdate(target.record) == nil
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

    /// Posts the "update available" notification; returns whether it was actually delivered.
    private func notify(_ target: UpdateTarget, version: String) async -> Bool {
        guard let installation = target.record.installations.first else { return false }
        let job = RefreshJob(recordID: target.record.id, deviceID: installation.deviceID)
        return await onAppUpdateAvailable?(AppUpdateNotice(appName: target.name, version: version, job: job, id: target.noticeID)) ?? false
    }

    /// Cancels a background auto-install for an app (from « Annuler » in the « Mises à jour » tab).
    /// Best-effort: it cancels the download, then the install at its next cancellation point.
    func cancelAutoInstall(recordID: UUID) {
        for (key, task) in autoInstallTasks where key.recordID == recordID { task.cancel() }
    }

    /// Auto mode but no reachable device: notify that the update is pending. Returns whether delivered.
    private func notifyAutoPending(_ target: UpdateTarget, version: String) async -> Bool {
        guard let installation = target.record.installations.first else { return false }
        let job = RefreshJob(recordID: target.record.id, deviceID: installation.deviceID)
        return await onAppUpdatePending?(AppUpdateNotice(appName: target.name, version: version, job: job, id: target.noticeID)) ?? false
    }

    /// XSide started an auto-install: a notification whose tap opens the tab to watch the progress.
    private func notifyInstalling(_ target: UpdateTarget, version: String) {
        guard let installation = target.record.installations.first else { return }
        let job = RefreshJob(recordID: target.record.id, deviceID: installation.deviceID)
        onAppInstalling?(AppUpdateNotice(appName: target.name, version: version, job: job, id: target.noticeID))
    }

    /// XSide auto-installed an update: a confirmation notification (it replaces the "available" one).
    private func notifyUpdated(_ target: UpdateTarget, version: String) {
        guard let installation = target.record.installations.first else { return }
        let job = RefreshJob(recordID: target.record.id, deviceID: installation.deviceID)
        onAppUpdated?(AppUpdateNotice(appName: target.name, version: version, job: job, id: target.noticeID))
    }

    /// The release was announced to the person (notify-dedup): the next pass won't notify it again.
    private func markAnnounced(_ trigger: String, for target: UpdateTarget) async {
        await mutateSource(for: target) { $0.lastSeenTrigger = trigger }
    }

    /// XSide installed this release: it becomes the baseline, so a check is up to date until a newer
    /// release appears. Its trigger is marked announced too (no stale "available" notice).
    private func markInstalled(_ found: FoundRelease, for target: UpdateTarget) async {
        await mutateSource(for: target) { $0.installedTag = found.tag; $0.installedTrigger = found.trigger; $0.lastSeenTrigger = found.trigger }
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
    func installableIPAs(of repo: GitHubSource) async throws -> [(tag: String, isPrerelease: Bool, asset: ReleaseAsset)] {
        let work = libraryRoot.appendingPathComponent(AppLibrary.stagingFolder).appendingPathComponent("updates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        return try await ReleaseFinder.fetchInstallableAssets(source: repo, kind: .ipa, fetcher: repoFetcher, workDir: work)
    }

    /// After the import: the install window's GitHub link, mode and chosen variant become the
    /// record's update source. Nothing without a valid link and a chosen variant.
    func persistUpdateSource(from draft: OptionsDraft, recordID: UUID) {
        guard let repo = GitHubSource.parse(draft.updateSourceURL), let variant = draft.updateVariant else { return }
        let source = UpdateSource(repo: repo, variant: variant, mode: draft.updateMode, lastSeenTrigger: nil,
                                  installedTag: draft.updateInstalledTag, checkInterval: draft.updateInterval)
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
