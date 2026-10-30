import Foundation

/// Reads an `.ipa` before it enters the library: unzips it to a scratch directory, extracts its
/// `AppInfo` and refuses App Store (encrypted) builds right away. The scratch copy is always removed.
public enum IPAImporter {
    private static let log = Log("import")

    /// `iconDestination`: where to write the app's own icon (PNG), best effort. `iconHelper`: the
    /// executable that extracts it in a child process (see `AppIconExtractor.runHelper`); nil
    /// extracts in this process (tests).
    public static func inspect(ipa: URL, runner: CommandRunning,
                               scratchRoot: URL = FileManager.default.temporaryDirectory,
                               iconDestination: URL? = nil, iconHelper: URL? = nil) async throws -> AppInfo {
        let size = (try? ipa.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { "\($0 / 1_048_576) MB" } ?? "? MB"
        log.notice("inspecting \(ipa.lastPathComponent) (\(size))")
        do {
            let info = try await read(ipa: ipa, runner: runner, scratchRoot: scratchRoot,
                                      iconDestination: iconDestination, iconHelper: iconHelper)
            log.notice("read \(info.bundleID) \(info.version ?? "?") (executable \(info.executable))")
            return info
        } catch {
            log.error("refused \(ipa.lastPathComponent): \(error)")
            throw error
        }
    }

    private static func read(ipa: URL, runner: CommandRunning, scratchRoot: URL,
                             iconDestination: URL?, iconHelper: URL?) async throws -> AppInfo {
        let fm = FileManager.default
        let dir = scratchRoot.appendingPathComponent("xside-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let unzip = try await ZipLimits.extract(ipa, to: dir, runner: runner)
        guard unzip.status == 0 else { throw XSideError.invalidIPA("Couldn't unzip the IPA") }

        // Never follow links out of the archive, even just to read.
        try require(.typeDirectory, dir.appendingPathComponent("Payload"))
        let app = try IPAInspector.appBundle(in: dir)
        try require(.typeDirectory, app)
        try require(.typeRegular, app.appendingPathComponent("Info.plist"))
        let info = try IPAInspector.info(of: app)
        let executable = app.appendingPathComponent(info.executable)
        try require(.typeRegular, executable)
        if try IPAInspector.isEncrypted(executable) { throw XSideError.encryptedIPA }
        let entitlements = IPAInspector.embeddedEntitlements(executable)
        let shared = Resigner.sharedGroupNames(entitlements)
        if let iconDestination {
            if let iconHelper {
                _ = await AppIconExtractor.extractInSubprocess(helper: iconHelper, app: app,
                                                               destination: iconDestination, runner: runner)
            } else if let data = try? IPAInspector.infoPlistData(of: app),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                AppIconExtractor.extract(from: app, plist: plist, to: iconDestination)
            }
        }
        return AppInfo(bundleID: info.bundleID, name: info.name, version: info.version,
                       executable: info.executable, sharedKeychainGroups: shared,
                       sharedKeychainVendor: shared.isEmpty ? nil : Resigner.keychainVendor(entitlements))
    }

    private static func require(_ type: FileAttributeType, _ url: URL) throws {
        let actual = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        guard actual == type else {
            throw XSideError.invalidIPA("\(url.lastPathComponent) isn't of the expected type")
        }
    }
}
