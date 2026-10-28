import Foundation

/// Reads an `.ipa` before it enters the library: unzips it to a scratch directory, extracts its
/// `AppInfo` and refuses App Store (encrypted) builds right away. The scratch copy is always removed.
public enum IPAImporter {
    public static func inspect(ipa: URL, runner: CommandRunning,
                               scratchRoot: URL = FileManager.default.temporaryDirectory) async throws -> AppInfo {
        let fm = FileManager.default
        let dir = scratchRoot.appendingPathComponent("xside-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let unzip = try await runner.run("/usr/bin/ditto", ["-x", "-k", ipa.path, dir.path], cwd: nil)
        guard unzip.status == 0 else { throw XSideError.invalidIPA("Impossible de décompresser l'IPA") }

        // Never follow links out of the archive, even just to read.
        try require(.typeDirectory, dir.appendingPathComponent("Payload"))
        let app = try IPAInspector.appBundle(in: dir)
        try require(.typeDirectory, app)
        try require(.typeRegular, app.appendingPathComponent("Info.plist"))
        let info = try IPAInspector.info(of: app)
        let executable = app.appendingPathComponent(info.executable)
        try require(.typeRegular, executable)
        if try IPAInspector.isEncrypted(executable) { throw XSideError.encryptedIPA }
        return info
    }

    private static func require(_ type: FileAttributeType, _ url: URL) throws {
        let actual = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        guard actual == type else {
            throw XSideError.invalidIPA("IPA invalide : \(url.lastPathComponent) n'est pas du type attendu")
        }
    }
}
