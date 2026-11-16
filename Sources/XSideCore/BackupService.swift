import Foundation

/// What a restore did to the container before pushing the snapshot back.
public enum RestoreClear: Sendable { case overlay, clearedContainer }

/// Backs an app's data container up and restores it. A protocol so the pipeline can inject a fake.
public protocol DataBackingUp: Sendable {
    func backUp(signedBundleID: String, deviceID: String, deviceName: String, appVersion: String?,
                includeCaches: Bool, retention: Int, onlyIfChanged: Bool) async throws -> BackupSnapshot?
    func restore(_ snapshot: BackupSnapshot, toSignedBundleID: String, deviceID: String,
                 executable: String, clear: Bool) async throws -> RestoreClear
}

public struct BackupService: DataBackingUp {
    private let store: AppDataBackup
    private let container: AppDataContainer

    public init(store: AppDataBackup, container: AppDataContainer) {
        self.store = store
        self.container = container
    }

    public func backUp(signedBundleID: String, deviceID: String, deviceName: String, appVersion: String?,
                       includeCaches: Bool, retention: Int = 3, onlyIfChanged: Bool = true) async throws -> BackupSnapshot? {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("xside-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        let excluded = Self.excludedPrefixes(includeCaches: includeCaches)
        if let entries = try await container.listFiles(signedBundleID: signedBundleID, deviceID: deviceID) {
            for path in Self.pullPaths(entries, excluded: excluded) {
                let dest = temp.appendingPathComponent(path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await container.pull(signedBundleID: signedBundleID, deviceID: deviceID, relativePath: path, to: dest)
            }
        } else {
            // Listing unavailable (unsupported, or the device blinked): copy everything, then prune.
            try await container.pull(signedBundleID: signedBundleID, deviceID: deviceID, relativePath: "/", to: temp)
            for prefix in excluded {
                try? fm.removeItem(at: temp.appendingPathComponent(String(prefix.dropLast())))
            }
        }

        if onlyIfChanged,
           let newest = await store.list(signedBundleID: signedBundleID, deviceID: deviceID).first,
           AppDataBackup.contentUnchanged(temp, await store.snapshotDir(newest)) {
            return nil
        }
        return try await store.createSnapshot(from: temp, signedBundleID: signedBundleID, deviceID: deviceID,
                                              deviceName: deviceName, includedCaches: includeCaches,
                                              appVersion: appVersion, retention: retention)
    }

    public func restore(_ snapshot: BackupSnapshot, toSignedBundleID: String, deviceID: String,
                        executable: String, clear: Bool) async throws -> RestoreClear {
        try await container.terminate(executable: executable, deviceID: deviceID)
        // devicectl has no verified way to empty a container, so a restore is always an overlay.
        try await container.push(signedBundleID: toSignedBundleID, deviceID: deviceID,
                                 from: await store.snapshotDir(snapshot), relativePath: "/")
        return .overlay
    }

    static func excludedPrefixes(includeCaches: Bool) -> [String] {
        AppDataContainer.excludedPrefixes + (includeCaches ? [] : [AppDataContainer.cachesPrefix])
    }

    /// The smallest set of paths covering the listing without touching an excluded prefix: a
    /// directory holding an excluded descendant is split into its children.
    static func pullPaths(_ entries: [ContainerEntry], excluded: [String]) -> [String] {
        func parent(_ p: String) -> String { p.contains("/") ? String(p[..<p.lastIndex(of: "/")!]) : "" }
        func isExcluded(_ p: String) -> Bool { excluded.contains { (p + "/").hasPrefix($0) } }
        func holdsExcluded(_ p: String) -> Bool { excluded.contains { $0.hasPrefix(p + "/") } }
        let byParent = Dictionary(grouping: entries.map(\.relativePath), by: parent)
        let dirs = Set(entries.filter(\.isDirectory).map(\.relativePath))
        func walk(_ dir: String) -> [String] {
            (byParent[dir] ?? []).sorted().flatMap { child -> [String] in
                if isExcluded(child) { return [] }
                if dirs.contains(child), holdsExcluded(child) { return walk(child) }
                return [child]
            }
        }
        return walk("")
    }
}
