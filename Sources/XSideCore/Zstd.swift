import Foundation

/// zstd decompression through `xside-unzstd`, a decompression-only helper built from facebook/zstd
/// at a pinned tag (scripts/build-unzstd.sh). macOS has no zstd of its own. Files in, files out.
public enum Zstd {
    public static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    /// `XSIDE_UNZSTD` (tests; when set it is the only candidate), then `Contents/Helpers` of the
    /// app, then `build/zstd/xside-unzstd` of the package (found by `swift test` once
    /// `scripts/build-unzstd.sh` or `scripts/bundle.sh` has run).
    public static func helper() -> URL? { helper(environment: ProcessInfo.processInfo.environment) }

    static func helper(environment: [String: String], filePath: String = #filePath) -> URL? {
        let fm = FileManager.default
        func usable(_ url: URL) -> URL? { fm.isExecutableFile(atPath: url.path) ? url : nil }
        if let override = environment["XSIDE_UNZSTD"], !override.isEmpty {
            return usable(URL(fileURLWithPath: override))
        }
        if let bundled = usable(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/xside-unzstd")) {
            return bundled
        }
        // Sources/XSideCore/Zstd.swift -> package root
        let root = URL(fileURLWithPath: filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return usable(root.appendingPathComponent("build/zstd/xside-unzstd"))
    }

    /// Decompresses `input` into `output` (one or more frames). Over `maxBytes` of output throws
    /// `.tooLarge`; no helper throws `.unsupportedCompression("zstd")`; anything else `.malformed`.
    /// No output file is left behind on a throw.
    public static func decompress(_ input: URL, to output: URL, maxBytes: UInt64, runner: CommandRunning) async throws {
        try await decompress(input, to: output, maxBytes: maxBytes, runner: runner, helper: helper())
    }

    static func decompress(_ input: URL, to output: URL, maxBytes: UInt64, runner: CommandRunning, helper: URL?) async throws {
        guard let helper else { throw DebError.unsupportedCompression("zstd") }
        let result: CommandResult
        do {
            result = try await runner.run(helper.path, [input.path, output.path, String(maxBytes)], cwd: nil)
        } catch {
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError { throw error }
            throw DebError.malformed("zstd")
        }
        switch result.status {
        case 0: return
        case 2:
            try? FileManager.default.removeItem(at: output)
            throw DebError.tooLarge
        default:
            try? FileManager.default.removeItem(at: output)
            throw DebError.malformed("zstd")
        }
    }
}
