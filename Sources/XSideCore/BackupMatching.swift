import Foundation

/// Which backups still belong to an installation XSide knows.
public enum BackupMatching {
    /// Snapshots whose (signed bundle id, device) matches no current installation of `records`.
    public static func orphans(snapshots: [BackupSnapshot], records: [AppRecord]) -> [BackupSnapshot] {
        var live = Set<String>()
        for record in records {
            for installation in record.installations {
                live.insert(key(installation.signedBundleID ?? record.signedBundleID, installation.deviceID))
            }
        }
        return snapshots.filter { !live.contains(key($0.signedBundleID, $0.deviceID)) }
    }

    /// An imported zip's manifest is an untrusted hint: with one, it must name the target's signed
    /// bundle id exactly; without one, the caller's explicit target stands.
    public static func manifestAllows(_ manifest: BackupManifest?, targetSignedBundleID: String) -> Bool {
        manifest.map { $0.signedBundleID == targetSignedBundleID } ?? true
    }

    private static func key(_ bundleID: String, _ deviceID: String) -> String { bundleID + "\u{0}" + deviceID }
}
