import Foundation

/// Installs a signed `.app` on a device, or removes one, with `devicectl`.
public struct Installer: Sendable {
    private let runner: CommandRunning

    public init(runner: CommandRunning) {
        self.runner = runner
    }

    /// No progress from here: devicectl prints none for an install, even on a terminal or with
    /// --verbose (checked on 31/10/2026), only "App installed" at the end.
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

    /// Removes the app signed as `bundleID` (and its data) from the device. An app that is
    /// already gone counts as removed, so asking twice is harmless.
    public func uninstall(bundleID: String, deviceID: String) async throws {
        let result = try await runner.run(
            "/usr/bin/xcrun",
            ["devicectl", "device", "uninstall", "app", "--device", deviceID, bundleID],
            cwd: nil, timeout: CommandTimeout.deviceInstall)
        guard result.status == 0 else {
            let combined = String(decoding: result.stdout, as: UTF8.self) + "\n" + result.stderr
            if let mapped = Self.mapUninstallError(combined) {
                if case .commandFailed = mapped { throw XSideError.commandFailed(tool: "devicectl", status: result.status) }
                throw mapped
            }
            return
        }
    }

    /// Whether the app signed as `bundleID` is on the device. Nil when devicectl fails or its
    /// output can't be read: never a guess, a "false" makes XSide forget the app there.
    public func isInstalled(bundleID: String, deviceID: String) async -> Bool? {
        await installedBundleIDs(deviceID: deviceID)?.contains(bundleID)
    }

    /// Every app on the device, nil when that can't be told. All of them, not devicectl's default
    /// "developer apps": an app missing from a filtered list would be forgotten by mistake. So the
    /// list is never empty (system apps); an empty one is treated as unreadable.
    public func installedBundleIDs(deviceID: String) async -> Set<String>? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("xside-apps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let result = try? await runner.run(
            "/usr/bin/xcrun",
            ["devicectl", "device", "info", "apps", "--device", deviceID, "--include-all-apps",
             "--json-output", file.path],
            cwd: nil, timeout: CommandTimeout.deviceQuery),
              result.status == 0,
              let data = try? Data(contentsOf: file),
              let ids = Self.installedBundleIDs(data), !ids.isEmpty else { return nil }
        return Set(ids)
    }

    /// The bundle ids in `devicectl device info apps --json-output` (`result.apps[].bundleIdentifier`),
    /// nil when it isn't that shape.
    static func installedBundleIDs(_ json: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let apps = result["apps"] as? [[String: Any]] else { return nil }
        return apps.compactMap { $0["bundleIdentifier"] as? String }
    }

    public enum TrustState: Sendable, Equatable { case trusted, untrusted, unknown }

    /// Whether the device trusts the app's developer, found by launching the app in the
    /// background: iOS refuses an untrusted one "for reason: Security". Any other failure (locked
    /// device, out of reach) says nothing: `unknown`.
    /// A trusted app was started only to ask: it is stopped again at once (just installed, it
    /// wasn't running before).
    public func trustState(bundleID: String, deviceID: String) async -> TrustState {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("xside-launch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let result = try? await runner.run(
            "/usr/bin/xcrun",
            ["devicectl", "device", "process", "launch", "--device", deviceID, "--no-activate",
             "--json-output", file.path, bundleID],
            cwd: nil, timeout: CommandTimeout.deviceQuery) else { return .unknown }
        if result.status == 0 {
            if let pid = (try? Data(contentsOf: file)).flatMap(Self.launchedProcessID) {
                _ = try? await runner.run(
                    "/usr/bin/xcrun",
                    ["devicectl", "device", "process", "terminate", "--device", deviceID, "--pid", String(pid)],
                    cwd: nil, timeout: CommandTimeout.deviceQuery)
            }
            return .trusted
        }
        let lower = (String(decoding: result.stdout, as: UTF8.self) + "\n" + result.stderr).lowercased()
        let untrusted = ["for reason: security", "not been explicitly trusted"]
        return untrusted.contains { lower.contains($0) } ? .untrusted : .unknown
    }

    /// `result.process.processIdentifier` of `devicectl device process launch --json-output`.
    static func launchedProcessID(_ json: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let process = result["process"] as? [String: Any] else { return nil }
        return (process["processIdentifier"] as? NSNumber)?.intValue
    }

    /// Opens Settings > General > VPN & Device Management on the device, where the developer is
    /// trusted. Restarted if already open, so it lands on that page.
    public func openTrustSettings(deviceID: String) async throws {
        let result = try await runner.run(
            "/usr/bin/xcrun",
            ["devicectl", "device", "process", "launch", "--device", deviceID, "--terminate-existing",
             "--payload-url", "prefs:root=General&path=ManagedConfigurationList", "com.apple.Preferences"],
            cwd: nil, timeout: CommandTimeout.deviceQuery)
        guard result.status == 0 else {
            let combined = String(decoding: result.stdout, as: UTF8.self) + "\n" + result.stderr
            let mapped = Self.mapError(combined)
            if case .commandFailed = mapped { throw XSideError.commandFailed(tool: "devicectl", status: result.status) }
            throw mapped
        }
    }

    /// Maps the output of a failed uninstall: nil when it says the app isn't on the device (the
    /// goal is reached), else the same errors as an install, `uninstallFailed` for a message.
    /// Like `mapError`, only error blocks are read, so an app named "Not Installed" is no cause.
    public static func mapUninstallError(_ output: String) -> XSideError? {
        if isUnreachable(output) { return .deviceUnavailable }
        let texts = errorBlocks(output).flatMap { $0.lines }.map { withoutQuotedNames($0).lowercased() }
        let gone = ["is not installed", "app not installed", "application not installed", "no such app",
                    "no app with bundle identifier", "no application with bundle identifier"]
        if texts.contains(where: { t in gone.contains { t.contains($0) } }) { return nil }
        switch mapError(output) {
        case .installFailed(let message): return .uninstallFailed(message)
        case .maxAppsReached: return .uninstallFailed(errorBlocks(output).first?.first ?? "")
        case let other: return other
        }
    }

    /// Maps combined devicectl output to an error. With no recognizable line it returns
    /// `.commandFailed(tool: "devicectl", status: -1)`; the caller substitutes the real status.
    /// Only error blocks (and known error codes anywhere) are matched, so an app or device name
    /// ("Locked Notes") or a progress line can't pass for a cause; "locked" is tried last.
    /// devicectl often prints a generic `ERROR:` line and the real cause below it, see `errorBlocks`.
    public static func mapError(_ output: String) -> XSideError {
        let lower = output.lowercased()
        if isUnreachable(output) { return .deviceUnavailable }
        if lower.contains("maximumappsreached") { return .maxAppsReached }
        let blocks = errorBlocks(output)
        let messages = blocks.map(\.first)
        let texts = blocks.flatMap { $0.lines }.map { withoutQuotedNames($0).lowercased() }
        if texts.contains(where: { t in ["maximum number of apps", "maximum number of installed apps", "3 apps", "three apps"].contains { t.contains($0) } }) {
            return .maxAppsReached
        }
        if texts.contains(where: { $0.contains("developer mode") }) { return .developerModeDisabled }
        if texts.contains(where: { $0.contains("passcode") }) { return .deviceLocked }
        if texts.contains(where: { t in ["is locked", "device locked", "locked device", "while locked"].contains { t.contains($0) } }) {
            return .deviceLocked
        }
        if let first = messages.first { return .installFailed(first) }
        return .commandFailed(tool: "devicectl", status: -1)
    }

    /// CoreDevice can't reach the device: 4016 (isolating networks), 1011 ("This device is not
    /// currently reachable", seen 2026-11-05 with an unplugged iPhone).
    static func isUnreachable(_ output: String) -> Bool {
        let lower = output.lowercased()
        return ["coredeviceerror error 4016", "coredeviceerror error 1011", "device is not currently reachable"]
            .contains { lower.contains($0) }
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
