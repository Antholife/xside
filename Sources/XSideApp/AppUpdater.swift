import Foundation
import XSideCore

/// Why an app update was not installed by itself: the engine words the notification from this.
enum NotifyReason: Sendable, Equatable { case prerelease, suspect, notifyMode }

enum AppUpdateResult: Sendable, Equatable {
    case installed(version: String)
    case notify(version: String, reason: NotifyReason)
    case incompatible
    case failed(String)
}

enum TweakUpdateResult: Sendable, Equatable {
    case installed(version: String)
    /// The downloaded package is byte-identical to the one in the pool: nothing to do, not a failure.
    case upToDate(version: String)
    case notify(version: String, reason: NotifyReason)
    case incompatible
    case failed(String)
}

extension AppModel {
    /// Downloads a found `.deb` of a tracked tweak, checks it is the same tweak, and swaps it into
    /// the app's pool only when the tweak is on auto AND the release is stable with a usable
    /// verdict. Otherwise says why it did not; the engine posts the notification.
    func applyTweakUpdate(old: TweakPackage, recordID: UUID, device: Device, found: FoundRelease, stable: Bool) async -> TweakUpdateResult {
        let fm = FileManager.default
        let work = libraryRoot.appendingPathComponent(AppLibrary.stagingFolder).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: work) }
        let deb = work.appendingPathComponent("update.deb")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try await UpdateApply.downloadAsset(found.asset, kind: .deb, to: deb, fetcher: repoFetcher)
        } catch {
            return .failed("download: \(error)")
        }
        // Checked from a scratch copy first: a wrong one never enters the app's pool.
        let scratch = work.appendingPathComponent("scratch")
        let checked: TweakPackage
        do {
            checked = try await TweakAnalyzer.analyze(deb, into: scratch, runner: runner, now: Date())
        } catch {
            return .failed("analyze: \(error)")
        }
        guard UpdateApply.packageIDMatches(checked.packageID, oldPackageID: old.packageID) else { return .incompatible }
        guard let record = records.first(where: { $0.id == recordID }) else { return .failed("the app is gone") }
        let version = checked.version ?? found.tag
        let verdict = TweakClassifier.verdict(checked, entryContext(record, old.id, on: device.id))
        let isAuto = old.updateSource?.mode == .auto
        // Injected code: its binaries are scanned (from the scratch copy) before anything is written.
        let hasSigns = !IPAContentScanner.warningSigns(of: checked, in: scratch).isEmpty
        guard isAuto, UpdateApply.tweakAutoAllowed(verdict: verdict, stable: stable, hasSigns: hasSigns) else {
            var suspect = hasSigns
            if case .incompatible = verdict { suspect = true }
            let reason: NotifyReason = !stable ? .prerelease : (suspect ? .suspect : .notifyMode)
            return .notify(version: version, reason: reason)
        }
        do {
            // Same path as the manual replace: store in the pool (comes back as `replacing`), swap.
            let (package, replacing) = try await library.addTweak(deb, recordID: recordID, deviceIDs: [], runner: runner, now: Date())
            guard replacing != nil else { return .upToDate(version: version) }
            try await library.replaceTweak(old.id, with: package, recordID: recordID)
            await reloadRecords()
            refreshNow(RefreshJob(recordID: recordID, deviceID: device.id))
            return .installed(version: version)
        } catch {
            return .failed("install: \(error)")
        }
    }

    /// Downloads a found release of an app, checks it is the same app, and installs it over the
    /// installed one only when the app is on auto AND the release is stable with no warning sign.
    /// Otherwise says why it did not; the engine posts the notification.
    func applyAppUpdate(record: AppRecord, device: Device, found: FoundRelease, stable: Bool) async -> AppUpdateResult {
        let fm = FileManager.default
        let work = libraryRoot.appendingPathComponent(AppLibrary.stagingFolder).appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: work) }
        let ipa = work.appendingPathComponent("update.ipa")
        let info: AppInfo
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try await UpdateApply.downloadAsset(found.asset, kind: .ipa, to: ipa, fetcher: repoFetcher)
        } catch {
            return .failed("download: \(error)")
        }
        do {
            info = try await IPAImporter.inspect(ipa: ipa, runner: runner)
        } catch {
            return .failed("inspect: \(error)")
        }
        guard UpdateApply.bundleIDMatches(info.bundleID, originalBundleID: record.originalBundleID) else {
            return .incompatible
        }
        let version = info.version ?? found.tag
        let isAuto = record.updateSource?.mode == .auto
        let allowed = UpdateApply.autoAllowed(content: info.content, stable: stable)
        guard isAuto, allowed else {
            let reason: NotifyReason = !stable ? .prerelease : (isAuto ? .suspect : .notifyMode)
            return .notify(version: version, reason: reason)
        }
        do {
            // No `importedInto`: that would reinstall the stored (old) IPA. Without it the new IPA is
            // imported over the record found by bundle id (same id, options and data kept).
            let updated = try await importAndInstall(ipa, on: device)
            guard UpdateApply.applied(storedVersion: updated.version, expected: info.version) else {
                return .failed("update not applied: stored \(updated.version ?? "nil") != \(info.version ?? "nil")")
            }
            return .installed(version: version)
        } catch {
            return .failed("install: \(error)")
        }
    }
}
