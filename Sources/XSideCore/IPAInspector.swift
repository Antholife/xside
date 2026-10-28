import Foundation

public struct AppInfo: Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public let version: String?
    public let executable: String

    public init(bundleID: String, name: String, version: String?, executable: String) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.executable = executable
    }
}

public enum IPAInspector {
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
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { throw XSideError.invalidIPA("Info.plist illisible") }
        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw XSideError.invalidIPA("Info.plist sans CFBundleIdentifier")
        }
        guard let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty else {
            throw XSideError.invalidIPA("Info.plist sans CFBundleExecutable")
        }
        let name = (plist["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (plist["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? app.deletingPathExtension().lastPathComponent
        return AppInfo(bundleID: bundleID, name: name,
                       version: plist["CFBundleShortVersionString"] as? String, executable: executable)
    }

    /// True if any slice of the Mach-O carries an LC_ENCRYPTION_INFO(_64) with cryptid != 0.
    public static func isEncrypted(_ machO: URL) throws -> Bool {
        let data: Data
        do { data = try Data(contentsOf: machO, options: .mappedIfSafe) }
        catch { throw XSideError.invalidIPA("Exécutable illisible") }
        guard let magicBE = readU32(data, 0, bigEndian: true) else { throw bad() }
        switch magicBE {
        case 0xCAFEBABE, 0xCAFEBABF:
            let is64 = magicBE == 0xCAFEBABF
            guard let n = readU32(data, 4, bigEndian: true) else { throw bad() }
            let entry = is64 ? 32 : 20
            var found = false
            for i in 0..<Int(n) {
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
                if try sliceEncrypted(data, at: Int(off)) { found = true }
            }
            return found
        default:
            return try sliceEncrypted(data, at: 0)
        }
    }

    private static func bad() -> XSideError { .invalidIPA("Mach-O invalide") }

    private static func sliceEncrypted(_ data: Data, at start: Int) throws -> Bool {
        guard let magic = readU32(data, start, bigEndian: false) else { throw bad() }
        let headerSize: Int
        let encCmd: UInt32
        switch magic {
        case 0xFEEDFACF: headerSize = 32; encCmd = 0x2C
        case 0xFEEDFACE: headerSize = 28; encCmd = 0x21
        default: throw bad()
        }
        guard let ncmds = readU32(data, start + 16, bigEndian: false) else { throw bad() }
        var pos = start + headerSize
        for _ in 0..<ncmds {
            guard let cmd = readU32(data, pos, bigEndian: false),
                  let size = readU32(data, pos + 4, bigEndian: false), size >= 8 else { throw bad() }
            if cmd == encCmd {
                guard let cryptid = readU32(data, pos + 16, bigEndian: false) else { throw bad() }
                return cryptid != 0
            }
            pos += Int(size)
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
