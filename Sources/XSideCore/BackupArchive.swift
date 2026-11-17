import Foundation

/// Describes a backup archive: which app, device and signing identity it was taken from.
public struct BackupManifest: Codable, Equatable, Sendable {
    public let schema: Int
    public let originalBundleID: String
    public let signedBundleID: String
    public let teamID: String
    public let deviceID: String
    public let deviceName: String
    public let createdAt: Date
    public let includedCaches: Bool
    public let appVersion: String?
    public let xsideVersion: String

    public init(schema: Int = 1, originalBundleID: String, signedBundleID: String, teamID: String,
                deviceID: String, deviceName: String, createdAt: Date, includedCaches: Bool,
                appVersion: String?, xsideVersion: String) {
        self.schema = schema
        self.originalBundleID = originalBundleID
        self.signedBundleID = signedBundleID
        self.teamID = teamID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.createdAt = createdAt
        self.includedCaches = includedCaches
        self.appVersion = appVersion
        self.xsideVersion = xsideVersion
    }
}

public enum BackupArchiveError: Error, Equatable, Sendable {
    case toolFailed(tool: String, status: Int32)
    /// The archive holds a symlink, an absolute path, a `..` component, or extracted outside the target.
    case unsafeArchive
}

/// Packs a backup snapshot plus a manifest into a `.zip` and reads one back.
///
/// Zip tooling: `/usr/bin/zip` (create) and `/usr/bin/unzip` (extract, read one entry), run through
/// `Process` with absolute paths (no shell). Chosen over `ditto` because `unzip -p` can read the
/// manifest alone without extracting the whole archive.
///
/// Layout: `xside-backup.json` and a `snapshot/` folder at the archive root.
public enum BackupArchive {
    public static let manifestName = "xside-backup.json"
    public static let treeName = "snapshot"

    public static func export(snapshotDir: URL, manifest: BackupManifest, to zipURL: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("xside-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try copyWithoutSymlinks(from: snapshotDir, to: staging.appendingPathComponent(treeName, isDirectory: true))
        try encoder().encode(manifest).write(to: staging.appendingPathComponent(manifestName))
        try? fm.removeItem(at: zipURL)  // zip would otherwise append to an existing archive
        try fm.createDirectory(at: zipURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = try run("/usr/bin/zip", ["-q", "-r", "-X", zipURL.path, "--", "."], cwd: staging)
        guard r.status == 0 else { throw BackupArchiveError.toolFailed(tool: "zip", status: r.status) }
    }

    /// Zips an already-prepared directory as-is (the caller builds the layout, e.g. a full backup's
    /// `manifest.json` + `apps/<id>/…`). The caller must put only regular files and directories in it;
    /// `unpackTree` vets the archive on the way back in.
    public static func packTree(_ dir: URL, to zipURL: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: zipURL)  // zip would otherwise append to an existing archive
        try fm.createDirectory(at: zipURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = try run("/usr/bin/zip", ["-q", "-r", "-X", zipURL.path, "--", "."], cwd: dir)
        guard r.status == 0 else { throw BackupArchiveError.toolFailed(tool: "zip", status: r.status) }
    }

    /// Vets (no symlink, absolute path, `..`, or zip-slip) and extracts an archive into a fresh
    /// subdirectory of `dir`, returning that directory. Used to read a full backup back.
    public static func unpackTree(_ zipURL: URL, to dir: URL) throws -> URL {
        let fm = FileManager.default
        try vet(zipURL: zipURL)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        do {
            let r = try run("/usr/bin/unzip", ["-q", "-d", target.path, "--", zipURL.path], cwd: nil)
            guard r.status == 0 else { throw BackupArchiveError.toolFailed(tool: "unzip", status: r.status) }
            try verifyExtracted(target)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        return target
    }

    /// Reads one entry's bytes from the archive without extracting it (used to peek a full backup's
    /// `manifest.json`). nil when the entry is absent.
    public static func readFile(_ zipURL: URL, named name: String) throws -> Data? {
        let r = try run("/usr/bin/unzip", ["-p", "--", zipURL.path, name], cwd: nil)
        return r.status == 0 ? r.output : nil
    }

    /// nil when the archive has no `xside-backup.json` or it is not valid manifest JSON.
    public static func readManifest(zipURL: URL) throws -> BackupManifest? {
        let r = try run("/usr/bin/unzip", ["-p", "--", zipURL.path, manifestName], cwd: nil)
        guard r.status == 0 else { return nil }  // 11 = entry not found
        return try? decoder().decode(BackupManifest.self, from: r.output)
    }

    public static func unpack(zipURL: URL, to dir: URL) throws -> (manifest: BackupManifest?, contentDir: URL) {
        let fm = FileManager.default
        try vet(zipURL: zipURL)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Extract into a fresh empty subdirectory so nothing pre-existing can be overwritten.
        let target = dir.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        do {
            let r = try run("/usr/bin/unzip", ["-q", "-d", target.path, "--", zipURL.path], cwd: nil)
            guard r.status == 0 else { throw BackupArchiveError.toolFailed(tool: "unzip", status: r.status) }
            try verifyExtracted(target)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        let manifest = (try? Data(contentsOf: target.appendingPathComponent(manifestName)))
            .flatMap { try? decoder().decode(BackupManifest.self, from: $0) }
        let tree = target.appendingPathComponent(treeName, isDirectory: true)
        var isDir: ObjCBool = false
        let hasTree = manifest != nil && fm.fileExists(atPath: tree.path, isDirectory: &isDir) && isDir.boolValue
        return (manifest, hasTree ? tree : target)
    }

    /// Copies a tree into `dst`, dropping any symlink, so the full backup's staging never contains one
    /// (its archive is then symlink-free and `unpackTree` won't reject it). Public for the assembler.
    public static func copyTreeWithoutSymlinks(from src: URL, to dst: URL) throws {
        try copyWithoutSymlinks(from: src, to: dst)
    }

    /// Copies regular files and directories only; symlinks are skipped so archives never contain any
    /// (and zip has nothing to follow, e.g. a cyclic `a -> .`).
    private static func copyWithoutSymlinks(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let base = src.standardizedFileURL.path
        guard let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { return }
        for case let url as URL in en {
            let v = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if v.isSymbolicLink == true { continue }  // enumerator does not descend into symlinks
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let target = dst.appendingPathComponent(rel, isDirectory: v.isDirectory == true)
            if v.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.copyItem(at: url, to: target)
            }
        }
    }

    /// Rejects symlink entries, absolute paths and `..` components before anything is extracted.
    private static func vet(zipURL: URL) throws {
        let names = try run("/usr/bin/unzip", ["-Z1", "--", zipURL.path], cwd: nil)
        guard names.status == 0 else { throw BackupArchiveError.toolFailed(tool: "unzip", status: names.status) }
        for line in String(decoding: names.output, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("/") || line.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
                throw BackupArchiveError.unsafeArchive
            }
        }
        let modes = try run("/usr/bin/unzip", ["-Z", "--", zipURL.path], cwd: nil)
        guard modes.status == 0 else { throw BackupArchiveError.toolFailed(tool: "unzip", status: modes.status) }
        for line in String(decoding: modes.output, as: UTF8.self).split(separator: "\n") where line.hasPrefix("l") {
            throw BackupArchiveError.unsafeArchive
        }
    }

    /// Belt and braces: no symlink anywhere in the extracted tree, nothing resolving outside it.
    private static func verifyExtracted(_ root: URL) throws {
        let fm = FileManager.default
        let rootPath = root.resolvingSymlinksInPath().path
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in en {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw BackupArchiveError.unsafeArchive
            }
            let p = url.resolvingSymlinksInPath().path
            if p != rootPath && !p.hasPrefix(rootPath + "/") { throw BackupArchiveError.unsafeArchive }
        }
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func run(_ tool: String, _ args: [String], cwd: URL?) throws -> (status: Int32, output: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = cwd
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }
}
