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
        panel.nameFieldStringValue = archiveName
        panel.allowedContentTypes = [.zip]
        NSApp.activate()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            if await writeArchive(model: model, to: destination) {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } else {
                NSSound.beep()
            }
        }
    }

    /// `archiveName`, with " 2", " 3"… when that name is taken in `folder`.
    private static func uniqueArchiveName(in folder: URL) -> String {
        let base = String(archiveName.dropLast(4))
        var name = archiveName, n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base) \(n).zip"; n += 1
        }
        return name
    }

    private static var archiveName: String {
        "XSide-logs-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).zip"
    }

    /// The logs and a summary of the state, redacted, zipped at `destination`.
    @MainActor private static func writeArchive(model: AppModel, to destination: URL) async -> Bool {
        log.notice("exporting logs")
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("XSide-logs-\(UUID().uuidString)")
            .appendingPathComponent("XSide-logs", isDirectory: true)
        defer { try? fm.removeItem(at: folder.deletingLastPathComponent()) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Masked again: a value registered after a line was written (a device seen later) is
            // hidden in the export too.
            for file in LogStore.shared.files() {
                let text = try String(contentsOf: file, encoding: .utf8)
                try LogStore.shared.redact(text)
                    .write(to: folder.appendingPathComponent(file.lastPathComponent), atomically: true, encoding: .utf8)
            }
            try LogStore.shared.redact(model.diagnosticSummary(header: summary))
                .write(to: folder.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
            // The crash logs XSide read (already cleaned when read), one per installation.
            for (n, finding) in model.crashFindings.enumerated() {
                let name = "crash-\(n + 1)-" + finding.fileName.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
                try LogStore.shared.redact(finding.log)
                    .write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        } catch {
            log.error("log export failed: \(error)")
            return false
        }
        try? fm.removeItem(at: destination)
        let result = try? await ProcessRunner().run("/usr/bin/ditto",
                                                    ["-c", "-k", "--keepParent", folder.path, destination.path], cwd: nil)
        return result?.status == 0
    }

    /// "Report a problem": the logs archive goes to the Desktop (shown in the Finder, to drag into
    /// the issue), and a new GitHub issue opens filled in with the summary and the last log
    /// lines, all redacted. Nothing is sent: the person reads it and submits it.
    /// The logs archive, redacted, on the Desktop: easy to find and drag into an issue. If macOS
    /// denies it, Downloads, then the temporary folder. Never over an earlier archive. nil when
    /// none could be written. (`xside report` prints its path.)
    @MainActor static func writeReportArchive(model: AppModel) async -> URL? {
        let fm = FileManager.default
        let folders = [fm.urls(for: .desktopDirectory, in: .userDomainMask).first,
                       fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
                       fm.temporaryDirectory].compactMap { $0 }
        for folder in folders {
            let archive = folder.appendingPathComponent(uniqueArchiveName(in: folder))
            if await writeArchive(model: model, to: archive) { return archive }
        }
        return nil
    }

    @MainActor static func reportIssue(model: AppModel) {
        Task {
            let written = await writeReportArchive(model: model)
            let archived = written != nil
            let archive = written ?? FileManager.default.temporaryDirectory
            // Public: apps as <app-N>, as in the summary's "app N".
            let apps = model.records.map { r in [r.originalBundleID, r.signedBundleID] + r.installations.compactMap(\.signedBundleID) }
            let lastLines = LogStore.shared.files().first
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                .map { IssueReport.maskApps(LogStore.shared.redact(IssueReport.tail($0, lines: 40)), apps: apps) } ?? ""
            let info = Bundle.main.infoDictionary ?? [:]
            let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
            let os = ProcessInfo.processInfo.operatingSystemVersion
            var system = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            if case .success(let env)? = model.environment {
                system += ", Xcode \(env.developerDir.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)"
            }
            let devices = model.devices.filter(\.isPaired)
                .map { "\($0.model), iOS \($0.osVersion ?? "?")" }.joined(separator: " · ")
            let logs = """
                \(L("report.attach"))

                ### \(L("report.summary"))
                ```
                \(LogStore.shared.redact(model.diagnosticSummary(header: summary, publicApps: true)))
                ```

                ### \(L("report.lastLines"))
                ```
                \(lastLines)
                ```
                """
            NSWorkspace.shared.open(IssueReport.url(template: "bug_report.yml",
                                                    fields: [("version", version), ("system", system),
                                                             ("device", devices), ("logs", logs)],
                                                    cut: "logs"))
            if archived { NSWorkspace.shared.activateFileViewerSelecting([archive]) }
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
    /// `publicApps`: for the GitHub issue, apps as "app N" (no bundle id, no Xcode path): the
    /// full detail stays in the archive the person chooses to attach.
    func diagnosticSummary(header: String, publicApps: Bool = false) -> String {
        var lines = [header, "Exported \(Date().formatted(.iso8601))", ""]
        switch environment {
        case .success(let env)?:
            lines.append(publicApps ? "Environment: OK, \(env.developerDir.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)"
                                    : "Environment: OK, Xcode \(env.developerDir.path), team \(env.teamID)")
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
        for (index, record) in records.enumerated() {
            lines.append(publicApps ? "  <app-\(index + 1)>"
                                    : "  \(record.originalBundleID) as \(record.signedBundleID), team \(record.teamID)")
            for i in record.installations {
                var text = "    on \(i.deviceID): installed \(i.installedAt.formatted(.iso8601)), expires \(i.expiresAt.formatted(.iso8601))"
                if i.refreshPaused { text += ", paused" }
                if let key = i.lastErrorKey { text += ", last error \(key)" }
                if let tweaks = TweakCrashFix.summary(i, pool: record.tweaks ?? []) { text += ", \(tweaks)" }
                lines.append(text)
            }
        }
        let crashes = records.enumerated().flatMap { index, record in
            record.installations.compactMap { i -> String? in
                guard case .found(let f)? = crashChecks[JobKey(recordID: record.id, deviceID: i.deviceID)] else { return nil }
                let d = f.diagnosis
                // Public: the cause and the exception only (a subject can name the app).
                let what = publicApps ? [d.cause.rawValue, d.exceptionType, d.signal].compactMap { $0 }.joined(separator: " ")
                                      : d.summary
                let app = publicApps ? "<app-\(index + 1)>" : record.originalBundleID
                return "  \(app) on \(i.deviceID): \(what), \(d.date?.formatted(.iso8601) ?? "?")"
            }
        }
        if !crashes.isEmpty {
            lines.append("")
            lines.append("Crashes (diagnosed by XSide):")
            lines += crashes
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The crashes XSide found, for the report archive.
    var crashFindings: [CrashFinding] {
        crashChecks.values.compactMap { if case .found(let f) = $0 { f } else { nil } }
    }
}
