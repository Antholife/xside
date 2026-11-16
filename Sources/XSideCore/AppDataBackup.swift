import Foundation
import CryptoKit

/// One backed-up copy of an app's data container.
public struct BackupSnapshot: Codable, Equatable, Sendable {
    public let id: String // ISO8601 directory name
    public let signedBundleID: String
    public let deviceID: String
    public let deviceName: String
    public let createdAt: Date
    public let byteSize: Int
    public let fileCount: Int
    public let includedCaches: Bool
    public let appVersion: String?

    public init(id: String, signedBundleID: String, deviceID: String, deviceName: String, createdAt: Date,
                byteSize: Int, fileCount: Int, includedCaches: Bool, appVersion: String?) {
        self.id = id; self.signedBundleID = signedBundleID; self.deviceID = deviceID
        self.deviceName = deviceName; self.createdAt = createdAt; self.byteSize = byteSize
        self.fileCount = fileCount; self.includedCaches = includedCaches; self.appVersion = appVersion
    }
}

public struct BackupIndex: Codable, Equatable, Sendable {
    public var snapshots: [BackupSnapshot]
    public init(snapshots: [BackupSnapshot] = []) { self.snapshots = snapshots }
}

/// On-disk snapshot store under `<library root>/app-data/<signedBundleID>/<deviceID>/<id>/`.
/// Unchanged files (same relative path, size and content; mtimes are ignored) are hard-linked from the newest prior snapshot of the pair.
/// Snapshot contents are the user's private data: only counts, sizes and ids are ever reported.
public actor AppDataBackup {
    private let base: URL
    private var indexURL: URL { base.appendingPathComponent("index.json") }
    private let fm = FileManager.default
    private let log = Log("backup")

    /// Name of the store's subfolder under the library root.
    public static let folderName = "app-data"

    /// `root` is the library root; the store lives in `root/app-data`.
    public init(root: URL) {
        self.base = root.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    public func list() -> [BackupSnapshot] {
        loadIndex().snapshots.sorted { $0.createdAt > $1.createdAt }
    }

    public func list(signedBundleID: String, deviceID: String? = nil) -> [BackupSnapshot] {
        list().filter { $0.signedBundleID == signedBundleID && (deviceID == nil || $0.deviceID == deviceID) }
    }

    public func snapshot(_ id: String) -> BackupSnapshot? {
        loadIndex().snapshots.first { $0.id == id }
    }

    public func snapshotDir(_ s: BackupSnapshot) -> URL {
        pairDir(s.signedBundleID, s.deviceID).appendingPathComponent(s.id, isDirectory: true)
    }

    public func createSnapshot(from sourceDir: URL, signedBundleID: String, deviceID: String, deviceName: String,
                               includedCaches: Bool, appVersion: String?, retention: Int = 3,
                               now: Date = Date()) throws -> BackupSnapshot {
        let pair = pairDir(signedBundleID, deviceID)
        try fm.createDirectory(at: pair, withIntermediateDirectories: true)

        var index = loadIndex()
        let previous = index.snapshots
            .filter { $0.signedBundleID == signedBundleID && $0.deviceID == deviceID }
            .max { $0.createdAt < $1.createdAt }
            .map { snapshotDir($0) }

        var id = Self.makeID(now)
        var n = 1
        while fm.fileExists(atPath: pair.appendingPathComponent(id).path) { n += 1; id = Self.makeID(now) + "-\(n)" }
        let final = pair.appendingPathComponent(id, isDirectory: true)
        let staging = pair.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)

        var bytes = 0, files = 0
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            (bytes, files) = try copyTree(from: sourceDir, to: staging, linkingFrom: previous)
            try fm.moveItem(at: staging, to: final)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        let snap = BackupSnapshot(id: id, signedBundleID: signedBundleID, deviceID: deviceID, deviceName: deviceName,
                                  createdAt: now, byteSize: bytes, fileCount: files,
                                  includedCaches: includedCaches, appVersion: appVersion)
        index.snapshots.append(snap)

        let mine = index.snapshots
            .filter { $0.signedBundleID == signedBundleID && $0.deviceID == deviceID }
            .sorted { $0.createdAt > $1.createdAt }
        for old in mine.dropFirst(max(retention, 1)) {
            try? fm.removeItem(at: snapshotDir(old))
            index.snapshots.removeAll { $0.id == old.id && $0.signedBundleID == old.signedBundleID && $0.deviceID == old.deviceID }
        }
        try saveIndex(index)
        return snap
    }

    public func delete(_ id: String) throws {
        var index = loadIndex()
        for s in index.snapshots where s.id == id { try removeIfPresent(snapshotDir(s)) }
        index.snapshots.removeAll { $0.id == id }
        try saveIndex(index)
    }

    public func deleteAll(signedBundleID: String, deviceID: String? = nil) throws {
        var index = loadIndex()
        for s in index.snapshots where s.signedBundleID == signedBundleID && (deviceID == nil || s.deviceID == deviceID) {
            try removeIfPresent(snapshotDir(s))
        }
        index.snapshots.removeAll { $0.signedBundleID == signedBundleID && (deviceID == nil || $0.deviceID == deviceID) }
        try saveIndex(index)
    }

    /// Sum of file sizes counting each inode once, so hard-linked history isn't double-counted.
    public func totalBytes() -> Int {
        guard let e = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { return 0 }
        var seen = Set<String>()
        var total = 0
        for case let url as URL in e {
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            if seen.insert("\(st.st_dev):\(st.st_ino)").inserted { total += Int(st.st_size) }
        }
        return total
    }

    /// True when both trees hold the same regular files (by relative path) with equal size and content.
    /// Modification times are ignored: `devicectl` does not preserve them.
    static func contentUnchanged(_ a: URL, _ b: URL) -> Bool {
        let ma = fileSizes(a), mb = fileSizes(b)
        guard ma == mb else { return false }
        for (rel, _) in ma {
            guard let ha = sha256(a.appendingPathComponent(rel).path),
                  let hb = sha256(b.appendingPathComponent(rel).path), ha == hb else { return false }
        }
        return true
    }

    // MARK: - Internals

    private func pairDir(_ bundleID: String, _ deviceID: String) -> URL {
        base.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent(deviceID, isDirectory: true)
    }

    private func removeIfPresent(_ url: URL) throws {
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    private func loadIndex() -> BackupIndex {
        guard let data = try? Data(contentsOf: indexURL),
              let idx = try? JSONDecoder().decode(BackupIndex.self, from: data) else { return BackupIndex() }
        return idx
    }

    private func saveIndex(_ index: BackupIndex) throws {
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(index).write(to: indexURL, options: .atomic)
    }

    private static func makeID(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    private static func fileSizes(_ root: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return out }
        for case let rel as String in e {
            var st = stat()
            guard lstat(root.appendingPathComponent(rel).path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            out[rel] = Int(st.st_size)
        }
        return out
    }

    /// Streamed SHA-256 of a file's bytes; nil when unreadable.
    private static func sha256(_ path: String) -> SHA256.Digest? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            // read(upToCount:) returns nil (not empty Data) at EOF.
            let chunk: Data
            do { chunk = try h.read(upToCount: 1 << 20) ?? Data() } catch { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    /// Copies `source` into `dest` (which exists), linking files unchanged vs `previous`. Returns (bytes, files).
    /// The source is untrusted app content: entries are addressed by their unresolved relative path, unsafe
    /// paths and symlinks are skipped (only a count is logged), and no parent of a write target may be a symlink.
    private func copyTree(from source: URL, to dest: URL, linkingFrom previous: URL?) throws -> (Int, Int) {
        guard let e = fm.enumerator(atPath: source.path) else { return (0, 0) }
        var bytes = 0, files = 0, skipped = 0
        for case let rel as String in e {
            let comps = rel.split(separator: "/", omittingEmptySubsequences: false)
            if rel.hasPrefix("/") || rel.isEmpty || comps.contains("..") || comps.contains("") { skipped += 1; continue }
            let src = source.appendingPathComponent(rel)
            let target = dest.appendingPathComponent(rel)
            var st = stat()
            guard lstat(src.path, &st) == 0 else { continue }
            let kind = st.st_mode & S_IFMT
            if kind != S_IFDIR && kind != S_IFLNK && kind != S_IFREG { continue }
            guard Self.parentsAreRealDirs(of: rel, under: dest) else { skipped += 1; continue }
            switch kind {
            case S_IFDIR:
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
            case S_IFLNK:
                guard let dst = try? fm.destinationOfSymbolicLink(atPath: src.path),
                      Self.symlinkStaysInside(dst, parent: src.deletingLastPathComponent()) else { skipped += 1; continue }
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: dst)
            default:
                let prior = previous.map { $0.appendingPathComponent(rel) }
                if let previous, let prior, Self.parentsAreRealDirs(of: rel, under: previous),
                   Self.sameFile(prior.path, src.path, st), link(prior.path, target.path) == 0 {
                    // hard-linked
                } else {
                    try fm.copyItem(at: src, to: target)
                }
                bytes += Int(st.st_size); files += 1
            }
        }
        if skipped > 0 { log.notice("backup skipped \(skipped) unsafe entr\(skipped == 1 ? "y" : "ies")") }
        return (bytes, files)
    }

    /// True when no directory above `rel` (inside `root`) is a symlink or missing.
    private static func parentsAreRealDirs(of rel: String, under root: URL) -> Bool {
        var cur = root
        for c in rel.split(separator: "/").dropLast() {
            cur = cur.appendingPathComponent(String(c))
            var st = stat()
            guard lstat(cur.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        }
        return true
    }

    /// A symlink is kept only when its destination is relative, has no `..` component, and no intermediate
    /// component of it (resolved under the link's parent in the source tree) is itself a symlink.
    private static func symlinkStaysInside(_ dest: String, parent: URL) -> Bool {
        if dest.hasPrefix("/") || dest.isEmpty { return false }
        let comps = dest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if comps.contains("..") || comps.dropLast().contains("") { return false }
        var cur = parent
        for c in comps.dropLast() where c != "." {
            cur = cur.appendingPathComponent(c)
            var st = stat()
            guard lstat(cur.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        }
        return true
    }

    /// Same size, then same content (SHA-256); mtime is never consulted.
    private static func sameFile(_ path: String, _ srcPath: String, _ src: stat) -> Bool {
        var p = stat()
        guard lstat(path, &p) == 0, (p.st_mode & S_IFMT) == S_IFREG, p.st_size == src.st_size else { return false }
        guard let a = sha256(path), let b = sha256(srcPath) else { return false }
        return a == b
    }
}
