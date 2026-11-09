import Foundation
import Testing
@testable import XSideCore

struct StreamDecompressorTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name); try data.write(to: url); return url
    }
    private func run(_ exe: String, _ args: [String], stdin: URL? = nil, stdout: URL? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        if let stdin { p.standardInput = try FileHandle(forReadingFrom: stdin) }
        if let stdout {
            FileManager.default.createFile(atPath: stdout.path, contents: nil)
            p.standardOutput = try FileHandle(forWritingTo: stdout)
        }
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }
    private let text = Data((0..<2000).map { "Package: pkg\($0)\nVersion: 1.\($0)\n\n" }.joined().utf8)

    private func gzip(_ data: Data) throws -> Data {
        let plain = try file("plain", data), out = dir.appendingPathComponent("plain.gz")
        try run("/usr/bin/gzip", ["-c"], stdin: plain, stdout: out)
        return try Data(contentsOf: out)
    }
    /// Raw xz of a tar holding `data` (bsdtar writes it; macOS has no xz tool).
    private func xzTar(_ data: Data) throws -> (xz: URL, tar: Data) {
        let inner = FakeDeb.tar([.file("Packages", data)])
        let src = try file("inner.tar", inner), out = dir.appendingPathComponent("inner.tar.xz")
        try run("/usr/bin/tar", ["--xz", "-cf", out.path, "@" + src.path])
        return (out, inner)
    }

    @Test func gzipWithNameAndExtraFields() async throws {
        let plain = try gzip(text)
        let deflate = plain.dropFirst(10)                       // after the plain 10-byte header
        var header = Data([0x1F, 0x8B, 8, 0x1E, 0, 0, 0, 0, 0, 3])   // FEXTRA | FNAME | FCOMMENT | FHCRC
        header += Data([4, 0, 0xAA, 0xBB, 0xCC, 0xDD])           // XLEN 4 + extra
        header += Data("Packages\0".utf8) + Data("a comment\0".utf8) + Data([0x12, 0x34])
        let input = try file("n.gz", header + deflate)
        let out = dir.appendingPathComponent("n.out")
        try await StreamDecompressor.decompress(input, kind: .gzip, to: out, maxBytes: 1 << 20, runner: ProcessRunner())
        #expect(try Data(contentsOf: out) == text)
    }

    @Test func gzipPlain() async throws {
        let input = try file("p.gz", try gzip(text)), out = dir.appendingPathComponent("p.out")
        try await StreamDecompressor.decompress(input, kind: .gzip, to: out, maxBytes: 1 << 20, runner: ProcessRunner())
        #expect(try Data(contentsOf: out) == text)
    }

    @Test func xz() async throws {
        let (xz, inner) = try xzTar(text), out = dir.appendingPathComponent("x.out")
        try await StreamDecompressor.decompress(xz, kind: .xz, to: out, maxBytes: 1 << 20, runner: ProcessRunner())
        // bsdtar re-wrote the entries: compare what the tar holds
        let got = try Data(contentsOf: out)
        let entries = try TarReader.entries(got)
        #expect(entries.map(\.path) == ["Packages"] && got[entries[0].dataRange] == text)
        _ = inner
    }

    @Test func bzip2() async throws {
        let plain = try file("b", text), bz = dir.appendingPathComponent("b.bz2"), out = dir.appendingPathComponent("b.out")
        try run("/usr/bin/bzip2", ["-c"], stdin: plain, stdout: bz)
        try await StreamDecompressor.decompress(bz, kind: .bzip2, to: out, maxBytes: 1 << 20, runner: ProcessRunner())
        #expect(try Data(contentsOf: out) == text)
    }

    @Test func zstd() async throws {
        let input = try file("z.zst", FakeDeb.zstdStored(text)), out = dir.appendingPathComponent("z.out")
        try await StreamDecompressor.decompress(input, kind: .zstd, to: out, maxBytes: 1 << 20, runner: ProcessRunner())
        #expect(try Data(contentsOf: out) == text)
    }

    @Test func noneCopiesAndLzmaIsUnsupported() async throws {
        let input = try file("n", text), out = dir.appendingPathComponent("n.out")
        try await StreamDecompressor.decompress(input, kind: .none, to: out, maxBytes: 1 << 20, runner: ProcessRunner())
        #expect(try Data(contentsOf: out) == text)
        await #expect(throws: DebError.unsupportedCompression("lzma")) {
            try await StreamDecompressor.decompress(input, kind: .lzma, to: out, maxBytes: 1 << 20, runner: ProcessRunner())
        }
        await #expect(throws: DebError.tooLarge) {
            try await StreamDecompressor.decompress(input, kind: .none, to: out, maxBytes: 10, runner: ProcessRunner())
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func capStopsEachKind() async throws {
        let zeros = Data(count: 4 << 20)
        let bzSrc = try file("zb", zeros), bz = dir.appendingPathComponent("zb.bz2")
        try run("/usr/bin/bzip2", ["-c"], stdin: bzSrc, stdout: bz)
        let inputs: [(CompressionKind, URL)] = [
            (.gzip, try file("z.gz", try gzip(zeros))),
            (.xz, try xzTar(zeros).xz),
            (.bzip2, bz),
            (.zstd, try file("z.zst", FakeDeb.zstdStored(zeros))),
            (.none, bzSrc),
        ]
        for (kind, input) in inputs {
            let out = dir.appendingPathComponent("cap-\(kind.rawValue)")
            await #expect(throws: DebError.tooLarge, "\(kind)") {
                try await StreamDecompressor.decompress(input, kind: kind, to: out, maxBytes: 1 << 20, runner: ProcessRunner())
            }
            #expect(!FileManager.default.fileExists(atPath: out.path), "\(kind)")
        }
    }

    @Test func truncatedStreamIsMalformed() async throws {
        let gz = try gzip(Data(count: 1 << 20))
        let (xz, _) = try xzTar(Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 ^ $0 >> 3) }))
        let bzSrc = try file("tb", Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 7 ^ $0 >> 2) })), bz = dir.appendingPathComponent("tb.bz2")
        try run("/usr/bin/bzip2", ["-c"], stdin: bzSrc, stdout: bz)
        let cases: [(CompressionKind, Data)] = [
            (.gzip, gz.prefix(gz.count / 2)),
            (.gzip, gz.prefix(gz.count - 3)),
            (.xz, try Data(contentsOf: xz).prefix(100)),
            (.bzip2, try Data(contentsOf: bz).prefix(1000)),
            (.zstd, FakeDeb.zstdStored(text).dropLast(10)),
        ]
        for (i, (kind, data)) in cases.enumerated() {
            let input = try file("t\(i)", Data(data)), out = dir.appendingPathComponent("t\(i).out")
            await #expect(throws: DebError.self, "\(kind) \(i)") {
                try await StreamDecompressor.decompress(input, kind: kind, to: out, maxBytes: 8 << 20, runner: ProcessRunner())
            }
            #expect(!FileManager.default.fileExists(atPath: out.path), "\(kind) \(i)")
        }
    }

    @Test func garbageGzipHeadersAreMalformed() async throws {
        for (i, bytes) in [[UInt8](), [0x1F, 0x8B], [0x1F, 0x8B, 8, 0x04, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF], [0x1F, 0x8B, 8, 0x08, 0, 0, 0, 0, 0, 0, 0x41]].enumerated() {
            let input = try file("g\(i)", Data(bytes)), out = dir.appendingPathComponent("g\(i).out")
            await #expect(throws: DebError.self) {
                try await StreamDecompressor.decompress(input, kind: .gzip, to: out, maxBytes: 1 << 20, runner: ProcessRunner())
            }
        }
    }
}
