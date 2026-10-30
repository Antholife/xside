import Foundation

public struct AppInfo: Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public let version: String?
    public let executable: String
    /// Keychain groups the app asks to share with its vendor's other apps ("com.google.common.SSO"),
    /// granted only if the user opts in (`InstallOptions.shareKeychain`).
    public let sharedKeychainGroups: [String]
    /// The vendor those groups are allowed for ("com.google"), from the same source as the
    /// allowlist (the embedded `application-identifier`, see `Resigner.keychainVendor`).
    public let sharedKeychainVendor: String?

    public init(bundleID: String, name: String, version: String?, executable: String,
                sharedKeychainGroups: [String] = [], sharedKeychainVendor: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.executable = executable
        self.sharedKeychainGroups = sharedKeychainGroups
        self.sharedKeychainVendor = sharedKeychainVendor
    }
}

/// Bundle identifiers XSide signs with (a custom one, or the default `<original>.<TEAM>`):
/// letters, digits and hyphens in dot-separated parts, at most 155 characters (Apple's App ID
/// rules). An imported app's own identifier may also contain "_" (older apps do; it is never
/// registered as is), see `isValidOriginal` and `defaultSigned`.
public enum BundleIdentifier {
    public static let maxLength = 155

    public static func isValid(_ id: String) -> Bool { check(id, extra: "-") }

    /// An identifier found in an imported app.
    public static func isValidOriginal(_ id: String) -> Bool { check(id, extra: "-_") }

    /// The identifier an import is signed with by default: the app's own, "_" turned into "-"
    /// (App IDs can't hold "_"), then `.<TEAM>`. Validate the result: it may pass 155 characters.
    public static func defaultSigned(original: String, teamID: String) -> String {
        "\(original.replacingOccurrences(of: "_", with: "-")).\(teamID)"
    }

    private static func check(_ id: String, extra: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= maxLength else { return false }
        let allowed = Set(extra.unicodeScalars)
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || allowed.contains($0))
            }
        }
    }
}

public enum IPAInspector {
    /// An `Info.plist` larger than this is refused unread.
    public static let maxInfoPlistBytes = 1024 * 1024
    /// More slices than any real fat binary has (arm64, arm64e, armv7…).
    static let maxFatArchs: UInt32 = 16

    /// The bundle's `Info.plist` bytes, refused past `maxInfoPlistBytes`.
    public static func infoPlistData(of app: URL) throws -> Data {
        let url = app.appendingPathComponent("Info.plist")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        guard let size else { throw XSideError.invalidIPA("Info.plist illisible") }
        guard size <= maxInfoPlistBytes else { throw XSideError.invalidIPA("Info.plist trop volumineux") }
        guard let data = try? Data(contentsOf: url) else { throw XSideError.invalidIPA("Info.plist illisible") }
        return data
    }

    /// `payloadParent` is the directory containing `Payload/`.
    public static func appBundle(in payloadParent: URL) throws -> URL {
        let payload = payloadParent.appendingPathComponent("Payload")
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: payload, includingPropertiesForKeys: nil) else {
            throw XSideError.invalidIPA("Dossier Payload introuvable")
        }
        let apps = items.filter { $0.pathExtension == "app" }
        guard apps.count == 1 else {
            throw XSideError.invalidIPA(apps.isEmpty ? "Aucune app dans Payload" : "Plusieurs apps dans Payload")
        }
        return apps[0]
    }

    public static func info(of app: URL) throws -> AppInfo {
        let data = try infoPlistData(of: app)
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { throw XSideError.invalidIPA("Info.plist illisible") }
        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw XSideError.invalidIPA("Info.plist sans CFBundleIdentifier")
        }
        guard BundleIdentifier.isValidOriginal(bundleID) else {
            throw XSideError.invalidIPA("CFBundleIdentifier invalide")
        }
        guard let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty else {
            throw XSideError.invalidIPA("Info.plist sans CFBundleExecutable")
        }
        guard !executable.contains("/"), executable != ".", executable != ".." else {
            throw XSideError.invalidIPA("CFBundleExecutable invalide")
        }
        let name = (plist["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (plist["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? app.deletingPathExtension().lastPathComponent
        return AppInfo(bundleID: bundleID, name: name,
                       version: plist["CFBundleShortVersionString"] as? String, executable: executable)
    }

    /// True if any slice of the Mach-O carries an LC_ENCRYPTION_INFO(_64) with cryptid != 0.
    public static func isEncrypted(_ machO: URL) throws -> Bool {
        let data = try machOData(machO)
        var found = false
        for start in try sliceOffsets(data) where try sliceEncrypted(data, at: start) { found = true }
        return found
    }

    /// Largest entitlements blob read.
    static let maxEntitlementsBytes = 1024 * 1024

    /// The entitlements embedded in the Mach-O's code signature (first slice of a fat binary), nil
    /// when it is unsigned, has none, or anything about it is malformed. Read straight from the
    /// `LC_CODE_SIGNATURE` super blob (`CSSLOT_ENTITLEMENTS`, XML plist), with no tool involved.
    public static func embeddedEntitlements(_ machO: URL) -> [String: Any]? {
        guard let data = try? machOData(machO), let start = try? sliceOffsets(data).first,
              let commands = try? loadCommands(data, at: start),
              let signature = commands.first(where: { $0.cmd == 0x1D }), // LC_CODE_SIGNATURE
              let dataoff = readU32(data, signature.pos + 8, bigEndian: false),
              let datasize = readU32(data, signature.pos + 12, bigEndian: false) else { return nil }
        let blob = start + Int(dataoff)
        guard UInt64(start) + UInt64(dataoff) + UInt64(datasize) <= UInt64(data.count),
              readU32(data, blob, bigEndian: true) == 0xFADE_0CC0, // CSMAGIC_EMBEDDED_SIGNATURE
              let length = readU32(data, blob + 4, bigEndian: true), length <= datasize,
              let count = readU32(data, blob + 8, bigEndian: true), UInt64(count) * 8 + 12 <= UInt64(length)
        else { return nil }
        for i in 0..<Int(count) {
            guard readU32(data, blob + 12 + i * 8, bigEndian: true) == 5, // CSSLOT_ENTITLEMENTS
                  let offset = readU32(data, blob + 16 + i * 8, bigEndian: true),
                  UInt64(offset) + 8 <= UInt64(length),
                  readU32(data, blob + Int(offset), bigEndian: true) == 0xFADE_7171, // CSMAGIC_EMBEDDED_ENTITLEMENTS
                  let size = readU32(data, blob + Int(offset) + 4, bigEndian: true),
                  size >= 8, size <= maxEntitlementsBytes, UInt64(offset) + UInt64(size) <= UInt64(length)
            else { continue }
            let from = data.startIndex + blob + Int(offset) + 8
            let plist = data.subdata(in: from..<(from + Int(size) - 8))
            return (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any]
        }
        return nil
    }

    private static func machOData(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw XSideError.invalidIPA("Exécutable illisible") }
    }

    /// Start of each slice: every architecture of a fat binary (at most `maxFatArchs`), else 0.
    private static func sliceOffsets(_ data: Data) throws -> [Int] {
        guard let magicBE = readU32(data, 0, bigEndian: true) else { throw bad() }
        guard magicBE == 0xCAFEBABE || magicBE == 0xCAFEBABF else { return [0] }
        let is64 = magicBE == 0xCAFEBABF
        guard let n = readU32(data, 4, bigEndian: true), n <= maxFatArchs else { throw bad() }
        let entry = is64 ? 32 : 20
        return try (0..<Int(n)).map { i in
            let base = 8 + i * entry
            let off: UInt64
            if is64 {
                guard let o = readU64(data, base + 8, bigEndian: true) else { throw bad() }
                off = o
            } else {
                guard let o = readU32(data, base + 8, bigEndian: true) else { throw bad() }
                off = UInt64(o)
            }
            guard off < UInt64(data.count) else { throw bad() }
            return Int(off)
        }
    }

    private static func bad() -> XSideError { .invalidIPA("Mach-O invalide") }

    /// The load commands of the slice at `start` (`pos`: offset of each command in `data`), with
    /// every size checked against `sizeofcmds` and the file.
    private static func loadCommands(_ data: Data, at start: Int) throws -> [(cmd: UInt32, pos: Int)] {
        guard let magic = readU32(data, start, bigEndian: false) else { throw bad() }
        let headerSize: Int
        switch magic {
        case 0xFEEDFACF: headerSize = 32
        case 0xFEEDFACE: headerSize = 28
        default: throw bad()
        }
        guard let ncmds = readU32(data, start + 16, bigEndian: false),
              let sizeofcmds = readU32(data, start + 20, bigEndian: false) else { throw bad() }
        // Every command is 8 bytes at least, and all of them fit in the file after the header.
        let commandsStart = start + headerSize
        guard UInt64(ncmds) * 8 <= UInt64(sizeofcmds),
              UInt64(sizeofcmds) <= UInt64(max(0, data.count - commandsStart)) else { throw bad() }
        let commandsEnd = commandsStart + Int(sizeofcmds)
        var pos = commandsStart
        var result: [(cmd: UInt32, pos: Int)] = []
        for _ in 0..<ncmds {
            guard pos + 8 <= commandsEnd,
                  let cmd = readU32(data, pos, bigEndian: false),
                  let size = readU32(data, pos + 4, bigEndian: false), size >= 8,
                  UInt64(size) <= UInt64(commandsEnd - pos) else { throw bad() }
            result.append((cmd, pos))
            pos += Int(size)
        }
        return result
    }

    private static func sliceEncrypted(_ data: Data, at start: Int) throws -> Bool {
        let is64 = readU32(data, start, bigEndian: false) == 0xFEEDFACF
        let encCmd: UInt32 = is64 ? 0x2C : 0x21
        for command in try loadCommands(data, at: start) where command.cmd == encCmd {
            guard let cryptid = readU32(data, command.pos + 16, bigEndian: false) else { throw bad() }
            return cryptid != 0
        }
        return false
    }

    private static func readU32(_ d: Data, _ offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset <= d.count - 4 else { return nil }
        let s = d.startIndex + offset
        let v = (UInt32(d[s]) << 24) | (UInt32(d[s + 1]) << 16) | (UInt32(d[s + 2]) << 8) | UInt32(d[s + 3])
        return bigEndian ? v : v.byteSwapped
    }

    private static func readU64(_ d: Data, _ offset: Int, bigEndian: Bool) -> UInt64? {
        guard let hi = readU32(d, offset, bigEndian: bigEndian),
              let lo = readU32(d, offset + 4, bigEndian: bigEndian) else { return nil }
        return bigEndian ? (UInt64(hi) << 32) | UInt64(lo) : (UInt64(lo) << 32) | UInt64(hi)
    }
}
