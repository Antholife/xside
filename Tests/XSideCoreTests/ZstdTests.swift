import Foundation
import Testing
@testable import XSideCore

@Suite("zstd helper", .enabled(if: Zstd.helper() != nil))
struct ZstdTests {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/zstd/\(name)")
    }
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zstd-\(UUID().uuidString)")
    }

    @Test func decompressesAFrame() async throws {
        let out = scratch(); defer { try? FileManager.default.removeItem(at: out) }
        try await Zstd.decompress(fixture("hello.zst"), to: out, maxBytes: 1 << 20, runner: ProcessRunner())
        #expect(try String(contentsOf: out, encoding: .utf8) == "hello\n")
    }

    @Test func stopsAtTheCap() async throws {
        let out = scratch(); defer { try? FileManager.default.removeItem(at: out) }
        await #expect(throws: DebError.tooLarge) {
            try await Zstd.decompress(fixture("zeros-4MiB.zst"), to: out, maxBytes: 1 << 20, runner: ProcessRunner())
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func exactCapIsAllowed() async throws {
        let out = scratch(); defer { try? FileManager.default.removeItem(at: out) }
        try await Zstd.decompress(fixture("zeros-4MiB.zst"), to: out, maxBytes: 4 << 20, runner: ProcessRunner())
        #expect(try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? UInt64 == 4 << 20)
    }

    @Test func garbageIsMalformed() async throws {
        let junk = scratch(); let out = scratch()
        defer { try? FileManager.default.removeItem(at: junk); try? FileManager.default.removeItem(at: out) }
        try Data("this is not zstd".utf8).write(to: junk)
        await #expect(throws: DebError.malformed("zstd")) {
            try await Zstd.decompress(junk, to: out, maxBytes: 1 << 20, runner: ProcessRunner())
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func truncatedIsMalformed() async throws {
        let data = try Data(contentsOf: fixture("zeros-4MiB.zst"))
        let cut = scratch(); let out = scratch()
        defer { try? FileManager.default.removeItem(at: cut); try? FileManager.default.removeItem(at: out) }
        try data.prefix(data.count - 3).write(to: cut)
        await #expect(throws: DebError.malformed("zstd")) {
            try await Zstd.decompress(cut, to: out, maxBytes: 8 << 20, runner: ProcessRunner())
        }
    }
}

@Suite("zstd without helper")
struct ZstdNoHelperTests {
    @Test func noHelperSaysUnsupported() async throws {
        // XSIDE_UNZSTD set to a missing file: no helper, and no fallback to another one.
        #expect(Zstd.helper(environment: ["XSIDE_UNZSTD": "/nonexistent"]) == nil)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("zstd-\(UUID().uuidString)")
        await #expect(throws: DebError.unsupportedCompression("zstd")) {
            try await Zstd.decompress(out, to: out, maxBytes: 1, runner: ProcessRunner(), helper: nil)
        }
    }
}
