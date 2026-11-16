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
        try fm.copyItem(at: snapshotDir, to: staging.appendingPathComponent(treeName, isDirectory: true))
        try encoder().encode(manifest).write(to: staging.appendingPathComponent(manifestName))
        try? fm.removeItem(at: zipURL)  // zip would otherwise append to an existing archive
        try fm.createDirectory(at: zipURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = try run("/usr/bin/zip", ["-q", "-r", "-y", "-X", zipURL.path, "."], cwd: staging)
        guard r.status == 0 else { throw BackupArchiveError.toolFailed(tool: "zip", status: r.status) }
    }

    /// nil when the archive has no `xside-backup.json` or it is not valid manifest JSON.
    public static func readManifest(zipURL: URL) throws -> BackupManifest? {
        let r = try run("/usr/bin/unzip", ["-p", zipURL.path, manifestName], cwd: nil)
        guard r.status == 0 else { return nil }  // 11 = entry not found
        return try? decoder().decode(BackupManifest.self, from: r.output)
    }

    public static func unpack(zipURL: URL, to dir: URL) throws -> (manifest: BackupManifest?, contentDir: URL) {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = try run("/usr/bin/unzip", ["-q", "-o", zipURL.path, "-d", dir.path], cwd: nil)
        guard r.status == 0 else { throw BackupArchiveError.toolFailed(tool: "unzip", status: r.status) }
        let manifest = (try? Data(contentsOf: dir.appendingPathComponent(manifestName)))
            .flatMap { try? decoder().decode(BackupManifest.self, from: $0) }
        let tree = dir.appendingPathComponent(treeName, isDirectory: true)
        var isDir: ObjCBool = false
        let hasTree = manifest != nil && fm.fileExists(atPath: tree.path, isDirectory: &isDir) && isDir.boolValue
        return (manifest, hasTree ? tree : dir)
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
