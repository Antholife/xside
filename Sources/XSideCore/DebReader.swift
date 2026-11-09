import Foundation

public struct DebContents: Equatable, Sendable {
    public var control: String
    public var extraction: TarExtraction
}

/// Reads a `.deb` from an untrusted source: members decompressed under caps, normalised to one
/// plain pax tar by bsdtar (which reads the member as an archive and never writes its entries to
/// disk), then parsed and extracted by `TarReader`.
public enum DebReader {
    /// Extracts the files of `data.tar` accepted by `keep` into `root` and returns the `control`
    /// file. `root` must be missing or an empty folder; it is created here and removed again on
    /// ANY throw (extraction can stop halfway). A non-empty `root` is refused and left alone.
    public static func read(_ deb: URL, into root: URL, runner: CommandRunning,
                            keep: @escaping @Sendable (String) -> Bool,
                            maxDataBytes: UInt64 = UInt64(DebLimits.maxDataTarBytes)) async throws -> DebContents {
        let fm = FileManager.default
        var st = stat()
        if lstat(root.path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFDIR,
                  (try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty == true else {
                throw DebError.malformed("destination is not empty")
            }
        } else {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        do {
            return try await readInto(deb, root: root, runner: runner, keep: keep, maxDataBytes: maxDataBytes)
        } catch {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            _ = ZipLimits.repairPermissions(root)
            try? fm.removeItem(at: root)
            throw error
        }
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

    /// One member -> a plain pax tar in `dir`, at most `cap` bytes.
    private static func normalised(_ archive: Data, _ member: DebMember, as label: String, in dir: URL,
                                   cap: UInt64, runner: CommandRunning) async throws -> URL {
        let fm = FileManager.default
        let raw = dir.appendingPathComponent("\(label).member")
        let body = archive[(archive.startIndex + member.range.lowerBound)..<(archive.startIndex + member.range.upperBound)]
        try body.write(to: raw)
        let source: URL
        if CompressionKind.sniff(body.prefix(512), name: member.name) == .zstd {
            source = dir.appendingPathComponent("\(label).zst.tar")
            try await Zstd.decompress(raw, to: source, maxBytes: cap, runner: runner)
        } else {
            source = raw
        }
        let out = dir.appendingPathComponent("\(label).tar")
        let result: CommandResult
        do {
            result = try await ZipLimits.watchingFile(out, maxBytes: cap) {
                try await runner.run("/usr/bin/tar", ["-c", "-f", out.path, "--format", "pax", "@" + source.path],
                                     cwd: nil, timeout: CommandTimeout.standard)
            }
        } catch {
            try? fm.removeItem(at: out)
            throw error
        }
        guard result.status == 0 else {
            try? fm.removeItem(at: out)
            throw DebError.malformed("\(label).tar is not a readable archive")
        }
        return out
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
