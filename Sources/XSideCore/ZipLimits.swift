import Foundation

/// Refuses an `.ipa` that would expand into something unreasonable (a zip bomb) before it is
/// unpacked: reads the zip's central directory (end record, ZIP64 included) and sums what each
/// entry declares. A crafted archive can announce small sizes and expand far more (`ditto` reads
/// local headers), so `extract` also watches what is really written and stops `ditto` past the
/// same limits.
public enum ZipLimits {
    private static let log = Log("import")
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

    /// How often `extract` measures the destination while the archive is unpacked.
    static let watchInterval: Duration = .milliseconds(500)

    /// Checks the declared sizes, then unpacks `ipa` into `destination` while measuring it: past
    /// `maxUncompressedBytes` or `maxEntries` really written, the tool is stopped (its process
    /// group is killed through cancellation) and `invalidIPA` thrown.
    ///
    /// `ditto -x -k` first. It reads the archive from start to end, and gives up ("Couldn't read
    /// pkzip signature") on archives with bytes left between entries, as written by tools that
    /// patch an app in place (issue #1). `unzip` follows the central directory instead: it gets a
    /// second try on a clean destination, under the same watch.
    public static func extract(_ ipa: URL, to destination: URL, runner: CommandRunning,
                               maxBytes: UInt64 = maxUncompressedBytes,
                               maxFiles: Int = maxEntries) async throws -> CommandResult {
        try check(ipa)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
        let ditto = try await watched(destination, maxBytes: maxBytes, maxFiles: maxFiles) {
            try await runner.run("/usr/bin/ditto", ["-x", "-k", ipa.path, destination.path], cwd: nil)
        }
        guard ditto.status != 0 else { return ditto }

        log.notice("ditto couldn't unpack \(ipa.lastPathComponent): trying unzip")
        _ = repairPermissions(destination)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [] where !before.contains(name) {
            try FileManager.default.removeItem(at: destination.appendingPathComponent(name))
        }
        return try await watched(destination, maxBytes: maxBytes, maxFiles: maxFiles) {
            try await runner.run("/usr/bin/unzip", ["-qq", "-o", ipa.path, "-d", destination.path], cwd: nil)
        }
    }

    /// Runs `unpack` while measuring `destination` every `watchInterval`, then once more at the end
    /// (tools set folder permissions last; this pass also gives the owner access back to them).
    private static func watched(_ destination: URL, maxBytes: UInt64, maxFiles: Int,
                                _ unpack: @escaping @Sendable () async throws -> CommandResult) async throws -> CommandResult {
        try await withThrowingTaskGroup(of: CommandResult?.self) { group in
            group.addTask { try await unpack() }
            group.addTask {
                while true {
                    try await Task.sleep(for: watchInterval)
                    let written = writtenTotals(destination)
                    if written.entries > maxFiles || written.bytes > maxBytes {
                        throw XSideError.invalidIPA("Rejected: it expands to more than it declares")
                    }
                }
            }
            defer { group.cancelAll() }
            while let finished = try await group.next() {
                guard let result = finished else { continue }
                let written = writtenTotals(destination)
                if result.status == 0, written.entries > maxFiles || written.bytes > maxBytes {
                    throw XSideError.invalidIPA("Rejected: it expands to more than it declares")
                }
                return result
            }
            throw CancellationError()
        }
    }

    /// Files and bytes under `directory`, without following links. Some tools write archives whose
    /// folders lack the search bit (`rw-r--r--`), which `ditto` reproduces: such folders are made
    /// accessible to their owner, then measured. Fails closed: a subtree that still can't be read
    /// counts as over every limit.
    static func writtenTotals(_ directory: URL) -> (entries: Int, bytes: UInt64) {
        if let totals = walk(directory) { return totals }
        log.notice("unreadable folders in the archive: giving their owner access back")
        if repairPermissions(directory), let totals = walk(directory) { return totals }
        log.error("archive still unreadable after repairing permissions")
        return (Int.max, UInt64.max)
    }

    /// Totals under `directory`, or nil when part of it can't be read.
    private static func walk(_ directory: URL) -> (entries: Int, bytes: UInt64)? {
        let unreadable = UnreadableFlag()
        guard let items = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey], options: [],
            errorHandler: { _, _ in unreadable.set(); return true }) else {
            return (0, 0)
        }
        var entries = 0, bytes: UInt64 = 0
        for case let url as URL in items {
            entries += 1
            bytes += UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return unreadable.isSet ? nil : (entries, bytes)
    }

    /// Gives the owner read, write and search on every folder and read and write on every file
    /// under `url` (links are left alone, never followed). False when something can't be fixed;
    /// an entry that vanished meanwhile (ditto still running) is fine.
    static func repairPermissions(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return errno == ENOENT }
        let kind = st.st_mode & S_IFMT
        if kind == S_IFLNK { return true }
        let needed: mode_t = kind == S_IFDIR ? 0o700 : 0o600
        if st.st_mode & needed != needed,
           fchmodat(AT_FDCWD, url.path, (st.st_mode & 0o7777) | needed, AT_SYMLINK_NOFOLLOW) != 0 {
            return false
        }
        guard kind == S_IFDIR else { return true }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return lstat(url.path, &st) != 0 && errno == ENOENT
        }
        return names.allSatisfy { repairPermissions(url.appendingPathComponent($0)) }
    }

    private final class UnreadableFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// Throws `invalidIPA` when the archive is unreadable as a zip or past a limit.
    public static func check(_ url: URL) throws {
        let totals = try scan(url)
        if totals.entries > maxEntries {
            throw XSideError.invalidIPA("Rejected: too many files (\(totals.entries))")
        }
        if totals.uncompressed > maxUncompressedBytes {
            throw XSideError.invalidIPA("Rejected: over 4 GB once unzipped")
        }
        if totals.uncompressed > ratioFloor,
           totals.uncompressed / max(totals.compressed, 1) > maxRatio {
            throw XSideError.invalidIPA("Rejected: suspicious compression ratio")
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
            throw XSideError.invalidIPA("Unreadable zip archive")
        }
    }

    private static func scanDirectory(_ url: URL) throws -> Totals {
        func bad(_ why: String) -> XSideError { .invalidIPA("Invalid zip archive: \(why)") }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw bad("unreadable") }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard offset <= size, UInt64(count) <= size - offset else { throw bad("truncated") }
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else { throw bad("truncated") }
            return data
        }

        // End of central directory: 22 bytes + a comment of up to 65 535 bytes, at the very end.
        let tailLength = Int(min(size, 22 + 65_535))
        let tail = try read(size - UInt64(tailLength), tailLength)
        guard tailLength >= 22,
              let eocd = stride(from: tailLength - 22, through: 0, by: -1).first(where: { tail.u32($0) == 0x0605_4B50 })
        else { throw bad("end of central directory not found") }
        var entries = UInt64(tail.u16(eocd + 10))
        var directorySize = UInt64(tail.u32(eocd + 12))
        var directoryOffset = UInt64(tail.u32(eocd + 16))

        // ZIP64: a locator just before the end record points at the ZIP64 end record. Without
        // one, 0xFFFF is a real count (exactly 65 535 entries); a 0xFFFFFFFF size or offset isn't.
        let eocdOffset = size - UInt64(tailLength) + UInt64(eocd)
        let locator = eocdOffset >= 20 ? try read(eocdOffset - 20, 20) : Data()
        let hasZIP64 = locator.count == 20 && locator.u32(0) == 0x0706_4B50
        if directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF, !hasZIP64 { throw bad("invalid ZIP64") }
        if hasZIP64 {
            let record = try read(locator.u64(8), 56)
            guard record.u32(0) == 0x0606_4B50 else { throw bad("invalid ZIP64") }
            entries = record.u64(32)
            directorySize = record.u64(40)
            directoryOffset = record.u64(48)
        }
        guard directorySize <= UInt64(maxDirectoryBytes) else { throw bad("central directory too large") }
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
            guard extraStart + extraLength + commentLength <= directory.count else { throw bad("truncated entry") }
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
            guard !o1, !o2 else { throw bad("invalid sizes") }
            compressed = c
            uncompressed = u
            pos = extraStart + extraLength + commentLength
        }
        // The end record's count must match what the directory holds (unless already too many).
        if count <= maxEntries, UInt64(count) != entries { throw bad("inconsistent central directory") }
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
