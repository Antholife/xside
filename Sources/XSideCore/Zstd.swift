import Foundation

/// zstd decompression through `xside-unzstd`, a decompression-only helper built from facebook/zstd
/// at a pinned tag (scripts/build-unzstd.sh). macOS has no zstd of its own. Files in, files out.
public enum Zstd {
    public static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    /// Printed by the helper on stderr when the output would pass the cap (with exit status 2). A
    /// helper killed by SIGINT also reports 2, so the status alone is not proof.
    static let capMessage = "output over the cap"

    /// The helper inside the app (release builds stop here). Debug builds, which run tests and
    /// development copies, also accept `XSIDE_UNZSTD` (when set it is the only candidate) and
    /// `build/zstd/xside-unzstd` of the package (after `scripts/build-unzstd.sh` or `bundle.sh`).
    public static func helper() -> URL? {
        #if DEBUG
        return helper(environment: ProcessInfo.processInfo.environment)
        #else
        return bundledHelper(near: Bundle.main.executableURL?.resolvingSymlinksInPath())
            ?? bundledHelper(near: Bundle.main.bundleURL)
        #endif
    }

    /// `Contents/Helpers/xside-unzstd` of the `.app` that contains `url` (the app's own executable
    /// or the `xside` tool in Contents/Helpers), if it is there and executable.
    static func bundledHelper(near url: URL?) -> URL? {
        var dir = url
        while let current = dir, current.path != "/" {
            if current.pathExtension == "app" {
                let helper = current.appendingPathComponent("Contents/Helpers/xside-unzstd")
                return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
            }
            dir = current.deletingLastPathComponent()
        }
        return nil
    }

    #if DEBUG
    static func helper(environment: [String: String], filePath: String = #filePath) -> URL? {
        let fm = FileManager.default
        func usable(_ url: URL) -> URL? { fm.isExecutableFile(atPath: url.path) ? url : nil }
        if let override = environment["XSIDE_UNZSTD"], !override.isEmpty {
            return usable(URL(fileURLWithPath: override))
        }
        if let bundled = bundledHelper(near: Bundle.main.executableURL?.resolvingSymlinksInPath())
            ?? bundledHelper(near: Bundle.main.bundleURL) { return bundled }
        // Sources/XSideCore/Zstd.swift -> package root
        let root = URL(fileURLWithPath: filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return usable(root.appendingPathComponent("build/zstd/xside-unzstd"))
    }
    #endif

    /// Decompresses `input` into `output` (one or more frames). Over `maxBytes` of output throws
    /// `.tooLarge`; no helper throws `.unsupportedCompression("zstd")`; a helper that is stopped
    /// for taking too long throws `XSideError.timedOut`; anything else `.malformed`. No output
    /// file is left behind on a throw.
    public static func decompress(_ input: URL, to output: URL, maxBytes: UInt64, runner: CommandRunning) async throws {
        try await decompress(input, to: output, maxBytes: maxBytes, runner: runner, helper: helper())
    }

    /// 60 s, plus a second per 20 MiB of allowed output (decoding runs at hundreds of MB/s).
    static func timeout(forMaxBytes maxBytes: UInt64) -> Duration {
        .seconds(60 + Int(min(maxBytes / (20 << 20), 3600)))
    }

    static func decompress(_ input: URL, to output: URL, maxBytes: UInt64, runner: CommandRunning, helper: URL?, timeout: Duration? = nil) async throws {
        guard let helper else { throw DebError.unsupportedCompression("zstd") }
        let result: CommandResult
        do {
            result = try await runner.run(helper.path, [input.path, output.path, String(maxBytes)], cwd: nil,
                                          timeout: timeout ?? Self.timeout(forMaxBytes: maxBytes))
        } catch {
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError { throw error }
            if case XSideError.timedOut = error { throw error }
            throw DebError.malformed("zstd")
        }
        if result.status == 0 { return }
        try? FileManager.default.removeItem(at: output)
        if result.status == 2 && result.stderr.contains(capMessage) { throw DebError.tooLarge }
        // A signal arrives as its number (SIGINT = 2, SIGKILL = 9): never taken for the cap.
        if result.status == 1 { throw DebError.malformed("zstd") }
        throw DebError.malformed("zstd helper failed")
    }
}
