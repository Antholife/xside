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
    func checkUpdatesIfDue() {
        let now = Date()
        guard hasLoadedRecords, !updateCheckRunning,
              UpdateSchedule.isDue(lastChecked: lastUpdateCheck, lastFailure: lastUpdateFailure, now: now) else { return }
        let targets = records.flatMap(updateTargets(of:))
        // Nothing to look at is a look done: asked again after a day, not at every tick.
        guard !targets.isEmpty else { lastUpdateCheck = now; return }
        updateCheckRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { updateCheckRunning = false }
            let reports = await runUpdateChecks(targets)
            // Every source failing (offline, rate limited) is no look done: tried again after
            // `UpdateSchedule.failureInterval`, not at the next tick (that would burn the rate limit).
            let reached = reports.contains { if case .failed = $0.result { false } else { true } }
            if reached { lastUpdateCheck = now; lastUpdateFailure = nil } else { lastUpdateFailure = now }
        }
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
        let checker = UpdateChecker(fetcher: repoFetcher, runner: runner, workDir: work)
        // Two sources asking the same thing of the same repo (same variant, kind and installed
        // version) are answered by one look.
        var answers: [String: UpdateOutcome] = [:]
        var reports: [UpdateCheckReport] = []
        for target in targets {
            guard let source = target.source else { continue }
            // A manual check reports the true state from the cached version (no re-download); the
            // background pass announces a release once. Neither writes the trigger back on a manual run.
            let key = "\(source.repo.id)|\(source.variant)|\(target.kind)|\(target.installedVersion ?? "")|\(source.lastSeenTrigger ?? "")|\(userInitiated)"
            let outcome: UpdateOutcome
            if let known = answers[key] {
                outcome = known
            } else {
                outcome = await checker.check(source: source, kind: target.kind, installedVersion: target.installedVersion,
                                              reportCachedAvailable: userInitiated)
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
        let checker = UpdateChecker(fetcher: repoFetcher, runner: runner, workDir: work)
        switch await checker.check(source: source, kind: target.kind, installedVersion: target.installedVersion) {
        case .upToDate: return .upToDate
        case .needsVariantChoice: return .needsVariantChoice
        case .failed(let reason): return .failed(reason)
        case .available(let found, let version, let stable):
            // The release changed since the card: nothing installs under the earlier approval.
            guard found.tag == expectedTag, found.asset.name == expectedAsset else {
                return .changed
            }
            switch await apply(target, device: device, found: found, stable: stable, userInitiated: true, approved: approved) {
            case .installed(let v):
                await persistTrigger(found.trigger, version: nil, for: target)
                return .installed(version: v)
            case .upToDate:
                await persistTrigger(found.trigger, version: nil, for: target)
                return .upToDate
            case .notify(let v, let r): return .available(version: v, reason: r, tag: found.tag, asset: found.asset.name)
            case .incompatible: return .failed("incompatible")
            case .failed(let m): return .failed(m)
            }
        }
    }

    private func route(_ outcome: UpdateOutcome, for target: UpdateTarget, userInitiated: Bool = false) async -> UpdateCheckResult {
        // Any full evaluation caches the release (trigger + version) so the next check — manual or
        // background — is answered without re-downloading the file.
        func persist(_ trigger: String?, _ version: String?) async {
            await persistTrigger(trigger, version: version, for: target)
        }
        switch outcome {
        case .upToDate(let trigger):
            await persist(trigger, nil)
            return .upToDate
        case .needsVariantChoice:
            return .needsVariantChoice
        case .failed(let reason):
            // Tried again next time. The reason is the checker's, never a release's contents.
            Self.updateLogger.notice("update check failed for \(target.name, privacy: .public): \(reason, privacy: .public)")
            return .failed(reason)
        case .available(let found, let version, let stable):
            var result = UpdateCheckResult.available(version: version, reason: stable ? .notifyMode : .prerelease, tag: found.tag, asset: found.asset.name)
            var shouldPersist = true
            let auto = stable && target.source?.mode == .auto
            if auto, let device = deviceForAutoUpdate(target.record) {
                switch await apply(target, device: device, found: found, stable: stable) {
                case .installed(let installed): await persist(found.trigger, nil); return .installed(version: installed)
                case .upToDate: await persist(found.trigger, nil); return .upToDate
                case .notify(let v, let reason): result = .available(version: v, reason: reason, tag: found.tag, asset: found.asset.name)
                case .incompatible: break
                case .failed(let reason):
                    Self.updateLogger.notice("auto update failed for \(target.name, privacy: .public): \(reason, privacy: .public)")
                    shouldPersist = false // tried again next time
                }
            }
            // Auto but no device to install on: announced, and not marked seen, so the install
            // happens once a device is back.
            if auto, deviceForAutoUpdate(target.record) == nil { shouldPersist = false }
            // Cache the available version so a later manual check reports it without re-downloading.
            let pendingVersion: String? = { if case .available(let v, _, _, _) = result { v } else { nil } }()
            // The background pass announces; a manual check shows the card itself, no extra notice.
            if let pendingVersion, !userInitiated { notify(target, version: pendingVersion) }
            if shouldPersist { await persist(found.trigger, pendingVersion) }
            return result
        }
    }

    private enum Applied { case installed(String), upToDate, notify(String, NotifyReason), incompatible, failed(String) }

    private func apply(_ target: UpdateTarget, device: Device, found: FoundRelease, stable: Bool, userInitiated: Bool = false, approved: Set<NotifyReason> = []) async -> Applied {
        if let tweak = target.tweak {
            switch await applyTweakUpdate(old: tweak, recordID: target.record.id, device: device, found: found, stable: stable, userInitiated: userInitiated, approved: approved) {
            case .installed(let v): return .installed(v)
            case .upToDate: return .upToDate
            case .notify(let v, let r): return .notify(v, r)
            case .incompatible: return .incompatible
            case .failed(let m): return .failed(m)
            }
        }
        switch await applyAppUpdate(record: target.record, device: device, found: found, stable: stable, userInitiated: userInitiated, approved: approved) {
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

    private func notify(_ target: UpdateTarget, version: String) {
        guard let installation = target.record.installations.first else { return }
        let job = RefreshJob(recordID: target.record.id, deviceID: installation.deviceID)
        onAppUpdateAvailable?(AppUpdateNotice(appName: target.name, version: version, job: job, id: target.noticeID))
    }

    /// Remembers the release acted on (or announced) so the next look doesn't repeat it. The record
    /// is read again: an update that swapped a tweak changed its id.
    private func persistTrigger(_ trigger: String?, version: String?, for target: UpdateTarget) async {
        guard let trigger else { return }
        do {
            if let old = target.tweak {
                guard let record = await library.records().first(where: { $0.id == target.record.id }),
                      let tweak = record.tweaks?.first(where: { $0.packageID == old.packageID && $0.updateSource != nil }),
                      var source = tweak.updateSource,
                      source.lastSeenTrigger != trigger || source.lastSeenVersion != version else { return }
                source.lastSeenTrigger = trigger
                source.lastSeenVersion = version
                try await library.setUpdateSource(source, forTweak: tweak.id, recordID: record.id)
            } else {
                guard let record = await library.records().first(where: { $0.id == target.record.id }),
                      var source = record.updateSource,
                      source.lastSeenTrigger != trigger || source.lastSeenVersion != version else { return }
                source.lastSeenTrigger = trigger
                source.lastSeenVersion = version
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
        let source = UpdateSource(repo: repo, variant: variant, mode: draft.updateMode, lastSeenTrigger: nil)
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
