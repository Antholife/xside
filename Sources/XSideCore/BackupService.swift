import Foundation

/// What a restore did to the container before pushing the snapshot back.
public enum RestoreClear: Sendable { case overlay, clearedContainer }

/// Backs an app's data container up and restores it. A protocol so the pipeline can inject a fake.
public protocol DataBackingUp: Sendable {
    /// `progress(filesDone, filesTotal, bytesDone, bytesTotal)` is called after each pulled file
    /// (any thread); `(0, 0, 0, 0)` once when the total is unknown (whole-container fallback).
    func backUp(signedBundleID: String, deviceID: String, deviceName: String, appVersion: String?,
                includeCaches: Bool, cycleStartedAt: Date?, retention: Int, onlyIfChanged: Bool,
                progress: @escaping @Sendable (_ filesDone: Int, _ filesTotal: Int, _ bytesDone: Int64, _ bytesTotal: Int64) -> Void) async throws -> BackupSnapshot?
    func restore(_ snapshot: BackupSnapshot, toSignedBundleID: String, deviceID: String,
                 executable: String, clear: Bool) async throws -> RestoreClear
    /// Restores the snapshot with this id; nil when no snapshot has it (nothing to restore).
    func restore(snapshotID: String, toSignedBundleID: String, deviceID: String,
                 executable: String, clear: Bool) async throws -> RestoreClear?
    /// Forgets every snapshot of this app on this device.
    func deleteBackups(signedBundleID: String, deviceID: String) async
}

/// Turns the backup's progress counters into a 0...1 fraction.
public enum BackupProgress {
    /// Bytes when their total is known (smoother with uneven files), else files; nil when unknown.
    public static func fraction(filesDone: Int, filesTotal: Int, bytesDone: Int64, bytesTotal: Int64) -> Double? {
        if bytesTotal > 0 { return min(max(Double(bytesDone) / Double(bytesTotal), 0), 1) }
        if filesTotal > 0 { return min(max(Double(filesDone) / Double(filesTotal), 0), 1) }
        return nil
    }
}

public struct BackupService: DataBackingUp {
    private let store: AppDataBackup
    private let container: AppDataContainer

    public init(store: AppDataBackup, container: AppDataContainer) {
        self.store = store
        self.container = container
    }

    public func backUp(signedBundleID: String, deviceID: String, deviceName: String, appVersion: String?,
                       includeCaches: Bool, cycleStartedAt: Date? = nil, retention: Int = 3, onlyIfChanged: Bool = true,
                       progress: @escaping @Sendable (Int, Int, Int64, Int64) -> Void = { _, _, _, _ in }) async throws -> BackupSnapshot? {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("xside-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        let excluded = Self.excludedPrefixes(includeCaches: includeCaches)
        if let entries = try await container.listFiles(signedBundleID: signedBundleID, deviceID: deviceID) {
            let paths = Self.pullPaths(entries, excluded: excluded)
            let sizes = Dictionary(entries.map { ($0.relativePath, Int64($0.size ?? 0)) }, uniquingKeysWith: { a, _ in a })
            let bytesTotal = paths.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            var bytesDone: Int64 = 0
            for (i, path) in paths.enumerated() {
                let dest = temp.appendingPathComponent(path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await container.pull(signedBundleID: signedBundleID, deviceID: deviceID, relativePath: path, to: dest)
                bytesDone += sizes[path] ?? 0
                progress(i + 1, paths.count, bytesDone, bytesTotal)
            }
        } else {
            // Listing unavailable (unsupported, or the device blinked): copy everything, then prune.
            progress(0, 0, 0, 0) // unknown total: indeterminate
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
                                              appVersion: appVersion, cycleStartedAt: cycleStartedAt, retention: retention)
    }

    public func restore(_ snapshot: BackupSnapshot, toSignedBundleID: String, deviceID: String,
                        executable: String, clear: Bool) async throws -> RestoreClear {
        try await container.terminate(executable: executable, deviceID: deviceID)
        _ = clear // intentionally unused: see below
        // devicectl has no verified way to empty a container, so a restore is always an overlay.
        try await container.push(signedBundleID: toSignedBundleID, deviceID: deviceID,
                                 from: await store.snapshotDir(snapshot), relativePath: "/")
        return .overlay
    }

    public func restore(snapshotID: String, toSignedBundleID: String, deviceID: String,
                        executable: String, clear: Bool) async throws -> RestoreClear? {
        guard let snapshot = await store.snapshot(snapshotID) else { return nil }
        return try await restore(snapshot, toSignedBundleID: toSignedBundleID, deviceID: deviceID,
                                 executable: executable, clear: clear)
    }

    public func deleteBackups(signedBundleID: String, deviceID: String) async {
        try? await store.deleteAll(signedBundleID: signedBundleID, deviceID: deviceID)
    }

    static func excludedPrefixes(includeCaches: Bool) -> [String] {
        AppDataContainer.excludedPrefixes + (includeCaches ? [] : [AppDataContainer.cachesPrefix])
    }

    /// Every file of the listing outside the excluded prefixes. Derived from file entries only, so
    /// it doesn't depend on the listing carrying directory entries.
    static func pullPaths(_ entries: [ContainerEntry], excluded: [String]) -> [String] {
        entries.filter { !$0.isDirectory && !excluded.contains(where: $0.relativePath.hasPrefix) }
            .map(\.relativePath).sorted()
    }
}
