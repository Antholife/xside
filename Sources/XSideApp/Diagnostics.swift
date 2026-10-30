import AppKit
import UniformTypeIdentifiers
import XSideCore

/// The log files (`~/Library/Logs/XSide`) and their export for a bug report.
enum Diagnostics {
    private static let log = Log("app")

    /// `XSide-debug` for the debug bundle, so both apps keep their own logs.
    static var directory: URL {
        let name = Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true ? "XSide-debug" : "XSide"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Called first thing at launch: everything after it is logged to the file.
    static func start() {
        LogStore.shared.configure(directory: directory)
        log.notice("— launch — \(summary)")
    }

    /// "XSide 1.0.1 (57, a4c510b) · macOS 27.2 (26B123) · arm64 · fr".
    static var summary: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = Bundle.main.shortVersion ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["XSideGitCommit"] as? String ?? "?"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "XSide \(version) (\(build), \(commit)) · macOS \(XcodeLauncher.macVersion) (\(XcodeLauncher.macBuild)) · \(arch) · \(appLocale.identifier)"
    }

    /// Asks where to save, then zips the log files with a short summary. Already redacted: ready to
    /// attach to a GitHub issue.
    @MainActor static func export(model: AppModel) {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        panel.nameFieldStringValue = "XSide-logs-\(stamp).zip"
        panel.allowedContentTypes = [.zip]
        NSApp.activate()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        log.notice("exporting logs")

        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("XSide-logs-\(UUID().uuidString)")
            .appendingPathComponent("XSide-logs", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in LogStore.shared.files() {
                try fm.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
            }
            try LogStore.shared.redact(model.diagnosticSummary(header: summary))
                .write(to: folder.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        } catch {
            log.error("log export failed: \(error)")
            NSSound.beep()
            return
        }
        Task {
            defer { try? fm.removeItem(at: folder.deletingLastPathComponent()) }
            try? fm.removeItem(at: destination)
            let result = try? await ProcessRunner().run("/usr/bin/ditto",
                                                        ["-c", "-k", "--keepParent", folder.path, destination.path], cwd: nil)
            if result?.status == 0 {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } else {
                NSSound.beep()
            }
        }
    }
}

extension Device {
    /// One line for the log: id and name are redacted when written.
    var logLine: String {
        let os = osVersion.map { "iOS \($0)" } ?? "iOS ?"
        let mode = developerModeEnabled.map { $0 ? "dev mode on" : "dev mode off" } ?? "dev mode ?"
        return "\(id) \(name) (\(model), \(os), \(transport.rawValue), \(isPaired ? "paired" : "not paired"), \(isAvailable ? "available" : "unavailable"), \(mode))"
    }
}

extension AppModel {
    /// The state worth knowing for a bug report, redacted by the caller.
    func diagnosticSummary(header: String) -> String {
        var lines = [header, "Exported \(Date().formatted(.iso8601))", ""]
        switch environment {
        case .success(let env)?:
            lines.append("Environment: OK, Xcode \(env.developerDir.path), team \(env.teamID)")
        case .failure(let error)?:
            lines.append("Environment: \(error.key)")
        case nil:
            lines.append("Environment: not checked yet")
        }
        lines.append("App IDs left (estimate): \(appIDsRemaining.map(String.init) ?? "?")")
        lines.append("")
        lines.append("Devices (\(devices.count)):")
        lines += devices.map { "  \($0.logLine)" }
        lines.append("")
        lines.append("Apps (\(records.count)):")
        for record in records {
            lines.append("  \(record.originalBundleID) as \(record.signedBundleID), team \(record.teamID)")
            for i in record.installations {
                var text = "    on \(i.deviceID): installed \(i.installedAt.formatted(.iso8601)), expires \(i.expiresAt.formatted(.iso8601))"
                if i.refreshPaused { text += ", paused" }
                if let key = i.lastErrorKey { text += ", last error \(key)" }
                lines.append(text)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
