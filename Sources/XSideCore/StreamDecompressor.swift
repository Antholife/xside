import Foundation
import Compression

/// How a file or archive member is compressed.
public enum CompressionKind: String, Sendable {
    case none, gzip, xz, bzip2, lzma, zstd

    /// By magic first (a wrong extension is common), by name second. Unknown content with an
    /// unknown name is `none`: the next step fails on it if it is not what it should be.
    public static func sniff(_ head: Data, name: String) -> CompressionKind {
        let b = [UInt8](head.prefix(512))
        func starts(_ magic: [UInt8]) -> Bool { b.count >= magic.count && Array(b.prefix(magic.count)) == magic }
        if starts([0x1F, 0x8B]) { return .gzip }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if starts([0x42, 0x5A, 0x68]) { return .bzip2 }
        if starts(Zstd.magic) { return .zstd }
        if starts([0x5D, 0x00, 0x00]) { return .lzma }
        if b.count >= 262, Array(b[257..<262]) == Array("ustar".utf8) { return .none }
        switch (name.lowercased() as NSString).pathExtension {
        case "gz", "tgz": return .gzip
        case "xz", "txz": return .xz
        case "bz2", "tbz", "tbz2": return .bzip2
        case "lzma": return .lzma
        case "zst", "zstd": return .zstd
        default: return .none
        }
    }
}

/// Decompression of raw files (repo indexes) into a file, capped. On any throw `output` is gone.
public enum StreamDecompressor {
    public static func decompress(_ input: URL, kind: CompressionKind, to output: URL, maxBytes: UInt64,
                                  runner: CommandRunning) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: output)
        do {
            var st = stat()
            guard lstat(input.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw DebError.malformed("unreadable input") }
            switch kind {
            case .none:
                guard UInt64(max(st.st_size, 0)) <= maxBytes else { throw DebError.tooLarge }
                try fm.copyItem(at: input, to: output)
            case .gzip:
                try gunzip(try read(input), to: output, maxBytes: maxBytes)
            case .xz, .lzma:
                // Compression's LZMA decoder reads both the .xz container and the legacy .lzma one.
                let data = try read(input)
                try withOutput(output) { handle in
                    var total: UInt64 = 0
                    _ = try inflate(data, from: 0, algorithm: COMPRESSION_LZMA, handle: handle, total: &total, maxBytes: maxBytes)
                }
            case .bzip2:
                try await bzip2(input, to: output, maxBytes: maxBytes, runner: runner)
            case .zstd:
                try await Zstd.decompress(input, to: output, maxBytes: maxBytes, runner: runner)
            }
        } catch {
            try? fm.removeItem(at: output)
            throw error
        }
    }

    private static func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw DebError.malformed("unreadable input") }
    }

    private static func withOutput(_ output: URL, _ body: (FileHandle) throws -> Void) throws {
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { throw DebError.malformed("cannot write output") }
        defer { try? handle.close() }
        try body(handle)
    }

    /// One gzip member, checked against its size field. Compression's decoder does not say where
    /// a stream ended, so a file with several members (or bytes after the first) is refused: the
    /// size at the end of the file would not match.
    private static func gunzip(_ data: Data, to output: URL, maxBytes: UInt64) throws {
        let start = try gzipHeaderEnd(data)
        guard data.count - start >= 8 else { throw DebError.malformed("truncated gzip trailer") }
        try withOutput(output) { handle in
            var total: UInt64 = 0
            _ = try inflate(data, from: start, algorithm: COMPRESSION_ZLIB, handle: handle, total: &total, maxBytes: maxBytes)
            let isize = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.count - 4 + $1]) << UInt32(8 * $1) }
            guard isize == UInt32(truncatingIfNeeded: total) else {
                throw DebError.malformed("gzip size mismatch (several members are not supported)")
            }
        }
    }

    /// Offset of the first deflate byte (RFC 1952).
    static func gzipHeaderEnd(_ d: Data) throws -> Int {
        let b = [UInt8](d.prefix(1 << 20))
        func bad() -> DebError { .malformed("bad gzip header") }
        guard b.count >= 10, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw bad() }
        let flags = b[3]
        guard flags & 0xE0 == 0 else { throw bad() }
        var pos = 10
        if flags & 0x04 != 0 {                                   // FEXTRA
            guard pos + 2 <= b.count else { throw bad() }
            pos += 2 + Int(b[pos]) + Int(b[pos + 1]) << 8
        }
        for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {   // FNAME, FCOMMENT: zero-terminated
            guard pos <= b.count, let end = b[pos...].firstIndex(of: 0) else { throw bad() }
            pos = end + 1
        }
        if flags & 0x02 != 0 { pos += 2 }                        // FHCRC
        guard pos <= b.count, pos < d.count else { throw bad() }
        return pos
    }

    /// Streams one compressed stream starting at `data[from]` into `handle`, adding to `total`
    /// (checked against `maxBytes` per chunk before it is written). Returns how many input bytes
    /// the stream used.
    private static func inflate(_ data: Data, from: Int, algorithm: compression_algorithm, handle: FileHandle,
                                total: inout UInt64, maxBytes: UInt64) throws -> Int {
        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw DebError.malformed("decoder")
        }
        defer { compression_stream_destroy(streamPtr) }
        var written = total
        let used: Int = try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let body = UnsafeRawBufferPointer(rebasing: raw[from...])
            streamPtr.pointee.src_ptr = body.baseAddress.map { $0.assumingMemoryBound(to: UInt8.self) } ?? UnsafePointer(dst)
            streamPtr.pointee.src_size = body.count
            while true {
                try Task.checkCancellation()
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = chunk
                let before = streamPtr.pointee.src_size
                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - streamPtr.pointee.dst_size
                if produced > 0 {
                    let (sum, overflow) = written.addingReportingOverflow(UInt64(produced))
                    guard !overflow, sum <= maxBytes else { throw DebError.tooLarge }
                    written = sum
                    try handle.write(contentsOf: Data(bytes: dst, count: produced))
                }
                switch status {
                case COMPRESSION_STATUS_END: return body.count - streamPtr.pointee.src_size
                case COMPRESSION_STATUS_OK:
                    // No input used and nothing produced: the stream is cut short.
                    if produced == 0 && streamPtr.pointee.src_size == before { throw DebError.malformed("truncated stream") }
                default: throw DebError.malformed("corrupt stream")
                }
            }
        }
        total = written
        return used
    }

    /// `bzip2 -d -k` on a copy (the runner captures stdout, so no `-c`), the size watched.
    private static func bzip2(_ input: URL, to output: URL, maxBytes: UInt64, runner: CommandRunning) async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("bzip2-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("in.bz2"), plain = dir.appendingPathComponent("in")
        try fm.copyItem(at: input, to: copy)
        let result: CommandResult
        do {
            result = try await ZipLimits.watchingFile(plain, maxBytes: maxBytes) {
                // The shell only sets a hard file-size limit (RLIMIT_FSIZE; bash counts in 1024-byte
                // blocks, two past the cap) and clears bzip2's option variables; paths are arguments.
                let blocks = (maxBytes / 1024).addingReportingOverflow(2).partialValue
                return try await runner.run("/bin/bash", ["-c", "unset BZIP BZIP2; ulimit -f \"$2\" && exec /usr/bin/bzip2 -d -k \"$1\"",
                                                        "bash", copy.path, String(blocks)], cwd: nil)
            }
        } catch {
            if error is CancellationError || error is DebError { throw error }
            if case XSideError.timedOut = error { throw error }
            throw DebError.malformed("bzip2")
        }
        guard result.status == 0 else { throw DebError.malformed("bzip2") }
        try fm.moveItem(at: plain, to: output)
    }
}
