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
    case available(version: String)
    /// Several files fit the variant: the person picks (only a manual check says so).
    case needsVariantChoice
    case failed(String)
}

struct UpdateCheckReport: Sendable, Equatable {
    let name: String
    let result: UpdateCheckResult
}

extension AppModel {
    private static let updateLogger = Logger(subsystem: "app.xside", category: "updates")

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
              UpdateSchedule.isDue(lastChecked: lastUpdateCheck, now: now) else { return }
        let targets = records.flatMap(updateTargets(of:))
        // Nothing to look at is a look done: asked again after a day, not at every tick.
        guard !targets.isEmpty else { lastUpdateCheck = now; return }
        updateCheckRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { updateCheckRunning = false }
            let reports = await runUpdateChecks(targets)
            // Every source failing (offline, rate limited) is no look done: the next tick tries again.
            let reached = reports.contains { if case .failed = $0.result { false } else { true } }
            if reached { lastUpdateCheck = now }
        }
    }

    /// A manual check of one app and its tweaks (the fiche's button), whatever the schedule says.
    /// Unlike the background pass it reports a variant to choose and every failure.
    func checkUpdatesNow(_ entry: AppEntry) async -> [UpdateCheckReport] {
        await runUpdateChecks(updateTargets(of: entry.record))
    }

    private func runUpdateChecks(_ targets: [UpdateTarget]) async -> [UpdateCheckReport] {
        let work = libraryRoot.appendingPathComponent(AppLibrary.stagingFolder).appendingPathComponent("updates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let checker = UpdateChecker(fetcher: repoFetcher, runner: runner, workDir: work)
        // Two sources asking the same thing of the same repo (same variant, kind and installed
        // version) are answered by one look.
        var answers: [String: UpdateOutcome] = [:]
        var reports: [UpdateCheckReport] = []
        for target in targets {
            guard let source = target.source else { continue }
            let key = "\(source.repo.id)|\(source.variant)|\(target.kind)|\(target.installedVersion ?? "")|\(source.lastSeenTrigger ?? "")"
            let outcome: UpdateOutcome
            if let known = answers[key] {
                outcome = known
            } else {
                outcome = await checker.check(source: source, kind: target.kind, installedVersion: target.installedVersion)
                answers[key] = outcome
            }
            reports.append(UpdateCheckReport(name: target.name, result: await route(outcome, for: target)))
        }
        return reports
    }

    private func route(_ outcome: UpdateOutcome, for target: UpdateTarget) async -> UpdateCheckResult {
        switch outcome {
        case .upToDate(let trigger):
            await persistTrigger(trigger, for: target)
            return .upToDate
        case .needsVariantChoice:
            return .needsVariantChoice
        case .failed(let reason):
            // Tried again next time. The reason is the checker's, never a release's contents.
            Self.updateLogger.notice("update check failed for \(target.name, privacy: .public): \(reason, privacy: .public)")
            return .failed(reason)
        case .available(let found, let version, let stable):
            var result = UpdateCheckResult.available(version: version)
            var persist = true
            let auto = stable && target.source?.mode == .auto
            if auto, let device = deviceForAutoUpdate(target.record) {
                switch await apply(target, device: device, found: found, stable: stable) {
                case .installed(let installed): return await persisted(found.trigger, target, .installed(version: installed))
                case .upToDate: return await persisted(found.trigger, target, .upToDate)
                case .notify(let v, _): result = .available(version: v)
                case .incompatible: break
                case .failed(let reason):
                    Self.updateLogger.notice("auto update failed for \(target.name, privacy: .public): \(reason, privacy: .public)")
                    persist = false // tried again next time
                }
            }
            // Auto but no device to install on: announced, and not marked seen, so the install
            // happens once a device is back.
            if auto, deviceForAutoUpdate(target.record) == nil { persist = false }
            if case .available(let v) = result { notify(target, version: v) }
            if persist { await persistTrigger(found.trigger, for: target) }
            return result
        }
    }

    private enum Applied { case installed(String), upToDate, notify(String, NotifyReason), incompatible, failed(String) }

    private func apply(_ target: UpdateTarget, device: Device, found: FoundRelease, stable: Bool) async -> Applied {
        if let tweak = target.tweak {
            switch await applyTweakUpdate(old: tweak, recordID: target.record.id, device: device, found: found, stable: stable) {
            case .installed(let v): return .installed(v)
            case .upToDate: return .upToDate
            case .notify(let v, let r): return .notify(v, r)
            case .incompatible: return .incompatible
            case .failed(let m): return .failed(m)
            }
        }
        switch await applyAppUpdate(record: target.record, device: device, found: found, stable: stable) {
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

    private func persisted(_ trigger: String?, _ target: UpdateTarget, _ result: UpdateCheckResult) async -> UpdateCheckResult {
        await persistTrigger(trigger, for: target)
        return result
    }

    /// Remembers the release acted on (or announced) so the next look doesn't repeat it. The record
    /// is read again: an update that swapped a tweak changed its id.
    private func persistTrigger(_ trigger: String?, for target: UpdateTarget) async {
        guard let trigger else { return }
        do {
            if let old = target.tweak {
                guard let record = await library.records().first(where: { $0.id == target.record.id }),
                      let tweak = record.tweaks?.first(where: { $0.packageID == old.packageID && $0.updateSource != nil }),
                      var source = tweak.updateSource, source.lastSeenTrigger != trigger else { return }
                source.lastSeenTrigger = trigger
                try await library.setUpdateSource(source, forTweak: tweak.id, recordID: record.id)
            } else {
                guard let record = await library.records().first(where: { $0.id == target.record.id }),
                      var source = record.updateSource, source.lastSeenTrigger != trigger else { return }
                source.lastSeenTrigger = trigger
                try await library.setUpdateSource(source, forRecord: record.id)
            }
            await reloadRecords()
        } catch {
            Self.updateLogger.error("update source not saved: \(String(describing: error), privacy: .public)")
        }
    }
}
