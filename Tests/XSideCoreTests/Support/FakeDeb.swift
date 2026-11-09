import Foundation
@testable import XSideCore

/// Builds fake `.deb` archives (ar), tars (ustar + pax) and compressed members for tests.
enum FakeDeb {
    struct Entry {
        enum Kind { case file, directory, symlink, hardlink, charDevice }
        var path: String
        var kind: Kind = .file
        var data = Data()
        var linkTarget = ""
        /// Write the path (and size) in a pax `x` header before the ustar header.
        var paxPath = false
        var paxSize = false
        /// Size written in the ustar header instead of the real one (hostile archives).
        var declaredSize: Int?

        static func file(_ path: String, _ data: Data = Data("x".utf8)) -> Entry { Entry(path: path, data: data) }
        static func dir(_ path: String) -> Entry { Entry(path: path, kind: .directory) }
        static func symlink(_ path: String, to target: String) -> Entry { Entry(path: path, kind: .symlink, linkTarget: target) }
        static func hardlink(_ path: String, to target: String) -> Entry { Entry(path: path, kind: .hardlink, linkTarget: target) }
        static func device(_ path: String) -> Entry { Entry(path: path, kind: .charDevice) }
    }

    // MARK: ar

    static func ar(_ members: [(name: String, data: Data)], bsdLongNames: Bool = false) -> Data {
        var out = Data("!<arch>\n".utf8)
        for member in members {
            var name = member.name
            var body = member.data
            if bsdLongNames {
                body = Data(member.name.utf8) + member.data
                name = "#1/\(member.name.utf8.count)"
            }
            precondition(name.utf8.count <= 16)
            out.append(field(name, 16)); out.append(field("0", 12)); out.append(field("0", 6))
            out.append(field("0", 6)); out.append(field("100644", 8)); out.append(field("\(body.count)", 10))
            out.append(contentsOf: [0x60, 0x0A])
            out.append(body)
            if body.count % 2 == 1 { out.append(0x0A) }
        }
        return out
    }

    private static func field(_ s: String, _ width: Int) -> Data {
        var d = Data(s.utf8)
        d.append(Data(repeating: 0x20, count: width - d.count))
        return d
    }

    // MARK: tar

    static func tar(_ entries: [Entry]) -> Data {
        var out = Data()
        for entry in entries {
            let size = entry.kind == .file ? entry.data.count : 0
            var records = ""
            if entry.paxPath { records += pax("path", entry.path) }
            if entry.paxSize { records += pax("size", "\(size)") }
            if !records.isEmpty {
                let payload = Data(records.utf8)
                out.append(header(name: "PaxHeader", type: "x", size: payload.count, link: ""))
                out.append(payload); out.append(Data(count: (512 - payload.count % 512) % 512))
            }
            let type: Character
            switch entry.kind {
            case .file: type = "0"
            case .directory: type = "5"
            case .symlink: type = "2"
            case .hardlink: type = "1"
            case .charDevice: type = "3"
            }
            let name = entry.paxPath ? String(entry.path.prefix(20)) : entry.path
            let headerSize = entry.paxSize ? 0 : (entry.declaredSize ?? size)
            out.append(header(name: name, type: type, size: headerSize, link: entry.linkTarget))
            if entry.kind == .file {
                out.append(entry.data); out.append(Data(count: (512 - entry.data.count % 512) % 512))
            }
        }
        out.append(Data(count: 1024))
        return out
    }

    private static func pax(_ key: String, _ value: String) -> String {
        let body = " \(key)=\(value)\n"
        var len = body.utf8.count + 1
        while "\(len)".utf8.count + body.utf8.count != len { len = "\(len)".utf8.count + body.utf8.count }
        return "\(len)\(body)"
    }

    private static func header(name: String, type: Character, size: Int, link: String) -> Data {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, at offset: Int, max: Int) {
            for (i, b) in s.utf8.prefix(max).enumerated() { h[offset + i] = b }
        }
        func octal(_ v: Int, at offset: Int, width: Int) {
            let s = String(v, radix: 8)
            put(String(repeating: "0", count: width - 1 - s.count) + s, at: offset, max: width - 1)
        }
        put(name, at: 0, max: 100)
        octal(0o644, at: 100, width: 8); octal(0, at: 108, width: 8); octal(0, at: 116, width: 8)
        octal(size, at: 124, width: 12); octal(0, at: 136, width: 12)
        for i in 148..<156 { h[i] = 0x20 }
        h[156] = type.asciiValue!
        put(link, at: 157, max: 100)
        put("ustar", at: 257, max: 5); put("00", at: 263, max: 2)
        let sum = h.reduce(0) { $0 + Int($1) }
        put(String(repeating: "0", count: 6 - String(sum, radix: 8).count) + String(sum, radix: 8), at: 148, max: 6)
        h[154] = 0; h[155] = 0x20
        return Data(h)
    }

    // MARK: deb

    /// A `.deb` whose members are compressed with the system tools. `compression`: `gz`, `xz`, `bz2`,
    /// `lzma` or `none`. `zst` needs the helper of Task 3 and is unsupported until then.
    static func deb(control: String, files: [Entry], compression: String) async throws -> Data {
        let flag: String?
        switch compression {
        case "gz": flag = "--gzip"
        case "xz": flag = "--xz"
        case "bz2": flag = "--bzip2"
        case "lzma": flag = "--lzma"
        case "none": flag = nil
        default: throw DebError.unsupportedCompression(compression)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fakedeb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func compressed(_ tar: Data, _ name: String) throws -> Data {
            guard let flag else { return tar }
            let input = dir.appendingPathComponent("\(name).in"), output = dir.appendingPathComponent(name)
            try tar.write(to: input)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = [flag, "-cf", output.path, "@" + input.path]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw DebError.malformed("tar failed") }
            return try Data(contentsOf: output)
        }
        let ext = compression == "none" ? "" : "." + compression
        let controlTar = tar([.file("./control", Data(control.utf8))])
        return ar([("debian-binary", Data("2.0\n".utf8)),
                   ("control.tar" + ext, try compressed(controlTar, "control.tar" + ext)),
                   ("data.tar" + ext, try compressed(tar(files), "data.tar" + ext))])
    }
}
