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
    /// The snapshots XSide keeps for this app on this device, newest first (for the phone's
    /// « Données » page, written at signing). Empty by default.
    func list(signedBundleID: String, deviceID: String) async -> [BackupSnapshot]
}

public extension DataBackingUp {
    func list(signedBundleID: String, deviceID: String) async -> [BackupSnapshot] { [] }
}

/// Turns the backup's progress counters into a 0...1 fraction.
public enum BackupProgress {
    /// The fraction to display: never below the one already shown (reports may arrive out of order).
    public static func monotonic(current: Double?, new: Double?) -> Double? {
        guard let new else { return current }
        return max(current ?? 0, new)
    }

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

    public func list(signedBundleID: String, deviceID: String) async -> [BackupSnapshot] {
        await store.list(signedBundleID: signedBundleID, deviceID: deviceID).sorted { $0.createdAt > $1.createdAt }
    }

    /// Removes `xside-backup-*` folders a backup left behind when the app was killed mid-way. Only
    /// those untouched for `olderThan` seconds: XSide and XSide-debug share the temporary folder, so
    /// a backup running in the other one must survive. Best effort.
    public static func sweepStaleTemps(in root: URL = FileManager.default.temporaryDirectory, olderThan age: TimeInterval = 6 * 3600) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let limit = Date().addingTimeInterval(-age)
        for name in names where name.hasPrefix("xside-backup-") {
            let url = root.appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, modified < limit else { continue }
            try? fm.removeItem(at: url)
        }
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
            // Copy whole clean directories in one devicectl call each, not file by file: an app with
            // hundreds of tiny files (YouTube's logs) is pulled in a handful of calls, not hundreds.
            let targets = Self.copyTargets(entries, excluded: excluded)
            let filesTotal = targets.reduce(0) { $0 + $1.files }
            let bytesTotal = targets.reduce(Int64(0)) { $0 + $1.bytes }
            var filesDone = 0, bytesDone: Int64 = 0
            for t in targets {
                try Task.checkCancellation() // Cancel stops between copies; the defer removes the temp
                let dest = t.path.isEmpty ? temp : temp.appendingPathComponent(t.path)
                let source = t.path.isEmpty ? "/" : (t.isDirectory ? String(t.path.dropLast()) : t.path)
                // devicectl drops the source's contents into an existing destination directory.
                try fm.createDirectory(at: t.isDirectory ? dest : dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try await container.pull(signedBundleID: signedBundleID, deviceID: deviceID, relativePath: source, to: dest)
                filesDone += t.files; bytesDone += t.bytes
                progress(filesDone, filesTotal, bytesDone, bytesTotal)
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

    /// One devicectl copy: a whole directory (`isDirectory`, path ends in `/`, `""` = the whole
    /// container) or a single file. `files`/`bytes` are the kept entries it carries, for progress.
    struct CopyTarget: Equatable {
        let path: String
        let isDirectory: Bool
        let files: Int
        let bytes: Int64
    }

    /// Groups the container's kept files into the fewest copies. A directory is copied whole in one
    /// call unless an excluded subtree (caches, tmp) lies within it — then its ancestors are
    /// "split" and we descend past them to the first directory that is clean. So an app with
    /// hundreds of tiny files under one folder is pulled in a single call, not one call per file.
    /// Derived from file entries only, so it doesn't depend on the listing carrying directory ones.
    static func copyTargets(_ entries: [ContainerEntry], excluded: [String]) -> [CopyTarget] {
        // Every proper directory ancestor of an excluded prefix must be descended into, never copied
        // whole (that would pull the excluded subtree). The container root is "".
        var split: Set<String> = []
        for prefix in excluded {
            let comps = prefix.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            var acc = ""
            split.insert(acc)
            for c in comps.dropLast() { acc += c + "/"; split.insert(acc) }
        }
        // The shallowest directory ancestor of `path` that is clean (not split); if every one is
        // split, the file sits directly in a split directory and is copied on its own.
        func root(of path: String) -> (String, Bool) {
            let dirs = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).dropLast()
            var acc = ""
            var i = 0
            while split.contains(acc) {
                guard i < dirs.count else { return (path, false) }
                acc += dirs[i] + "/"; i += 1
            }
            return (acc, true)
        }
        var order: [String] = []
        var carried: [String: (isDir: Bool, files: Int, bytes: Int64)] = [:]
        for e in entries where !e.isDirectory && !excluded.contains(where: e.relativePath.hasPrefix) {
            let (key, isDir) = root(of: e.relativePath)
            if carried[key] == nil { order.append(key) }
            var agg = carried[key] ?? (isDir, 0, 0)
            agg.files += 1; agg.bytes += Int64(e.size ?? 0)
            carried[key] = agg
        }
        return order.sorted().map {
            CopyTarget(path: $0, isDirectory: carried[$0]!.isDir, files: carried[$0]!.files, bytes: carried[$0]!.bytes)
        }
    }
}
