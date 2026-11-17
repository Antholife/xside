import Foundation
import XSideCore

extension AppModel {
    /// Outcome of a full backup: how many apps were written, and the names of those that could not be
    /// (device unreachable, missing IPA…).
    struct FullBackupResult {
        var saved: Int
        var failedApps: [String]
    }

    /// Which aspects can be included for this installation right now (greys the sheet's columns).
    /// Compatibility / in-app / tweaks need the IPA; data needs the device reachable to capture it.
    func fullBackupAvailability(record: AppRecord, installation: Installation, dataReachable: Bool) -> BackupAspects {
        BackupAspects(
            app: !record.ipaPath.isEmpty,
            compat: installation.duoCompatibility != nil || installation.iCloudSignedOut != nil,
            inApp: installation.inApp != nil,
            tweaks: !(installation.tweaks ?? []).isEmpty,
            data: dataReachable)
    }

    /// Assembles the chosen apps into one `.xsbak` archive at `dest`. Read-only on the device apart
    /// from a fresh data capture for each app whose Données is chosen. Best-effort per app: a failure
    /// is collected, never aborts the rest.
    func makeFullBackup(selections: [(entry: AppEntry, chosen: BackupAspects)], includeCaches: Bool,
                        to dest: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> FullBackupResult {
        let fm = FileManager.default
        let staging = libraryRoot.appendingPathComponent(AppLibrary.stagingFolder)
            .appendingPathComponent("fullbackup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        guard (try? fm.createDirectory(at: staging, withIntermediateDirectories: true)) != nil else {
            return FullBackupResult(saved: 0, failedApps: selections.map { $0.entry.record.displayName })
        }

        var entries: [BackupAppEntry] = []
        var failed: [String] = []
        let total = max(selections.count, 1)

        for (i, sel) in selections.enumerated() {
            defer { progress(Double(i + 1) / Double(total)) }
            let record = records.first { $0.id == sel.entry.record.id } ?? sel.entry.record
            let installation = record.installations.first { $0.deviceID == sel.entry.installation.deviceID } ?? sel.entry.installation
            let name = record.options.displayName ?? record.displayName
            let avail = fullBackupAvailability(record: record, installation: installation, dataReachable: isReachable(sel.entry))
            let inc = FullBackup.backupInclusion(available: avail, chosen: sel.chosen)
            guard FullBackup.isIncluded(inc) else { continue }

            let key = "\(record.id.uuidString)-\(installation.deviceID)"
            let appDir = staging.appendingPathComponent("apps/\(key)", isDirectory: true)
            var cfg = InstallationConfig(sourceDeviceID: installation.deviceID,
                                         sourceDeviceName: deviceDisplayName(installation.deviceID),
                                         appVersion: record.version,
                                         withoutXSideFeatures: installation.withoutXSideFeatures)
            var hasIPA = false, ipaBytes = 0, tweakFiles: [String: String] = [:]
            do {
                try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
                if inc.app {
                    let ipaDst = appDir.appendingPathComponent("original.ipa")
                    try fm.copyItem(at: libraryRoot.appendingPathComponent(record.ipaPath), to: ipaDst)
                    ipaBytes = (try? fm.attributesOfItem(atPath: ipaDst.path)[.size] as? Int) ?? 0
                    hasIPA = true
                    if inc.compat { cfg.duoCompatibility = installation.duoCompatibility; cfg.iCloudSignedOut = installation.iCloudSignedOut }
                    if inc.inApp { cfg.inApp = installation.inApp }
                    if inc.tweaks {
                        let tweaksDir = appDir.appendingPathComponent("tweaks", isDirectory: true)
                        for t in installation.tweaks ?? [] {
                            let src = library.tweakDirectory(recordID: record.id, id: t.id)
                            guard fm.fileExists(atPath: src.path) else { continue }
                            try BackupArchive.copyTreeWithoutSymlinks(from: src, to: tweaksDir.appendingPathComponent(t.id, isDirectory: true))
                            tweakFiles[t.id] = t.id
                        }
                        cfg.tweaks = installation.tweaks ?? []
                    }
                }
            } catch {
                failed.append(name); continue
            }

            var hasData = false, dataBytes = 0, dataCaches = includeCaches
            if inc.data, let (zip, snap) = await captureDataForBackup(record: record, installation: installation, includeCaches: includeCaches) {
                if (try? fm.copyItem(at: zip, to: appDir.appendingPathComponent("data.zip"))) != nil {
                    hasData = true; dataBytes = snap.byteSize; dataCaches = snap.includedCaches
                }
                cleanupExport(zip)
            }

            if hasIPA || hasData {
                entries.append(BackupAppEntry(recordID: record.id, displayName: name, originalBundleID: record.originalBundleID,
                                              options: record.options, updateSource: inc.app ? record.updateSource : nil,
                                              installation: cfg, hasIPA: hasIPA, hasData: hasData, dataIncludesCaches: dataCaches,
                                              ipaBytes: ipaBytes, dataBytes: dataBytes, tweakFiles: tweakFiles))
            } else {
                failed.append(name)
            }
        }

        guard !entries.isEmpty else { return FullBackupResult(saved: 0, failedApps: failed) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let manifest = FullBackupManifest(createdAt: Date(), appVersion: version, apps: entries)
        do {
            try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
            try BackupArchive.packTree(staging, to: dest)
        } catch {
            return FullBackupResult(saved: 0, failedApps: selections.map { $0.entry.record.displayName })
        }
        return FullBackupResult(saved: entries.count, failedApps: failed)
    }

    /// Captures the app's data now (a fresh snapshot, caches per the toggle) and exports it to a zip.
    /// Returns the zip and its snapshot, or nil when the device can't be reached.
    private func captureDataForBackup(record: AppRecord, installation: Installation,
                                      includeCaches: Bool) async -> (URL, BackupSnapshot)? {
        let signed = installation.signedBundleID ?? record.signedBundleID
        do {
            let snap = try await withKnownXcode {
                try await self.backupService.backUp(signedBundleID: signed, deviceID: installation.deviceID,
                                                    deviceName: self.deviceDisplayName(installation.deviceID),
                                                    appVersion: record.version, includeCaches: includeCaches,
                                                    cycleStartedAt: installation.firstInstalledAt ?? installation.installedAt,
                                                    retention: Self.backupRetention, onlyIfChanged: false)
            }
            guard let snap, let zip = await exportBackup(snap.id) else { return nil }
            return (zip, snap)
        } catch {
            return nil
        }
    }

    /// Removes a temporary export zip and its `xside-export-…` folder.
    private func cleanupExport(_ zip: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: zip)
        let parent = zip.deletingLastPathComponent()
        if parent.lastPathComponent.hasPrefix("xside-export-") { try? fm.removeItem(at: parent) }
    }
}
