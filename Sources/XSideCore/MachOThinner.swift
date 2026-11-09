import Foundation
import os

/// Removes the legacy 32-bit ARM slices (armv7, armv7s) from fat Mach-O files. No device XSide
/// supports runs them, and they may still be encrypted, which `codesign` would otherwise carry.
/// Done in Swift by rewriting the fat header, so it needs no tool.
public enum MachOThinner {
    private static let logger = Logger(subsystem: "io.github.xside", category: "thinner")

    private struct Arch { var cpu: UInt32; var sub: UInt32; var offset: UInt64; var size: UInt64; var align: UInt32 }

    /// The fat file's content without its 32-bit ARM slices: nil when there is nothing to remove,
    /// or when the file isn't a well-formed fat binary. One remaining slice gives the thin file.
    /// Never returns a file without any slice.
    public static func removingARM32(from data: Data) -> Data? {
        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o <= data.count - 4 else { return nil }
            let s = data.startIndex + o
            return (UInt32(data[s]) << 24) | (UInt32(data[s + 1]) << 16) | (UInt32(data[s + 2]) << 8) | UInt32(data[s + 3])
        }
        func u64(_ o: Int) -> UInt64? {
            guard let hi = u32(o), let lo = u32(o + 4) else { return nil }
            return UInt64(hi) << 32 | UInt64(lo)
        }
        guard let magic = u32(0), magic == 0xCAFEBABE || magic == 0xCAFEBABF,
              let n = u32(4), n >= 1, n <= 64 else { return nil }
        let is64 = magic == 0xCAFEBABF
        let entry = is64 ? 32 : 20
        var archs: [Arch] = []
        for i in 0..<Int(n) {
            let b = 8 + i * entry
            guard let cpu = u32(b), let sub = u32(b + 4) else { return nil }
            let off: UInt64, size: UInt64, align: UInt32
            if is64 {
                guard let o = u64(b + 8), let s = u64(b + 16), let a = u32(b + 24) else { return nil }
                off = o; size = s; align = a
            } else {
                guard let o = u32(b + 8), let s = u32(b + 12), let a = u32(b + 16) else { return nil }
                off = UInt64(o); size = UInt64(s); align = a
            }
            guard align <= 14, off <= UInt64(data.count), size <= UInt64(data.count) - off else { return nil }
            archs.append(Arch(cpu: cpu, sub: sub, offset: off, size: size, align: align))
        }
        let kept = archs.filter { $0.cpu != IPAInspector.cpuTypeARM32 }
        guard !kept.isEmpty, kept.count < archs.count else { return nil }

        // Hostile or corrupt headers: two slices of one architecture, or slices that overlap each
        // other or the header, are never rewritten.
        var seen = Set<UInt64>()
        for a in kept where !seen.insert(UInt64(a.cpu) << 32 | UInt64(a.sub)).inserted { return nil }
        var previousEnd = UInt64(8 + archs.count * entry)
        for a in kept.sorted(by: { $0.offset < $1.offset }) {
            guard a.offset >= previousEnd else { return nil }
            previousEnd = a.offset + a.size // in bounds: checked against data.count above
        }

        func slice(_ a: Arch) -> Data {
            let from = data.startIndex + Int(a.offset)
            return data.subdata(in: from..<(from + Int(a.size)))
        }
        if kept.count == 1 { return slice(kept[0]) }

        // The final layout first: nothing is built unless the output stays near the input's size.
        let limit = min(UInt64(data.count) + 65_536, is64 ? UInt64(Int.max) : UInt64(UInt32.max))
        var cursor = UInt64(8 + kept.count * entry)
        var placed: [UInt64] = []
        for a in kept {
            let alignment = UInt64(1) << UInt64(a.align)
            let (padded, o1) = cursor.addingReportingOverflow(alignment - 1)
            guard !o1 else { return nil }
            let start = padded / alignment * alignment
            let (end, o2) = start.addingReportingOverflow(a.size)
            guard !o2, end <= limit else { return nil }
            placed.append(start)
            cursor = end
        }

        var out = Data()
        out.reserveCapacity(Int(cursor))
        func be32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { out.append(contentsOf: $0) } }
        func be64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { out.append(contentsOf: $0) } }
        be32(magic); be32(UInt32(kept.count))
        for (a, off) in zip(kept, placed) {
            be32(a.cpu); be32(a.sub)
            if is64 { be64(off); be64(a.size); be32(a.align); be32(0) }
            else {
                guard let o = UInt32(exactly: off), let s = UInt32(exactly: a.size) else { return nil }
                be32(o); be32(s); be32(a.align)
            }
        }
        for (a, off) in zip(kept, placed) {
            guard off >= UInt64(out.count) else { return nil }
            out.append(Data(count: Int(off) - out.count))
            out.append(slice(a))
        }
        return out
    }

    /// Whether some fat Mach-O under `app` has a 32-bit ARM slice next to another one (what
    /// `removeARM32Slices` would change). Reads the headers only.
    public static func hasARM32Slices(under app: URL) -> Bool {
        guard let en = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  v.isRegularFile == true, v.isSymbolicLink != true,
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let head = (try? handle.read(upToCount: 8 + 64 * 32)) ?? Data()
            try? handle.close()
            if headerHasARM32(head) { return true }
        }
        return false
    }

    static func headerHasARM32(_ head: Data) -> Bool {
        guard head.count >= 8, head.prefix(3) == Data([0xCA, 0xFE, 0xBA]),
              head[head.startIndex + 3] == 0xBE || head[head.startIndex + 3] == 0xBF else { return false }
        let entry = head[head.startIndex + 3] == 0xBF ? 32 : 20
        let n = Int(head[head.startIndex + 7])
        guard head[head.startIndex + 4] == 0, head[head.startIndex + 5] == 0, head[head.startIndex + 6] == 0,
              n >= 1, n <= 64, head.count >= 8 + n * entry else { return false }
        let cpus: [UInt32] = (0..<n).map { i in
            let s = head.startIndex + 8 + i * entry
            return (UInt32(head[s]) << 24) | (UInt32(head[s + 1]) << 16) | (UInt32(head[s + 2]) << 8) | UInt32(head[s + 3])
        }
        return cpus.contains(IPAInspector.cpuTypeARM32) && cpus.contains { $0 != IPAInspector.cpuTypeARM32 }
    }

    /// Rewrites every fat Mach-O under `app` (executable, frameworks, dylibs, extensions) without
    /// its 32-bit ARM slices. A file that can't be rewritten is left as it was. Returns the
    /// files changed, for the log.
    @discardableResult
    public static func removeARM32Slices(under app: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        var changed: [URL] = []
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let head = (try? handle.read(upToCount: 4)) ?? Data()
            try? handle.close()
            guard head == Data([0xCA, 0xFE, 0xBA, 0xBE]) || head == Data([0xCA, 0xFE, 0xBA, 0xBF]) else { continue }
            do {
                let data = try Data(contentsOf: url)
                guard let thinned = removingARM32(from: data) else { continue }
                let mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions]
                try thinned.write(to: url, options: .atomic)
                if let mode { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
                changed.append(url)
                logger.info("removed 32-bit ARM slices from \(url.lastPathComponent) (\(data.count) -> \(thinned.count) bytes)")
            } catch {
                logger.notice("kept \(url.lastPathComponent) as is: \(String(describing: error))")
            }
        }
        return changed
    }
}
