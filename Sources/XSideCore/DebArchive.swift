import Foundation

/// Caps on everything read out of a `.deb` (untrusted input: a tweak downloaded from a repo or
/// dropped by the user). Every reader of Debian archives checks against these.
public enum DebLimits {
    public static let maxDebBytes = 256 * 1024 * 1024
    public static let maxMembers = 16
    /// Decompressed size of `control.tar`.
    public static let maxControlTarBytes = 1024 * 1024
    public static let maxControlFileBytes = 64 * 1024
    /// Decompressed size of `data.tar`.
    public static let maxDataTarBytes = 512 * 1024 * 1024
    public static let maxEntries = 10_000
    public static let maxFileBytes = 256 * 1024 * 1024
    public static let maxPathBytes = 1024
    public static let maxPathDepth = 32
    public static let maxPlistBytes = 64 * 1024
}

public enum DebError: Error, Equatable {
    case notADeb
    case tooLarge
    case malformed(String)
    case unsupportedCompression(String)
}

/// One member of the `ar` container: its name and where its body sits in the data it came from
/// (offsets from the start of that `Data`, long-name prefix excluded).
public struct DebMember: Equatable, Sendable {
    public let name: String
    public let range: Range<Int>
}

/// Reader for the `ar` container of a `.deb`. Bounded and strict: sizes are plain ASCII decimal,
/// every offset is checked against the data, a hostile file throws and never traps.
public enum DebArchive {
    private static let magic = Array("!<arch>\n".utf8)
    private static let headerSize = 60

    public static func members(_ data: Data) throws -> [DebMember] {
        guard data.count <= DebLimits.maxDebBytes else { throw DebError.tooLarge }
        return try data.withUnsafeBytes { try parse($0) }
    }

    /// Member 0 must be `debian-binary` starting with `2.`; then the first `control.tar[.ext]` and
    /// the first `data.tar[.ext]` (anything after them, such as `_gpgorigin`, is ignored).
    public static func controlAndData(_ data: Data) throws -> (debianBinary: String, control: DebMember, data: DebMember) {
        let all = try members(data)
        guard let first = all.first, first.name == "debian-binary", first.range.count <= 64 else { throw DebError.notADeb }
        let start = data.startIndex
        let version = String(decoding: data[(start + first.range.lowerBound)..<(start + first.range.upperBound)], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.hasPrefix("2.") else { throw DebError.notADeb }
        func find(_ base: String) -> DebMember? {
            all.dropFirst().first { $0.name == base || $0.name.hasPrefix(base + ".") }
        }
        guard let control = find("control.tar") else { throw DebError.malformed("no control.tar member") }
        guard let payload = find("data.tar") else { throw DebError.malformed("no data.tar member") }
        return (version, control, payload)
    }

    private static func parse(_ b: UnsafeRawBufferPointer) throws -> [DebMember] {
        guard b.count >= magic.count, magic.indices.allSatisfy({ b[$0] == magic[$0] }) else {
            throw DebError.malformed("not an ar archive")
        }
        var members: [DebMember] = []
        var pos = magic.count
        while pos < b.count {
            guard members.count < DebLimits.maxMembers else { throw DebError.malformed("too many members") }
            guard b.count - pos >= headerSize else { throw DebError.malformed("truncated member header") }
            guard b[pos + 58] == 0x60, b[pos + 59] == 0x0A else { throw DebError.malformed("bad member header") }
            guard let size = decimal(b, pos + 48, 10) else { throw DebError.malformed("bad member size") }
            let bodyStart = pos + headerSize                   // pos + 60 cannot overflow: pos < count
            guard size <= b.count - bodyStart else { throw DebError.malformed("member runs past the end") }
            var name = trimmed(b, pos, 16)
            var contentStart = bodyStart
            if name.hasPrefix("#1/") {
                guard let n = Int(name.dropFirst(3)), n >= 0, n <= 256, n <= size else {
                    throw DebError.malformed("bad long name")
                }
                name = String(decoding: UnsafeRawBufferPointer(rebasing: b[bodyStart..<(bodyStart + n)]), as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                contentStart = bodyStart + n
            }
            if name.hasSuffix("/") { name.removeLast() }
            let end = bodyStart + size
            members.append(DebMember(name: name, range: contentStart..<end))
            pos = end + (size % 2)                            // members start on even offsets
        }
        return members
    }

    private static func trimmed(_ b: UnsafeRawBufferPointer, _ at: Int, _ width: Int) -> String {
        var s = String(decoding: UnsafeRawBufferPointer(rebasing: b[at..<(at + width)]), as: UTF8.self)
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    /// Digits only (right-padded with spaces), at most 10: no sign, no hex, no overflow.
    private static func decimal(_ b: UnsafeRawBufferPointer, _ at: Int, _ width: Int) -> Int? {
        var value = 0, digits = 0, ended = false
        for i in at..<(at + width) {
            let c = b[i]
            if c == 0x20 { ended = true; continue }
            guard !ended, c >= 0x30, c <= 0x39 else { return nil }
            value = value * 10 + Int(c - 0x30)
            digits += 1
        }
        return digits > 0 ? value : nil
    }
}
