import Testing
import Foundation
@testable import XSideCore

@Suite struct BackupMatchingTests {
    private func snap(_ id: String, _ bundle: String, _ device: String) -> BackupSnapshot {
        BackupSnapshot(id: id, signedBundleID: bundle, deviceID: device, deviceName: "iPhone",
                       createdAt: Date(timeIntervalSince1970: 0), byteSize: 1, fileCount: 1,
                       includedCaches: false, appVersion: nil)
    }

    @Test func orphans_excludesInstalledPairs() {
        let now = Date()
        let record = AppRecord(id: UUID(), displayName: "A", originalBundleID: "com.a", signedBundleID: "com.a.T",
                               ipaPath: "a.ipa", options: InstallOptions(),
                               installations: [Installation(deviceID: "D1", installedAt: now, expiresAt: now)],
                               teamID: "T")
        let installed = snap("1", "com.a.T", "D1")
        let removedDevice = snap("2", "com.a.T", "D2")
        let removedApp = snap("3", "com.b.T", "D1")
        let result = BackupMatching.orphans(snapshots: [installed, removedDevice, removedApp], records: [record])
        #expect(result.map(\.id) == ["2", "3"])
    }

    @Test func importTarget_refusesManifestMismatch() {
        func manifest(_ id: String) -> BackupManifest {
            BackupManifest(originalBundleID: "com.a", signedBundleID: id, teamID: "T", deviceID: "D1", deviceName: "x",
                           createdAt: Date(timeIntervalSince1970: 0), includedCaches: false, appVersion: nil, xsideVersion: "1")
        }
        #expect(BackupMatching.manifestAllows(manifest("com.a.T"), targetSignedBundleID: "com.a.T"))
        #expect(!BackupMatching.manifestAllows(manifest("com.b.T"), targetSignedBundleID: "com.a.T"))
        #expect(BackupMatching.manifestAllows(nil, targetSignedBundleID: "com.a.T"))
    }
}
