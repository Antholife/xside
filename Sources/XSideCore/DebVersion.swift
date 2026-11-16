import Foundation

/// Debian version comparison (`[epoch:]upstream[-revision]`), a port of dpkg's `verrevcmp`.
/// Used for `.deb` tweak updates, whose versions (`1.1.8-1`, `2:1.0`, `1.0~beta`) the dotted-integer
/// `UpdateChecker.isNewer(_:than:)` cannot compare.
public enum DebVersion {
    /// nil only when either string cannot be parsed (empty, non-numeric epoch, empty upstream or revision).
    public static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        guard let x = parse(a), let y = parse(b) else { return nil }
        if x.epoch != y.epoch { return x.epoch < y.epoch ? .orderedAscending : .orderedDescending }
        let up = verrevcmp(x.upstream, y.upstream)
        if up != .orderedSame { return up }
        return verrevcmp(x.revision, y.revision)
    }

    private struct Parts { let epoch: Int; let upstream: [UInt8]; let revision: [UInt8] }

    private static func parse(_ s: String) -> Parts? {
        var rest = Substring(s.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !rest.isEmpty else { return nil }
        var epoch = 0
        if let colon = rest.firstIndex(of: ":") {
            let e = rest[..<colon]
            guard !e.isEmpty, e.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(e) else { return nil }
            epoch = n
            rest = rest[rest.index(after: colon)...]
        }
        var upstream = rest, revision = Substring("")
        if let dash = rest.lastIndex(of: "-") {
            upstream = rest[..<dash]
            revision = rest[rest.index(after: dash)...]
            guard !revision.isEmpty else { return nil }
        }
        guard !upstream.isEmpty else { return nil }
        let allowed = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber || ".+-~:".contains(c)) }
        guard upstream.allSatisfy(allowed), revision.allSatisfy(allowed) else { return nil }
        return Parts(epoch: epoch, upstream: Array(upstream.utf8), revision: Array(revision.utf8))
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    private static func isAlpha(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }

    /// `~` -1, end/digit 0, letter ASCII, other ASCII + 256.
    private static func order(_ s: [UInt8], _ i: Int) -> Int {
        guard i < s.count else { return 0 }
        let c = s[i]
        if isDigit(c) { return 0 }
        if isAlpha(c) { return Int(c) }
        if c == 126 { return -1 }
        return Int(c) + 256
    }

    private static func verrevcmp(_ a: [UInt8], _ b: [UInt8]) -> ComparisonResult {
        var i = 0, j = 0
        while i < a.count || j < b.count {
            while (i < a.count && !isDigit(a[i])) || (j < b.count && !isDigit(b[j])) {
                let ac = order(a, i), bc = order(b, j)
                if ac != bc { return ac < bc ? .orderedAscending : .orderedDescending }
                i += 1; j += 1
            }
            while i < a.count && a[i] == 48 { i += 1 }
            while j < b.count && b[j] == 48 { j += 1 }
            var firstDiff = 0
            while i < a.count && isDigit(a[i]) && j < b.count && isDigit(b[j]) {
                if firstDiff == 0 { firstDiff = Int(a[i]) - Int(b[j]) }
                i += 1; j += 1
            }
            if i < a.count && isDigit(a[i]) { return .orderedDescending }
            if j < b.count && isDigit(b[j]) { return .orderedAscending }
            if firstDiff != 0 { return firstDiff < 0 ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
