import Testing
import Foundation
@testable import XSideCore

@Suite struct FullBackupTests {
    static func entry(hasIPA: Bool, hasData: Bool, duo: Bool? = nil, iCloud: Bool? = nil,
                      inApp: InAppSettings? = nil, tweaks: [TweakUse] = [],
                      ipaBytes: Int = 100, dataBytes: Int = 10) -> BackupAppEntry {
        BackupAppEntry(recordID: UUID(), displayName: "App", originalBundleID: "com.x.app",
                       options: InstallOptions(),
                       installation: InstallationConfig(sourceDeviceID: "D1", sourceDeviceName: "iPhone",
                                                        duoCompatibility: duo, iCloudSignedOut: iCloud,
                                                        inApp: inApp, tweaks: tweaks),
                       hasIPA: hasIPA, hasData: hasData, dataIncludesCaches: false,
                       ipaBytes: ipaBytes, dataBytes: dataBytes, tweakFiles: [:])
    }

    // MARK: Manifest round-trip

    @Test func manifest_encodesAndDecodesBackToEqual() throws {
        let inApp = InAppSettings.defaults(reminder: true, at: Date(timeIntervalSince1970: 1000))
        let src = UpdateSource(repo: GitHubSource(owner: "itzzace", repo: "ytkace"),
                               variant: VariantSelector(stableTokens: ["ytkace"], excludedTokens: []),
                               mode: .notify, installedTag: "v1.1.8")
        let cfg = InstallationConfig(sourceDeviceID: "D1", sourceDeviceName: "iPhone 13", appVersion: "1.1.8",
                                     duoCompatibility: true, iCloudSignedOut: false, withoutXSideFeatures: nil,
                                     inApp: inApp, tweaks: [TweakUse(id: "pkg.a"), TweakUse(id: "pkg.b", enabled: false)])
        let e = BackupAppEntry(recordID: UUID(), displayName: "YTKACE", originalBundleID: "com.google.ios.youtube",
                               options: InstallOptions(), updateSource: src, installation: cfg, hasIPA: true,
                               hasData: true, dataIncludesCaches: true, ipaBytes: 142, dataBytes: 12,
                               tweakFiles: ["pkg.a": "a.deb"])
        let m = FullBackupManifest(createdAt: Date(timeIntervalSince1970: 2000), appVersion: "1.2.0", apps: [e])

        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(FullBackupManifest.self, from: data)
        #expect(back == m)
        #expect(back.version == FullBackupManifest.currentVersion)
        #expect(back.apps.first?.updateSource?.repo.repo == "ytkace")
    }

    // MARK: availableAspects

    @Test func availableAspects_reflectWhatWasStored() {
        let full = Self.entry(hasIPA: true, hasData: true, duo: true, inApp: .defaults(reminder: true, at: Date()),
                              tweaks: [TweakUse(id: "a")])
        #expect(full.availableAspects == BackupAspects.all)

        let ipaOnly = Self.entry(hasIPA: true, hasData: false)
        #expect(ipaOnly.availableAspects == BackupAspects(app: true))

        let dataOnly = Self.entry(hasIPA: false, hasData: true, duo: true, tweaks: [TweakUse(id: "a")])
        // No IPA: compat/in-app/tweaks can't be available even though the config carries values.
        #expect(dataOnly.availableAspects == BackupAspects(data: true))
    }

    // MARK: Backup inclusion

    @Test func backupInclusion_configRidesWithApp() {
        let avail = BackupAspects.all
        let inc = FullBackup.backupInclusion(available: avail, chosen: BackupAspects(app: true, compat: true, inApp: true, tweaks: true, data: true))
        #expect(inc == BackupAspects.all)
    }

    @Test func backupInclusion_dropsConfigWhenAppUnchecked() {
        let avail = BackupAspects.all
        let inc = FullBackup.backupInclusion(available: avail, chosen: BackupAspects(app: false, compat: true, inApp: true, tweaks: true, data: true))
        // compat/in-app/tweaks need app; only data survives.
        #expect(inc == BackupAspects(data: true))
    }

    @Test func backupInclusion_cannotIncludeWhatIsNotAvailable() {
        let avail = BackupAspects(app: true, compat: false, inApp: false, tweaks: false, data: false)
        let inc = FullBackup.backupInclusion(available: avail, chosen: BackupAspects.all)
        #expect(inc == BackupAspects(app: true))
    }

    @Test func isIncluded_requiresAppOrData() {
        #expect(FullBackup.isIncluded(BackupAspects()) == false)
        #expect(FullBackup.isIncluded(BackupAspects(app: true)))
        #expect(FullBackup.isIncluded(BackupAspects(data: true)))
        #expect(FullBackup.isIncluded(BackupAspects(compat: true)) == false) // compat without app is meaningless
    }

    // MARK: Restore action

    @Test func restore_reinstallWithChosenConfigAndData() {
        let a = FullBackup.restoreAction(available: .all, chosen: .all)
        #expect(a == .reinstall(compat: true, inApp: true, tweaks: true, data: true))
    }

    @Test func restore_reinstallDropsUnavailableAspects() {
        let avail = BackupAspects(app: true, compat: false, inApp: true, tweaks: false, data: true)
        let a = FullBackup.restoreAction(available: avail, chosen: .all)
        #expect(a == .reinstall(compat: false, inApp: true, tweaks: false, data: true))
    }

    @Test func restore_reinstallCanOptOutOfConfig() {
        let a = FullBackup.restoreAction(available: .all, chosen: BackupAspects(app: true, compat: false, inApp: false, tweaks: false, data: false))
        #expect(a == .reinstall(compat: false, inApp: false, tweaks: false, data: false))
    }

    @Test func restore_dataOnlyWhenAppNotChosen() {
        let a = FullBackup.restoreAction(available: .all, chosen: BackupAspects(app: false, data: true))
        #expect(a == .dataOnly)
    }

    @Test func restore_dataOnlyWhenArchiveHasNoIPA() {
        let avail = BackupAspects(app: false, data: true)
        let a = FullBackup.restoreAction(available: avail, chosen: BackupAspects(app: true, data: true))
        #expect(a == .dataOnly)
    }

    @Test func restore_skipWhenNothingUsable() {
        #expect(FullBackup.restoreAction(available: .all, chosen: BackupAspects()) == .skip)
        #expect(FullBackup.restoreAction(available: BackupAspects(app: false, data: false), chosen: .all) == .skip)
    }

    // MARK: Sizing & counts

    @Test func entryBytes_sumsStoredParts() {
        #expect(FullBackup.entryBytes(BackupAspects(app: true, data: true), ipaBytes: 100, dataBytes: 10) == 110)
        #expect(FullBackup.entryBytes(BackupAspects(app: true), ipaBytes: 100, dataBytes: 10) == 100)
        #expect(FullBackup.entryBytes(BackupAspects(data: true), ipaBytes: 100, dataBytes: 10) == 10)
        #expect(FullBackup.entryBytes(BackupAspects(), ipaBytes: 100, dataBytes: 10) == 0)
    }

    @Test func restoreCount_ignoresSkips() {
        #expect(FullBackup.restoreCount([.reinstall(compat: true, inApp: true, tweaks: true, data: true), .dataOnly, .skip]) == 2)
    }
}
