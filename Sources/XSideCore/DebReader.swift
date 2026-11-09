import Foundation

public struct DebContents: Equatable, Sendable {
    public var control: String
    public var extraction: TarExtraction
}

/// Reads a `.deb` from an untrusted source: members decompressed in-process (or by the pinned
/// helpers) under caps, required to be a tar, then parsed and extracted by `TarReader`. No
/// multi-format archive reader (bsdtar, libarchive) ever sees a member: formats such as mtree
/// make it open local files.
public enum DebReader {
    /// Extracts the files of `data.tar` accepted by `keep` into `root` and returns the `control`
    /// file. `root` must be missing or an empty folder; it is created here and removed again on
    /// ANY throw (extraction can stop halfway). A non-empty `root` is refused and left alone.
    public static func read(_ deb: URL, into root: URL, runner: CommandRunning,
                            keep: @escaping @Sendable (String) -> Bool,
                            maxDataBytes: UInt64 = UInt64(DebLimits.maxDataTarBytes)) async throws -> DebContents {
        let fm = FileManager.default
        var st = stat()
        var created: [URL] = []                       // folders made here, deepest last
        if lstat(root.path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFDIR,
                  (try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty == true else {
                throw DebError.malformed("destination is not empty")
            }
        } else {
            var missing: [URL] = []
            var dir = root
            while lstat(dir.path, &st) != 0, dir.path != "/" { missing.append(dir); dir = dir.deletingLastPathComponent() }
            created = missing.reversed()
            do { try fm.createDirectory(at: root, withIntermediateDirectories: true) } catch {
                for url in created.reversed() { try? fm.removeItem(at: url) }
                throw error
            }
        }
        do {
            return try await readInto(deb, root: root, runner: runner, keep: keep, maxDataBytes: maxDataBytes)
        } catch {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            _ = ZipLimits.repairPermissions(root)
            try? fm.removeItem(at: root)
            for url in created.reversed() where (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
                try? fm.removeItem(at: url)
            }
            throw error
        }
    }

    /// The `control` file only (nothing of `data.tar` is decompressed or extracted), under the
    /// same caps; a work folder in the temporary directory, gone on return.
    public static func control(of deb: URL, runner: CommandRunning) async throws -> String {
        let fm = FileManager.default
        var st = stat()
        guard lstat(deb.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw DebError.notADeb }
        guard st.st_size <= off_t(DebLimits.maxDebBytes) else { throw DebError.tooLarge }
        let archive: Data
        do { archive = try Data(contentsOf: deb, options: .mappedIfSafe) } catch { throw DebError.notADeb }
        let parts = try DebArchive.controlAndData(archive)
        let work = fm.temporaryDirectory.appendingPathComponent("deb-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: work) }
        let controlTar = try await normalised(archive, parts.control, as: "control", in: work,
                                              cap: UInt64(DebLimits.maxControlTarBytes), runner: runner)
        return try controlText(try Data(contentsOf: controlTar))
    }

    private static func readInto(_ deb: URL, root: URL, runner: CommandRunning, keep: @escaping @Sendable (String) -> Bool,
                                 maxDataBytes: UInt64) async throws -> DebContents {
        let fm = FileManager.default
        var st = stat()
        guard lstat(deb.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw DebError.notADeb }
        guard st.st_size <= off_t(DebLimits.maxDebBytes) else { throw DebError.tooLarge }
        let archive: Data
        do { archive = try Data(contentsOf: deb, options: .mappedIfSafe) } catch { throw DebError.notADeb }
        let parts = try DebArchive.controlAndData(archive)

        let work = fm.temporaryDirectory.appendingPathComponent("deb-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: work) }

        let controlTar = try await normalised(archive, parts.control, as: "control", in: work,
                                              cap: UInt64(DebLimits.maxControlTarBytes), runner: runner)
        let control = try controlText(try Data(contentsOf: controlTar))
        let dataTar = try await normalised(archive, parts.data, as: "data", in: work, cap: maxDataBytes, runner: runner)
        let tarData = try Data(contentsOf: dataTar, options: .mappedIfSafe)
        let extraction = try TarReader.extract(tarData, to: root, keep: keep)
        return DebContents(control: control, extraction: extraction)
    }

    /// One member -> a plain tar in `dir`, at most `cap` bytes; anything that is not a tar is refused.
    private static func normalised(_ archive: Data, _ member: DebMember, as label: String, in dir: URL,
                                   cap: UInt64, runner: CommandRunning) async throws -> URL {
        let raw = dir.appendingPathComponent("\(label).member")
        let body = archive[(archive.startIndex + member.range.lowerBound)..<(archive.startIndex + member.range.upperBound)]
        try body.write(to: raw)
        let out = dir.appendingPathComponent("\(label).tar")
        let kind = CompressionKind.sniff(body.prefix(512), name: member.name)
        try await StreamDecompressor.decompress(raw, kind: kind, to: out, maxBytes: cap, runner: runner)
        do {
            let handle = try FileHandle(forReadingFrom: out)
            defer { try? handle.close() }
            guard let first = try handle.read(upToCount: 512), isTarHeader(first) else {
                throw DebError.malformed("\(label).tar is not a tar archive")
            }
        } catch let error as DebError {
            throw error
        } catch {
            throw DebError.malformed("\(label).tar is unreadable")
        }
        return out
    }

    /// `ustar` at offset 257, or a first block whose checksum field matches (v7 tars).
    static func isTarHeader(_ block: Data) -> Bool {
        guard block.count == 512 else { return false }
        let b = [UInt8](block)
        if Array(b[257..<262]) == Array("ustar".utf8) { return true }
        let field = b[148..<156].prefix { $0 != 0 && $0 != 0x20 }
        guard !field.isEmpty, field.allSatisfy({ $0 >= 0x30 && $0 <= 0x37 }),
              let stored = Int(String(decoding: field, as: UTF8.self), radix: 8) else { return false }
        var sum = 0
        for (i, v) in b.enumerated() { sum += (148..<156).contains(i) ? 0x20 : Int(v) }
        return sum == stored
    }

    private static func controlText(_ tar: Data) throws -> String {
        let entries = try TarReader.entries(tar, maxEntries: DebLimits.maxEntries)
        guard let entry = entries.first(where: { $0.kind == .file && TarPath.normalize($0.path) == "control" }) else {
            throw DebError.malformed("no control file")
        }
        guard entry.size <= DebLimits.maxControlFileBytes else { throw DebError.tooLarge }
        return String(decoding: tar[entry.dataRange], as: UTF8.self)
    }
}
