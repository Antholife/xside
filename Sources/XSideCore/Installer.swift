import Foundation

/// Installs a signed `.app` on a device with `devicectl`.
public struct Installer: Sendable {
    private let runner: CommandRunning

    public init(runner: CommandRunning) {
        self.runner = runner
    }

    public func install(app: URL, deviceID: String) async throws {
        let result = try await runner.run(
            "/usr/bin/xcrun",
            ["devicectl", "device", "install", "app", "--device", deviceID, app.path],
            cwd: nil)
        guard result.status == 0 else {
            let combined = String(decoding: result.stdout, as: UTF8.self) + "\n" + result.stderr
            let mapped = Self.mapError(combined)
            if case .commandFailed = mapped { throw XSideError.commandFailed(tool: "devicectl", status: result.status) }
            throw mapped
        }
    }

    /// Maps combined devicectl output to an error. With no recognizable line it returns
    /// `.commandFailed(tool: "devicectl", status: -1)`; the caller substitutes the real status.
    public static func mapError(_ output: String) -> XSideError {
        let lower = output.lowercased()
        if lower.contains("coredeviceerror error 4016") { return .deviceUnavailable }
        if lower.contains("locked") || lower.contains("passcode") { return .deviceLocked }
        if lower.contains("maximum number of apps") || lower.contains("maximumappsreached")
            || lower.contains("3 apps") { return .maxAppsReached }
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("ERROR:") {
                let msg = line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
                if !msg.isEmpty { return .installFailed(msg) }
            }
        }
        return .commandFailed(tool: "devicectl", status: -1)
    }
}
