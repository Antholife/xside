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

    @Test func severalFramesAreConcatenated() async throws {
        let one = try Data(contentsOf: fixture("hello.zst"))
        let two = scratch(); let out = scratch()
        defer { try? FileManager.default.removeItem(at: two); try? FileManager.default.removeItem(at: out) }
        try (one + one).write(to: two)
        try await Zstd.decompress(two, to: out, maxBytes: 1 << 20, runner: ProcessRunner())
        #expect(try String(contentsOf: out, encoding: .utf8) == "hello\nhello\n")
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

    private func fakeHelper(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-unzstd-\(UUID().uuidString)")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func aHelperKilledBySigintIsNotTooLarge() async throws {
        // The runner reports a signal as its number: SIGINT (2) looks like the cap's exit code.
        let helper = try fakeHelper("kill -INT $$")
        defer { try? FileManager.default.removeItem(at: helper) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("zstd-\(UUID().uuidString)")
        await #expect(throws: DebError.malformed("zstd helper failed")) {
            try await Zstd.decompress(out, to: out, maxBytes: 1, runner: ProcessRunner(), helper: helper)
        }
    }

    @Test func exitTwoNeedsTheCapMessage() async throws {
        let helper = try fakeHelper("exit 2")
        defer { try? FileManager.default.removeItem(at: helper) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("zstd-\(UUID().uuidString)")
        await #expect(throws: DebError.malformed("zstd helper failed")) {
            try await Zstd.decompress(out, to: out, maxBytes: 1, runner: ProcessRunner(), helper: helper)
        }
    }

    @Test func aHelperThatNeverEndsTimesOut() async throws {
        let helper = try fakeHelper("sleep 30")
        defer { try? FileManager.default.removeItem(at: helper) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("zstd-\(UUID().uuidString)")
        await #expect(throws: XSideError.self) {
            try await Zstd.decompress(out, to: out, maxBytes: 1, runner: ProcessRunner(), helper: helper, timeout: .milliseconds(300))
        }
    }

    @Test func helperPathInsideAnAppIsFoundFromTheCLI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zstd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let helpers = root.appendingPathComponent("XSide.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let helper = helpers.appendingPathComponent("xside-unzstd")
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        #expect(Zstd.bundledHelper(near: helpers.appendingPathComponent("xside"))?.lastPathComponent == "xside-unzstd")
        #expect(Zstd.bundledHelper(near: URL(fileURLWithPath: "/usr/local/bin/xside")) == nil)
    }
}
