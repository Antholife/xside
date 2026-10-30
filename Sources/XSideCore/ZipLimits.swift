import Foundation

/// Refuses an `.ipa` that would expand into something unreasonable (a zip bomb) before it is
/// unpacked: reads the zip's central directory (end record, ZIP64 included) and sums what each
/// entry declares. `ditto` is trusted to honor the declared sizes; this only bounds what an
/// archive announces.
public enum ZipLimits {
    public static let maxUncompressedBytes: UInt64 = 4 * 1024 * 1024 * 1024
    public static let maxEntries = 100_000
    /// Above `ratioFloor` uncompressed, total uncompressed / total compressed may not exceed this.
    /// Small archives are exempt: a few highly compressible files are normal.
    public static let maxRatio: UInt64 = 100
    public static let ratioFloor: UInt64 = 64 * 1024 * 1024
    /// Largest central directory read (100 000 entries with long names fit easily).
    static let maxDirectoryBytes = 64 * 1024 * 1024

    public struct Totals: Equatable, Sendable {
        public let entries: Int
        public let compressed: UInt64
        public let uncompressed: UInt64
    }

    /// Throws `invalidIPA` when the archive is unreadable as a zip or past a limit.
    public static func check(_ url: URL) throws {
        let totals = try scan(url)
        if totals.entries > maxEntries {
            throw XSideError.invalidIPA("IPA refusé : trop de fichiers (\(totals.entries))")
        }
        if totals.uncompressed > maxUncompressedBytes {
            throw XSideError.invalidIPA("IPA refusé : plus de 4 Go une fois décompressé")
        }
        if totals.uncompressed > ratioFloor,
           totals.uncompressed / max(totals.compressed, 1) > maxRatio {
            throw XSideError.invalidIPA("IPA refusé : taux de compression suspect")
        }
    }

    /// Entry count and declared sizes from the central directory. Stops counting past
    /// `maxEntries` (the archive is refused anyway).
    /// Any failure (not a zip, unreadable, a directory) is an `invalidIPA`.
    public static func scan(_ url: URL) throws -> Totals {
        do {
            return try scanDirectory(url)
        } catch let error as XSideError {
            throw error
        } catch {
            throw XSideError.invalidIPA("Archive zip illisible")
        }
    }

    private static func scanDirectory(_ url: URL) throws -> Totals {
        func bad(_ why: String) -> XSideError { .invalidIPA("Archive zip invalide : \(why)") }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw bad("illisible") }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard offset <= size, UInt64(count) <= size - offset else { throw bad("tronquée") }
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else { throw bad("tronquée") }
            return data
        }

        // End of central directory: 22 bytes + a comment of up to 65 535 bytes, at the very end.
        let tailLength = Int(min(size, 22 + 65_535))
        let tail = try read(size - UInt64(tailLength), tailLength)
        guard tailLength >= 22,
              let eocd = stride(from: tailLength - 22, through: 0, by: -1).first(where: { tail.u32($0) == 0x0605_4B50 })
        else { throw bad("fin de répertoire introuvable") }
        var entries = UInt64(tail.u16(eocd + 10))
        var directorySize = UInt64(tail.u32(eocd + 12))
        var directoryOffset = UInt64(tail.u32(eocd + 16))

        // ZIP64: a locator just before the end record points at the ZIP64 end record. Without
        // one, 0xFFFF is a real count (exactly 65 535 entries); a 0xFFFFFFFF size or offset isn't.
        let eocdOffset = size - UInt64(tailLength) + UInt64(eocd)
        let locator = eocdOffset >= 20 ? try read(eocdOffset - 20, 20) : Data()
        let hasZIP64 = locator.count == 20 && locator.u32(0) == 0x0706_4B50
        if directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF, !hasZIP64 { throw bad("ZIP64 invalide") }
        if hasZIP64 {
            let record = try read(locator.u64(8), 56)
            guard record.u32(0) == 0x0606_4B50 else { throw bad("ZIP64 invalide") }
            entries = record.u64(32)
            directorySize = record.u64(40)
            directoryOffset = record.u64(48)
        }
        guard directorySize <= UInt64(maxDirectoryBytes) else { throw bad("répertoire trop grand") }
        let directory = try read(directoryOffset, Int(directorySize))

        var pos = 0, count = 0
        var compressed: UInt64 = 0, uncompressed: UInt64 = 0
        while pos + 46 <= directory.count, directory.u32(pos) == 0x0201_4B50 {
            count += 1
            if count > maxEntries { break }
            var entryCompressed = UInt64(directory.u32(pos + 20))
            var entryUncompressed = UInt64(directory.u32(pos + 24))
            let nameLength = Int(directory.u16(pos + 28))
            let extraLength = Int(directory.u16(pos + 30))
            let commentLength = Int(directory.u16(pos + 32))
            let extraStart = pos + 46 + nameLength
            guard extraStart + extraLength + commentLength <= directory.count else { throw bad("entrée tronquée") }
            if entryUncompressed == 0xFFFF_FFFF || entryCompressed == 0xFFFF_FFFF {
                // ZIP64 extra field (0x0001): the 64-bit values, only for the fields set to 0xFFFFFFFF.
                var e = extraStart
                while e + 4 <= extraStart + extraLength {
                    let id = directory.u16(e), length = Int(directory.u16(e + 2))
                    guard e + 4 + length <= extraStart + extraLength else { break }
                    if id == 0x0001 {
                        var v = e + 4
                        if entryUncompressed == 0xFFFF_FFFF, v + 8 <= e + 4 + length {
                            entryUncompressed = directory.u64(v); v += 8
                        }
                        if entryCompressed == 0xFFFF_FFFF, v + 8 <= e + 4 + length {
                            entryCompressed = directory.u64(v)
                        }
                        break
                    }
                    e += 4 + length
                }
            }
            let (c, o1) = compressed.addingReportingOverflow(entryCompressed)
            let (u, o2) = uncompressed.addingReportingOverflow(entryUncompressed)
            guard !o1, !o2 else { throw bad("tailles invalides") }
            compressed = c
            uncompressed = u
            pos = extraStart + extraLength + commentLength
        }
        // The end record's count must match what the directory holds (unless already too many).
        if count <= maxEntries, UInt64(count) != entries { throw bad("répertoire incohérent") }
        return Totals(entries: count, compressed: compressed, uncompressed: uncompressed)
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        let s = startIndex + offset
        return UInt16(self[s]) | UInt16(self[s + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }

    func u64(_ offset: Int) -> UInt64 {
        UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32
    }
}
