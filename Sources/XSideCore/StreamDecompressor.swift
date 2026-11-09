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
            switch kind {
            case .none:
                let size = (try? fm.attributesOfItem(atPath: input.path)[.size] as? UInt64) ?? nil
                guard let size else { throw DebError.malformed("unreadable input") }
                guard size <= maxBytes else { throw DebError.tooLarge }
                try fm.copyItem(at: input, to: output)
            case .gzip:
                let data = try read(input)
                let start = try gzipHeaderEnd(data)
                let written = try inflate(data, from: start, algorithm: COMPRESSION_ZLIB, to: output, maxBytes: maxBytes) { rest in
                    // 8 bytes follow the deflate stream: CRC-32 and the size modulo 2^32.
                    guard rest.count >= 8 else { throw DebError.malformed("truncated gzip trailer") }
                    return rest
                }
                // The size field catches a stream that ended early on its own.
                let tail = data.suffix(8).suffix(4)
                let isize = tail.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32(8 * $1.offset) }
                if isize != UInt32(truncatingIfNeeded: written) { throw DebError.malformed("gzip size mismatch") }
            case .xz:
                let data = try read(input)
                _ = try inflate(data, from: 0, algorithm: COMPRESSION_LZMA, to: output, maxBytes: maxBytes) { $0 }
            case .bzip2:
                try await bzip2(input, to: output, maxBytes: maxBytes, runner: runner)
            case .zstd:
                try await Zstd.decompress(input, to: output, maxBytes: maxBytes, runner: runner)
            case .lzma:
                throw DebError.unsupportedCompression("lzma")
            }
        } catch {
            try? fm.removeItem(at: output)
            throw error
        }
    }

    private static func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw DebError.malformed("unreadable input") }
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
            guard let end = b[min(pos, b.count)...].firstIndex(of: 0) else { throw bad() }
            pos = end + 1
        }
        if flags & 0x02 != 0 { pos += 2 }                        // FHCRC
        guard pos <= b.count, pos < d.count else { throw bad() }
        return pos
    }

    /// Streams `data[from...]` through the Compression framework into `output`; returns the bytes written.
    private static func inflate(_ data: Data, from: Int, algorithm: compression_algorithm, to output: URL,
                                maxBytes: UInt64, _ trim: (Data) throws -> Data) throws -> UInt64 {
        let body = try trim(data.dropFirst(from))
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { throw DebError.malformed("cannot write output") }
        defer { try? handle.close() }
        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw DebError.malformed("decoder")
        }
        defer { compression_stream_destroy(streamPtr) }
        var total: UInt64 = 0
        try body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            streamPtr.pointee.src_ptr = base ?? UnsafePointer(dst)
            streamPtr.pointee.src_size = raw.count
            while true {
                try Task.checkCancellation()
                streamPtr.pointee.dst_ptr = dst
                streamPtr.pointee.dst_size = chunk
                let before = streamPtr.pointee.src_size
                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - streamPtr.pointee.dst_size
                if produced > 0 {
                    total += UInt64(produced)
                    guard total <= maxBytes else { throw DebError.tooLarge }
                    try handle.write(contentsOf: Data(bytes: dst, count: produced))
                }
                switch status {
                case COMPRESSION_STATUS_END: return
                case COMPRESSION_STATUS_OK:
                    // No input used and nothing produced: the stream is cut short.
                    if produced == 0 && streamPtr.pointee.src_size == before { throw DebError.malformed("truncated stream") }
                default: throw DebError.malformed("corrupt stream")
                }
            }
        }
        return total
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
                try await runner.run("/usr/bin/bzip2", ["-d", "-k", copy.path], cwd: nil)
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
