import Foundation

/// Debian version ordering (Debian policy 5.6.12): `[epoch:]upstream[-revision]`, digit runs
/// compared numerically, letters before other characters, `~` before everything (even the end).
/// Works on arbitrary untrusted strings in linear time: no integer parsing, so no overflow.
public enum DebVersion {
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = split(a), y = split(b)
        let e = compareDigits(x.epoch, y.epoch)
        if e != .orderedSame { return e }
        let u = compareParts(x.upstream, y.upstream)
        if u != .orderedSame { return u }
        return compareParts(x.revision, y.revision)
    }

    private static func split(_ v: String) -> (epoch: [UInt8], upstream: [UInt8], revision: [UInt8]) {
        var bytes = Array(v.utf8)
        var epoch: [UInt8] = []
        if let colon = bytes.firstIndex(of: UInt8(ascii: ":")), colon > 0,
           bytes[..<colon].allSatisfy({ isDigit($0) }) {
            epoch = Array(bytes[..<colon])
            bytes.removeSubrange(...colon)
        }
        var revision: [UInt8] = []
        if let dash = bytes.lastIndex(of: UInt8(ascii: "-")) {
            revision = Array(bytes[(dash + 1)...])
            bytes.removeSubrange(dash...)
        }
        return (epoch, bytes, revision)
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    private static func isAlpha(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }

    private static func order(_ c: UInt8?) -> Int {
        guard let c else { return 0 }
        if isDigit(c) { return 0 }
        if isAlpha(c) { return Int(c) }
        if c == UInt8(ascii: "~") { return -1 }
        return Int(c) + 256
    }

    /// Numeric comparison of two digit strings of any length (leading zeros ignored).
    private static func compareDigits(_ a: [UInt8], _ b: [UInt8]) -> ComparisonResult {
        let x = a.drop { $0 == 48 }, y = b.drop { $0 == 48 }
        if x.count != y.count { return x.count < y.count ? .orderedAscending : .orderedDescending }
        for (p, q) in zip(x, y) where p != q { return p < q ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    private static func compareParts(_ a: [UInt8], _ b: [UInt8]) -> ComparisonResult {
        var i = 0, j = 0
        while i < a.count || j < b.count {
            // non-digit prefix
            while (i < a.count && !isDigit(a[i])) || (j < b.count && !isDigit(b[j])) {
                let oa = order(i < a.count && !isDigit(a[i]) ? a[i] : nil)
                let ob = order(j < b.count && !isDigit(b[j]) ? b[j] : nil)
                if oa != ob { return oa < ob ? .orderedAscending : .orderedDescending }
                if i < a.count && !isDigit(a[i]) { i += 1 }
                if j < b.count && !isDigit(b[j]) { j += 1 }
            }
            let si = i, sj = j
            while i < a.count && isDigit(a[i]) { i += 1 }
            while j < b.count && isDigit(b[j]) { j += 1 }
            let d = compareDigits(Array(a[si..<i]), Array(b[sj..<j]))
            if d != .orderedSame { return d }
        }
        return .orderedSame
    }
}
