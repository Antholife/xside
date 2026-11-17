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
            var tweakPool: [TweakPackage] = []
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
                        let ids = Set((installation.tweaks ?? []).map(\.id))
                        tweakPool = (record.tweaks ?? []).filter { ids.contains($0.id) }
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
                                              ipaBytes: ipaBytes, dataBytes: dataBytes, tweakFiles: tweakFiles, tweakPool: tweakPool))
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

    /// Outcome of a restore: how many apps came back, and the names of those that could not.
    struct FullRestoreResult {
        var restored: Int
        var failedApps: [String]
    }

    /// Restores the chosen apps from an `.xsbak` onto `targetDeviceID`. Per app it rebuilds the record
    /// from the archived IPA, re-applies options, update source, compatibility, in-app settings and
    /// tweaks through the normal install pipeline, then reinjects the data. Best-effort per app.
    func restoreFullBackup(archive: URL, selections: [(entry: BackupAppEntry, chosen: BackupAspects)],
                           targetDeviceID: String,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> FullRestoreResult {
        let fm = FileManager.default
        let names = selections.map { $0.entry.displayName }
        let work = libraryRoot.appendingPathComponent(AppLibrary.stagingFolder)
            .appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        guard let extracted = try? BackupArchive.unpackTree(archive, to: work),
              let env = try? environment?.get() else {
            return FullRestoreResult(restored: 0, failedApps: names)
        }

        var restored = 0
        var failed: [String] = []
        let total = max(selections.count, 1)
        for (i, sel) in selections.enumerated() {
            defer { progress(Double(i + 1) / Double(total)) }
            let e = sel.entry
            let action = FullBackup.restoreAction(available: e.availableAspects, chosen: sel.chosen)
            // The manifest comes from a file the person picked: a crafted sourceDeviceID must not let
            // the path escape the extracted folder. recordID is a decoded UUID, so already safe.
            guard Self.isSafePathComponent(e.installation.sourceDeviceID) else { failed.append(e.displayName); continue }
            let appDir = extracted.appendingPathComponent("apps/\(e.recordID.uuidString)-\(e.installation.sourceDeviceID)", isDirectory: true)
            guard Self.isContained(appDir, in: extracted) else { failed.append(e.displayName); continue }
            let dataZip = appDir.appendingPathComponent("data.zip")
            do {
                switch action {
                case .skip:
                    continue
                case .dataOnly:
                    guard let rec = records.first(where: { $0.originalBundleID == e.originalBundleID }),
                          fm.fileExists(atPath: dataZip.path),
                          await importBackup(zip: dataZip, intoRecordID: rec.id, deviceID: targetDeviceID) else {
                        failed.append(e.displayName); continue
                    }
                    restored += 1
                case .reinstall(let compat, let inAppOn, let tweaksOn, let dataOn):
                    guard let device = devices.first(where: { $0.id == targetDeviceID && $0.isAvailable }) else {
                        failed.append(e.displayName); continue
                    }
                    let ipa = appDir.appendingPathComponent("original.ipa")
                    let info = try await IPAImporter.inspect(ipa: ipa, runner: runner)
                    let rec = try await library.importIPA(ipa, info: info, teamID: env.teamID)
                    try await library.setOptions(e.options, for: rec.id)
                    if let src = e.updateSource { try await library.setUpdateSource(src, forRecord: rec.id) }

                    var tweakUses: [TweakUse] = []
                    var held: [String] = []
                    if tweaksOn, !e.tweakPool.isEmpty {
                        let staged = e.tweakPool.compactMap { pkg -> StagedTweak? in
                            guard Self.isSafePathComponent(pkg.id) else { return nil }
                            let dir = appDir.appendingPathComponent("tweaks/\(pkg.id)", isDirectory: true)
                            guard Self.isContained(dir, in: extracted), fm.fileExists(atPath: dir.path) else { return nil }
                            return StagedTweak(package: pkg, directory: dir)
                        }
                        held = try await library.adoptTweaks(staged, recordID: rec.id)
                        tweakUses = e.installation.tweaks
                    }
                    await reloadRecords()
                    let inAppDraft = (inAppOn ? e.installation.inApp : nil)
                        .map { InAppDraft(settings: $0, touched: Set(InAppField.allCases)) }
                    do {
                        _ = try await importAndInstall(ipa, on: device, options: e.options, inApp: inAppDraft,
                                                       duoCompatibility: compat ? e.installation.duoCompatibility : nil,
                                                       iCloudSignedOut: compat ? e.installation.iCloudSignedOut : nil,
                                                       tweaks: tweaksOn ? tweakUses : nil, importedInto: rec.id)
                    } catch {
                        if !held.isEmpty { await library.releaseTweaks(held, recordID: rec.id) }
                        throw error
                    }
                    if !held.isEmpty { await library.releaseTweaks(held, recordID: rec.id) }
                    if dataOn, fm.fileExists(atPath: dataZip.path) {
                        _ = await importBackup(zip: dataZip, intoRecordID: rec.id, deviceID: targetDeviceID)
                    }
                    restored += 1
                }
            } catch {
                failed.append(e.displayName)
            }
        }
        await reloadRecords()
        return FullRestoreResult(restored: restored, failedApps: failed)
    }

    /// Reads an archive's manifest (one entry, no full extraction) for the restore sheet's list.
    func readFullBackupManifest(_ archive: URL) -> FullBackupManifest? {
        guard let data = try? BackupArchive.readFile(archive, named: "manifest.json") else { return nil }
        return try? JSONDecoder().decode(FullBackupManifest.self, from: data)
    }

    /// A manifest-derived path component is safe only when it is a single separator-free ASCII token
    /// (no `/`, `\`, `.`/`..`): the archive is untrusted, so it must never escape the extracted folder.
    static func isSafePathComponent(_ s: String) -> Bool {
        guard !s.isEmpty, s != ".", s != ".." else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    /// True when `url` resolves to `root` or something inside it (belt-and-braces zip-slip guard).
    static func isContained(_ url: URL, in root: URL) -> Bool {
        let r = root.resolvingSymlinksInPath().standardizedFileURL.path
        let p = url.resolvingSymlinksInPath().standardizedFileURL.path
        return p == r || p.hasPrefix(r + "/")
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
