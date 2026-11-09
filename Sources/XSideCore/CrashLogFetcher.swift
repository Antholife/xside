import Foundation

/// One file of the device's crash logs, as `devicectl device info files` lists it.
public struct CrashLogEntry: Equatable, Sendable {
    public let relativePath: String
    public let size: Int?
    public let modified: Date?

    private static let fileName = try! NSRegularExpression(pattern: #"^(.+)-\d{4}-\d{2}-\d{2}-\d{6}(\.\d+)?\.ips$"#)

    /// The process part of the file name: "Kenya-master" for "Kenya-master-2026-11-08-231250.ips".
    var processPart: String? {
        let name = (relativePath as NSString).lastPathComponent
        guard name.hasSuffix(".ips") else { return nil }
        let regex = Self.fileName
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: range), let part = Range(match.range(at: 1), in: name) else { return nil }
        return String(name[part])
    }
}

/// Picks, from the device's list of crash logs, the few worth copying for an app: by name, date
/// and size, so a device holding hundreds of logs costs a handful of small copies.
public enum CrashLogListing {
    public static let maxCrashFiles = 6
    public static let maxJetsamFiles = 3
    /// Some slack: the file's date is when it was written, a moment after the crash.
    static let slack: TimeInterval = 60

    /// The files (not folders) of `devicectl device info files --json-output`; nil when it isn't that.
    public static func parse(_ json: Data) -> [CrashLogEntry]? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let files = result["files"] as? [Any] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return files.compactMap { item in
            guard let f = item as? [String: Any], let path = f["relativePath"] as? String, !path.isEmpty else { return nil }
            if (f["resources"] as? [String: Any])?["isDirectory"] as? Bool == true { return nil }
            let metadata = f["metadata"] as? [String: Any] ?? [:]
            let dateText = metadata["lastModDate"] as? String
            return CrashLogEntry(relativePath: path, size: (metadata["size"] as? NSNumber).map { $0.intValue },
                                 modified: dateText.flatMap { iso.date(from: $0) ?? plain.date(from: $0) })
        }
    }

    /// Names ReportCrash gives files that are never an app's crash, for when the app's process
    /// name isn't known.
    private static let systemPrefixes = ["JetsamEvent", "ExcUserFault_", "ExcResource_", "DiagnosticRequest_", "SFA-",
                                         "xp_amp", "SiriSearchFeedback", "AccessoryCrash", "proactive_event_tracker",
                                         "stacks", "WiFi", "Bluetooth", "panic", "LowBatteryLog", "ResetCounter"]

    /// Newest first: the app's crash logs and the JetsamEvents written since `since`. `executable`
    /// nil (an app imported before XSide kept it): any file that may be an app's crash, and no
    /// JetsamEvent (which names processes only). The Watch's logs (`ProxiedDevice-…`) are left out.
    public static func candidates(_ entries: [CrashLogEntry], executable: String?, since: Date)
        -> (crashes: [CrashLogEntry], jetsam: [CrashLogEntry]) {
        let recent = entries.filter { entry in
            !entry.relativePath.hasPrefix("ProxiedDevice-")
                && (entry.size ?? 0) <= CrashLogParser.maxBytes
                && (entry.modified.map { $0 >= since.addingTimeInterval(-slack) } ?? true)
        }
        func newestFirst(_ list: [CrashLogEntry]) -> [CrashLogEntry] {
            list.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
        let crashes = recent.filter { entry in
            guard let part = entry.processPart, part != "JetsamEvent" else { return false }
            if let executable { return normalized(part) == normalized(executable) }
            return !part.contains(".") && !systemPrefixes.contains { part.hasPrefix($0) }
        }
        let jetsam = executable == nil ? [] : recent.filter { $0.processPart == "JetsamEvent" }
        return (Array(newestFirst(crashes).prefix(maxCrashFiles)), Array(newestFirst(jetsam).prefix(maxJetsamFiles)))
    }

    /// ReportCrash keeps ASCII letters, digits and a few signs of the process name in the file's.
    static func normalized(_ name: String) -> String {
        String(name.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
            .map(Character.init)).lowercased()
    }
}

/// Reads an app's crash logs from a device with `devicectl`: lists them, copies only the few that
/// may be the app's into a temporary folder, parses them there, and deletes the folder before
/// returning (each file right after it's read). Nothing leaves the Mac.
public struct CrashLogFetcher: Sendable {
    private let runner: CommandRunning
    private let scratchRoot: URL
    private static let log = Log("crash")

    public init(runner: CommandRunning, scratchRoot: URL = FileManager.default.temporaryDirectory) {
        self.runner = runner
        self.scratchRoot = scratchRoot
    }

    /// The newest crash of `target` since `since`, and the file's text (not sanitized yet).
    public struct Found: Sendable, Equatable {
        public let log: CrashLog
        public let text: String
        public let fileName: String
    }

    /// The newest log (crash or JetsamEvent) about `target` dated `since` or later; nil when there's
    /// none. Throws when the device's list can't be read (out of reach, locked…).
    public func latest(_ target: CrashTarget, deviceID: String, since: Date) async throws -> Found? {
        let fm = FileManager.default
        let folder = scratchRoot.appendingPathComponent("xside-crash-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let listFile = folder.appendingPathComponent("list.json")
        let result = try await runner.run("/usr/bin/xcrun",
                                          ["devicectl", "device", "info", "files", "--device", deviceID,
                                           "--domain-type", "systemCrashLogs", "--json-output", listFile.path],
                                          cwd: nil, timeout: CommandTimeout.deviceQuery)
        guard result.status == 0 else {
            let mapped = Installer.mapError(String(decoding: result.stdout, as: UTF8.self) + "\n" + result.stderr)
            if case .commandFailed = mapped { throw XSideError.commandFailed(tool: "devicectl", status: result.status) }
            throw mapped
        }
        guard let data = try? Data(contentsOf: listFile), let entries = CrashLogListing.parse(data) else {
            throw XSideError.commandFailed(tool: "devicectl", status: result.status)
        }
        try? fm.removeItem(at: listFile)
        let picked = CrashLogListing.candidates(entries, executable: target.executable, since: since)
        Self.log.info("crash logs: \(entries.count) on the device, \(picked.crashes.count) + \(picked.jetsam.count) to read")

        var best: Found?
        for list in [picked.crashes, picked.jetsam] {
            for (n, entry) in list.enumerated() {
                try Task.checkCancellation()
                guard var found = await read(entry, deviceID: deviceID, into: folder.appendingPathComponent("\(n).ips")),
                      found.log.matches(target, since: since) else { continue }
                if found.log.kind == .jetsam, let executable = target.executable {
                    found = Self.jetsamOnly(found, executable: executable)
                }
                if best == nil || (found.log.date ?? .distantPast) > (best?.log.date ?? .distantPast) { best = found }
                break // newest first: the first match of each kind is its newest
            }
        }
        return best
    }

    /// Copies one file, reads it (size-capped) and deletes it.
    private func read(_ entry: CrashLogEntry, deviceID: String, into file: URL) async -> Found? {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let result = try? await runner.run("/usr/bin/xcrun",
                                                 ["devicectl", "device", "copy", "from", "--device", deviceID,
                                                  "--domain-type", "systemCrashLogs", "--source", entry.relativePath,
                                                  "--destination", file.path],
                                                 cwd: nil, timeout: CommandTimeout.deviceQuery),
              result.status == 0,
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= CrashLogParser.maxBytes,
              let data = try? Data(contentsOf: file), let log = CrashLogParser.parse(data) else { return nil }
        return Found(log: log, text: String(decoding: data, as: UTF8.self),
                     fileName: (entry.relativePath as NSString).lastPathComponent)
    }

    /// A JetsamEvent cut down to `executable`'s entries (it lists every process of the device:
    /// which apps the person uses is none of the report's business).
    static func jetsamOnly(_ found: Found, executable: String) -> Found {
        var log = found.log
        log.jetsamKills = log.jetsamKills.filter { $0.name == executable }
        let data = Data(found.text.utf8)
        let newline = data.firstIndex(of: 0x0A) ?? data.endIndex
        let header = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
        var text = header + "\n"
        if newline < data.endIndex,
           let body = try? JSONSerialization.jsonObject(with: Data(data[data.index(after: newline)...])) as? [String: Any] {
            var kept: [String: Any] = [:]
            for key in ["build", "product", "date", "bug_type"] { kept[key] = body[key] }
            let processes = body["processes"] as? [Any] ?? []
            let others = Set(processes.compactMap { ($0 as? [String: Any])?["name"] as? String }).subtracting([executable])
            // Another process's name is nobody's business: largestProcess only when it's the app.
            if body["largestProcess"] as? String == executable { kept["largestProcess"] = executable }
            if let memory = body["memoryStatus"] { kept["memoryStatus"] = withoutProcessNames(memory, others: others, executable: executable) }
            kept["processes"] = processes.filter { ($0 as? [String: Any])?["name"] as? String == executable }
            if let json = try? JSONSerialization.data(withJSONObject: kept, options: [.prettyPrinted, .sortedKeys]) {
                text += String(decoding: json, as: UTF8.self)
            }
        }
        return Found(log: log, text: text, fileName: found.fileName)
    }

    /// `value` (memoryStatus) without any process name but the app's: a string under a key that
    /// names a process, or equal to another listed process's name, is dropped.
    static func withoutProcessNames(_ value: Any, others: Set<String>, executable: String, key: String? = nil) -> Any? {
        switch value {
        case let dictionary as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dictionary {
                if let kept = withoutProcessNames(v, others: others, executable: executable, key: k) { out[k] = kept }
            }
            return out
        case let list as [Any]:
            return list.compactMap { withoutProcessNames($0, others: others, executable: executable, key: key) }
        case let text as String:
            if text == executable { return text }
            if others.contains(text) || key?.lowercased().contains("proc") == true { return nil }
            return text
        default:
            return value
        }
    }

    /// Whether the app (its main executable, not one of its extensions) runs on the device; nil
    /// when that can't be told.
    public func isRunning(executable: String, deviceID: String) async -> Bool? {
        let fm = FileManager.default
        let file = scratchRoot.appendingPathComponent("xside-processes-\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: file) }
        guard let result = try? await runner.run("/usr/bin/xcrun",
                                                 ["devicectl", "device", "info", "processes", "--device", deviceID,
                                                  "--json-output", file.path],
                                                 cwd: nil, timeout: CommandTimeout.deviceQuery),
              result.status == 0, let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let processes = (root["result"] as? [String: Any])?["runningProcesses"] as? [Any] else { return nil }
        return processes.contains { item in
            guard let text = (item as? [String: Any])?["executable"] as? String,
                  let url = URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "") else { return false }
            let path = url.path
            return path.contains("/Bundle/Application/") && url.lastPathComponent == executable
                && url.deletingLastPathComponent().pathExtension == "app"
        }
    }
}
