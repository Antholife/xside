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

extension AppModel {
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
            guard UpdateApply.applied(storedVersion: updated.version, expected: version) else {
                return .failed("update not applied: stored \(updated.version ?? "nil") != \(version)")
            }
            return .installed(version: version)
        } catch {
            return .failed("install: \(error)")
        }
    }
}
