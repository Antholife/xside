import Foundation
import Darwin

public struct TarEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case file, directory, symlink, hardlink, other }
    /// As written in the archive (not normalised; see `TarPath`).
    public let path: String
    public let kind: Kind
    public let size: Int
    /// Where the body sits in the data the entries were read from.
    public let dataRange: Range<Int>
}

/// Turns an archive path into a relative path that is safe to join to a root, or nil.
public enum TarPath {
    public static func normalize(_ raw: String) -> String? {
        guard raw.utf8.count <= DebLimits.maxPathBytes else { return nil }
        guard !raw.utf8.contains(0), !raw.utf8.contains(UInt8(ascii: "\\")) else { return nil }
        var parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains("..") { return nil }
        parts.removeAll { $0 == "." }
        if parts.count >= 2, parts[0] == "var", parts[1] == "jb" { parts.removeFirst(2) }   // rootless layout
        guard !parts.isEmpty, parts.count <= DebLimits.maxPathDepth else { return nil }
        guard parts.allSatisfy({ $0.utf8.count <= 255 }) else { return nil }
        let path = parts.joined(separator: "/")
        return path.utf8.count <= DebLimits.maxPathBytes ? path : nil
    }

    /// `./`, `/`, `.`, `./var/jb/`: the directory that holds everything, not an item to create.
    static func isRoot(_ raw: String) -> Bool {
        guard !raw.utf8.contains(0), !raw.utf8.contains(UInt8(ascii: "\\")) else { return false }
        var parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains("..") else { return false }
        parts.removeAll { $0 == "." }
        if parts.count == 2, parts[0] == "var", parts[1] == "jb" { return true }
        return parts.isEmpty
    }
}

public struct TarExtraction: Equatable, Sendable {
    public var files: [String]
    public var directories: [String]
    public var skippedLinks: Int
    public var skippedOther: Int
}

/// Reads ustar (plus pax `x` and GNU long-name headers) from untrusted data and writes only
/// regular files and directories out of it. Never creates a link, never leaves its root.
public enum TarReader {
    private static let block = 512
    private static let maxHeaderPayload = 64 * 1024     // pax / long-name records

    public static func entries(_ data: Data, maxEntries: Int = DebLimits.maxEntries) throws -> [TarEntry] {
        guard data.count <= DebLimits.maxDataTarBytes else { throw DebError.tooLarge }
        return try data.withUnsafeBytes { try parse($0, maxEntries: maxEntries) }
    }

    private static func parse(_ b: UnsafeRawBufferPointer, maxEntries: Int) throws -> [TarEntry] {
        var result: [TarEntry] = []
        var pos = 0
        var paxPath: String?, paxSize: Int?, longName: String?
        while b.count - pos >= block {
            let h = UnsafeRawBufferPointer(rebasing: b[pos..<(pos + block)])
            if h.allSatisfy({ $0 == 0 }) { return result }               // end-of-archive marker
            try verifyChecksum(h)
            let type = h[156]
            var size = try octal(h, 124, 12)
            if let paxSize, type != UInt8(ascii: "x"), type != UInt8(ascii: "g") { size = paxSize }
            let bodyStart = pos + block
            let kind: TarEntry.Kind
            switch type {
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"): kind = .file
            case UInt8(ascii: "5"): kind = .directory
            case UInt8(ascii: "2"): kind = .symlink
            case UInt8(ascii: "1"): kind = .hardlink
            default: kind = .other
            }
            // Directories and links carry no body here; everything else is skipped by its size.
            let bodySize = (kind == .directory || kind == .symlink || kind == .hardlink) ? 0 : size
            if bodySize > DebLimits.maxFileBytes { throw DebError.tooLarge }
            guard bodySize <= b.count - bodyStart else { throw DebError.malformed("tar entry runs past the end") }
            let bodyEnd = bodyStart + bodySize
            let padded = (bodySize + block - 1) / block * block        // bodySize <= 256 MiB: no overflow
            let next = padded <= b.count - bodyStart ? bodyStart + padded : b.count

            switch type {
            case UInt8(ascii: "x"):
                guard bodySize <= maxHeaderPayload else { throw DebError.malformed("pax header too large") }
                let records = try paxRecords(UnsafeRawBufferPointer(rebasing: b[bodyStart..<bodyEnd]))
                if let p = records["path"] { paxPath = p }
                if let s = records["size"] {
                    guard let n = Int(s), n >= 0 else { throw DebError.malformed("bad pax size") }
                    paxSize = n
                }
            case UInt8(ascii: "g"):
                break                                                   // global headers are ignored
            case UInt8(ascii: "L"):
                guard bodySize <= maxHeaderPayload else { throw DebError.malformed("long name too large") }
                let raw = UnsafeRawBufferPointer(rebasing: b[bodyStart..<bodyEnd])
                longName = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            case UInt8(ascii: "K"):
                break                                                   // long link target: unused
            default:
                guard result.count < maxEntries else { throw DebError.tooLarge }
                let path = paxPath ?? longName ?? ustarName(h)
                result.append(TarEntry(path: path, kind: kind, size: bodySize, dataRange: bodyStart..<bodyEnd))
                paxPath = nil; paxSize = nil; longName = nil
            }
            pos = next
        }
        // Leftover bytes shorter than a block must be zero padding.
        if pos < b.count, UnsafeRawBufferPointer(rebasing: b[pos...]).contains(where: { $0 != 0 }) {
            throw DebError.malformed("truncated tar header")
        }
        return result
    }

    private static func ustarName(_ h: UnsafeRawBufferPointer) -> String {
        func field(_ at: Int, _ width: Int) -> String {
            String(decoding: UnsafeRawBufferPointer(rebasing: h[at..<(at + width)]).prefix { $0 != 0 }, as: UTF8.self)
        }
        let name = field(0, 100)
        // POSIX ustar only (`ustar\0`): old GNU headers (`ustar  \0`) keep atime/ctime there.
        let isUstar = Array(h[257..<263]) == Array("ustar\0".utf8)
        let prefix = isUstar ? field(345, 155) : ""
        return prefix.isEmpty ? name : prefix + "/" + name
    }

    private static func verifyChecksum(_ h: UnsafeRawBufferPointer) throws {
        let stored = try octal(h, 148, 8)
        var unsigned = 0, signed = 0
        for i in 0..<block {
            let byte = (148..<156).contains(i) ? UInt8(0x20) : h[i]
            unsigned += Int(byte); signed += Int(Int8(bitPattern: byte))
        }
        guard stored == unsigned || stored == signed else { throw DebError.malformed("bad tar checksum") }
    }

    /// An octal number padded with NULs or spaces; no sign, no binary extension, at most 12 bytes.
    private static func octal(_ h: UnsafeRawBufferPointer, _ at: Int, _ width: Int) throws -> Int {
        var value = 0, digits = 0
        var started = false, ended = false
        for i in at..<(at + width) {
            let c = h[i]
            if c == 0 || c == 0x20 { if started { ended = true }; continue }
            guard !ended, c >= 0x30, c <= 0x37 else { throw DebError.malformed("bad tar number") }
            started = true
            value = value * 8 + Int(c - 0x30)                           // 12 digits * 3 bits: no overflow
            digits += 1
        }
        return digits > 0 ? value : 0
    }

    private static func paxRecords(_ p: UnsafeRawBufferPointer) throws -> [String: String] {
        var out: [String: String] = [:]
        var pos = 0
        while pos < p.count {
            var len = 0, i = pos
            while i < p.count, p[i] >= 0x30, p[i] <= 0x39, i - pos < 8 { len = len * 10 + Int(p[i] - 0x30); i += 1 }
            guard i < p.count, p[i] == 0x20, len > i - pos + 1, len <= p.count - pos, p[pos + len - 1] == 0x0A else {
                throw DebError.malformed("bad pax record")
            }
            let body = String(decoding: UnsafeRawBufferPointer(rebasing: p[(i + 1)..<(pos + len - 1)]), as: UTF8.self)
            if let eq = body.firstIndex(of: "=") {
                out[String(body[..<eq])] = String(body[body.index(after: eq)...])
            }
            pos += len
        }
        return out
    }

    // MARK: extraction

    /// Validates the whole archive first (a single unsafe path rejects all of it, nothing is
    /// written), then writes regular files (0644, or 0755 for Mach-O) and directories under
    /// `root`, creating every component itself without following links. `keep` sees the normalised
    /// path of each file and directory; the rest is left unwritten.
    public static func extract(_ data: Data, to root: URL, keep: (String) -> Bool = { _ in true }) throws -> TarExtraction {
        let all = try entries(data)
        struct Item { let path: String; let entry: TarEntry }
        var items: [Item] = []
        var result = TarExtraction(files: [], directories: [], skippedLinks: 0, skippedOther: 0)
        var seen: [String: (exact: String, isDir: Bool)] = [:]       // lowercased path -> what claimed it
        var total = 0

        func claim(_ path: String, isDir: Bool) throws {
            let key = path.lowercased()
            if let existing = seen[key] {
                guard existing.exact == path, existing.isDir, isDir else {
                    throw DebError.malformed("duplicate or conflicting path: \(path)")
                }
                return
            }
            seen[key] = (path, isDir)
        }

        for entry in all {
            switch entry.kind {
            case .symlink, .hardlink, .other:
                if !TarPath.isRoot(entry.path), TarPath.normalize(entry.path) == nil {
                    throw DebError.malformed("unsafe path in archive")
                }
                if entry.kind == .other { result.skippedOther += 1 } else { result.skippedLinks += 1 }
                continue
            case .directory where TarPath.isRoot(entry.path):
                continue
            default: break
            }
            guard let path = TarPath.normalize(entry.path) else { throw DebError.malformed("unsafe path in archive") }
            let parts = path.split(separator: "/").map(String.init)
            for n in 1..<max(parts.count, 1) { try claim(parts[..<n].joined(separator: "/"), isDir: true) }
            try claim(path, isDir: entry.kind == .directory)
            if entry.kind == .file {
                let (sum, overflow) = total.addingReportingOverflow(entry.size)
                guard !overflow, sum <= DebLimits.maxDataTarBytes else { throw DebError.tooLarge }
                total = sum
            }
            items.append(Item(path: path, entry: entry))
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY)
        guard rootFD >= 0 else { throw DebError.malformed("cannot open the destination") }
        defer { close(rootFD) }
        var made = Set<String>()

        /// Opens (creating) the directory at `parts`, one component at a time. Caller closes.
        func directory(_ parts: [String]) throws -> Int32 {
            var fd = dup(rootFD)
            var so = ""
            for part in parts {
                so += (so.isEmpty ? "" : "/") + part
                if mkdirat(fd, part, 0o755) == 0 { if made.insert(so).inserted { result.directories.append(so) } }
                else if errno != EEXIST { close(fd); throw DebError.malformed("cannot create \(so)") }
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                close(fd)
                guard next >= 0 else { throw DebError.malformed("\(so) is not a plain directory") }
                fd = next
            }
            return fd
        }

        for item in items where keep(item.path) {
            let parts = item.path.split(separator: "/").map(String.init)
            if item.entry.kind == .directory {
                close(try directory(parts))
                continue
            }
            let dir = try directory(Array(parts.dropLast()))
            defer { close(dir) }
            let body = item.entry.dataRange
            let first = data.withUnsafeBytes { raw -> [UInt8] in
                Array(UnsafeRawBufferPointer(rebasing: raw[body]).prefix(4))
            }
            let fd = openat(dir, parts[parts.count - 1], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            guard fd >= 0 else { throw DebError.malformed("cannot create \(item.path)") }
            defer { close(fd) }
            try data.withUnsafeBytes { raw in
                var done = 0
                let slice = UnsafeRawBufferPointer(rebasing: raw[body])
                while done < slice.count {
                    let n = write(fd, slice.baseAddress! + done, slice.count - done)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw DebError.malformed("cannot write \(item.path)") }
                    done += n
                }
            }
            if isMachO(first) { fchmod(fd, 0o755) }
            result.files.append(item.path)
        }
        return result
    }

    private static func isMachO(_ m: [UInt8]) -> Bool {
        guard m.count == 4 else { return false }
        let v = UInt32(m[0]) << 24 | UInt32(m[1]) << 16 | UInt32(m[2]) << 8 | UInt32(m[3])
        return [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA].contains(v)
    }
}
