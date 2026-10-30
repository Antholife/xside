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
            cwd: nil, timeout: CommandTimeout.deviceInstall)
        guard result.status == 0 else {
            let combined = String(decoding: result.stdout, as: UTF8.self) + "\n" + result.stderr
            let mapped = Self.mapError(combined)
            if case .commandFailed = mapped { throw XSideError.commandFailed(tool: "devicectl", status: result.status) }
            throw mapped
        }
    }

    /// Maps combined devicectl output to an error. With no recognizable line it returns
    /// `.commandFailed(tool: "devicectl", status: -1)`; the caller substitutes the real status.
    /// Only error blocks (and known error codes anywhere) are matched, so an app or device name
    /// ("Locked Notes") or a progress line can't pass for a cause; "locked" is tried last.
    /// devicectl often prints a generic `ERROR:` line and the real cause below it, see `errorBlocks`.
    public static func mapError(_ output: String) -> XSideError {
        let lower = output.lowercased()
        if lower.contains("coredeviceerror error 4016") { return .deviceUnavailable }
        if lower.contains("maximumappsreached") { return .maxAppsReached }
        let blocks = errorBlocks(output)
        let messages = blocks.map(\.first)
        let texts = blocks.flatMap { $0.lines }.map { withoutQuotedNames($0).lowercased() }
        if texts.contains(where: { t in ["maximum number of apps", "maximum number of installed apps", "3 apps", "three apps"].contains { t.contains($0) } }) {
            return .maxAppsReached
        }
        if texts.contains(where: { $0.contains("passcode") }) { return .deviceLocked }
        if texts.contains(where: { t in ["is locked", "device locked", "locked device", "while locked"].contains { t.contains($0) } }) {
            return .deviceLocked
        }
        if let first = messages.first { return .installFailed(first) }
        return .commandFailed(tool: "devicectl", status: -1)
    }

    /// Each `ERROR:` line (`first`, its text) with the lines that detail it (`lines`, all of
    /// them): the following indented lines, `Underlying error …` lines and `NSLocalized…` /
    /// `NSUnderlyingError` entries. A block ends at the first other line.
    static func errorBlocks(_ output: String) -> [(first: String, lines: [String])] {
        var blocks: [(first: String, lines: [String])] = []
        var open = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("ERROR:") {
                let msg = line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
                open = !msg.isEmpty
                if open { blocks.append((msg, [msg])) }
                continue
            }
            let detail = raw.first?.isWhitespace == true || line.hasPrefix("Underlying error")
                || line.hasPrefix("NSLocalized") || line.hasPrefix("NSUnderlyingError")
            guard open, !line.isEmpty else { continue }
            if detail { blocks[blocks.count - 1].lines.append(line) } else { open = false }
        }
        return blocks
    }

    /// Drops quoted parts (“Name”, "Name", 'Name') and `*.app` tokens: names, not causes.
    private static func withoutQuotedNames(_ text: String) -> String {
        var result = ""
        var closing: Character?
        for c in text {
            if let close = closing {
                if c == close { closing = nil }
                continue
            }
            switch c {
            case "\u{201C}": closing = "\u{201D}"
            case "\"": closing = "\""
            case "\u{2018}": closing = "\u{2019}"
            default: result.append(c)
            }
        }
        return result.split(separator: " ").filter { !$0.lowercased().hasSuffix(".app") }.joined(separator: " ")
    }
}
