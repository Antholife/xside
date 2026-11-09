import AppKit
import SwiftUI
import XSideCore

enum CrashWindow {
    static let id = "crash"
}

extension OpenWindowAction {
    /// Opens the crash window in front (from the closing panel, XSide isn't active yet).
    @MainActor func presentCrash() {
        NSApp.activate(ignoringOtherApps: true)
        self(id: CrashWindow.id)
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(CrashWindow.id) == true })
            else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// "Why does it crash?": the newest crash of one installation, explained, with what to do, the
/// technical details and the cleaned report for whoever wants them.
struct CrashWindowRoot: View {
    let model: AppModel
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        Group {
            if let key = model.crashWindowKey,
               let entry = model.records.lazy.flatMap({ r in r.installations.map { AppEntry(record: r, installation: $0) } })
                .first(where: { $0.id == key }) {
                CrashView(model: model, entry: entry, check: model.crashChecks[key])
            } else {
                Text(L("crash.gone"))
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
        .id(language)
        .frame(width: 520)
        .navigationTitle(L("crash.window"))
    }
}

private struct CrashView: View {
    let model: AppModel
    let entry: AppEntry
    let check: CrashCheck?
    @State private var showRaw = false
    @State private var showAllLines = false
    /// Lines shown before "Show all": a 5 MB log would stall the window otherwise.
    private static let firstLines = 1_500
    @Environment(\.dismissWindow) private var dismissWindow

    private var appName: String { entry.record.options.displayName ?? entry.record.displayName }
    private var deviceName: String {
        model.devices.first { $0.id == entry.installation.deviceID }?.name
            ?? model.cachedNames[entry.installation.deviceID] ?? L("popover.unknownDevice")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AppIconView(icon: model.icons.image(for: entry.record), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("crash.header", appName)).font(.system(size: 16, weight: .semibold))
                    Text(L("crash.onDevice", deviceName)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Divider()
            content
            Divider()
            HStack {
                Button(L("crash.report")) { Diagnostics.reportIssue(model: model) }
                Spacer()
                Button(L("crash.again")) { Task { await model.diagnoseCrash(entry.id) } }
                    .disabled(check == .checking)
                Button(L("crash.close")) { dismissWindow(id: CrashWindow.id) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        switch check {
        case nil:
            // Never looked (or the look was for another window): no spinner that never ends.
            Text(L("crash.notLooked")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .checking?:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("crash.checking", deviceName)).foregroundStyle(.secondary)
            }
        case .none?:
            VStack(alignment: .leading, spacing: 6) {
                Text(L("crash.none", appName, deviceName)).font(.system(size: 13, weight: .medium))
                Text(L("crash.none.hint")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message)?:
            Label(L("crash.failed", message), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
                .fixedSize(horizontal: false, vertical: true)
        case .found(let finding)?:
            found(finding)
        }
    }

    private func found(_ finding: CrashFinding) -> some View {
        let d = finding.diagnosis
        let wording = CrashWording(d, app: appName)
        return VStack(alignment: .leading, spacing: 10) {
            Label(wording.title, systemImage: "exclamationmark.octagon.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemRed))
            Text(wording.explanation).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("crash.whatToDo")).font(.system(size: 12, weight: .semibold))
                Text(wording.advice).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(when(d)).font(.system(size: 11)).foregroundStyle(.secondary)
            DisclosureGroup(L("crash.technical")) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(technical(d), id: \.self) { Text($0) }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12))
            HStack {
                Button(showRaw ? L("crash.raw.hide") : L("crash.raw.show")) { showRaw.toggle() }
                if showRaw {
                    Button(L("crash.copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(finding.log, forType: .string)
                    }
                }
            }
            if showRaw {
                Text(L("crash.raw.note")).font(.system(size: 11)).foregroundStyle(.secondary)
                let lines = showAllLines ? finding.lines : Array(finding.lines.prefix(Self.firstLines))
                ScrollView([.vertical, .horizontal]) {
                    // Lazy: only the lines on screen are laid out.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { n in
                            Text(verbatim: lines[n].isEmpty ? " " : lines[n])
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                if !showAllLines, finding.lines.count > Self.firstLines {
                    Button(L("crash.raw.showAll", finding.lines.count)) { showAllLines = true }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
        }
    }

    private func when(_ d: CrashDiagnosis) -> String {
        var parts: [String] = []
        if let date = d.date { parts.append(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(appLocale))) }
        if let version = d.appVersion { parts.append(L("crash.version", version)) }
        return parts.joined(separator: " · ")
    }

    private func technical(_ d: CrashDiagnosis) -> [String] {
        var lines: [String] = []
        let exception = [d.exceptionType, d.signal].compactMap { $0 }.joined(separator: " ")
        if !exception.isEmpty { lines.append(exception) }
        if let termination = d.termination { lines.append(termination) }
        lines += d.topFrames.enumerated().map { "\($0.offset)  \($0.element)" }
        return lines
    }
}

/// After an install: "checking it starts", then, if it crashed, why in a word and a link to the window.
struct CrashNotes: View {
    let model: AppModel
    let flow: InstallFlow

    var body: some View {
        let checking = flow.runs.filter(\.checkingLaunch)
        let crashed = flow.runs.filter { $0.crash != nil }
        if !checking.isEmpty || !crashed.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(checking) { run in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(L("install.crash.checking", run.name)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                ForEach(crashed) { run in
                    if let finding = run.crash {
                        let app = flow.info?.name ?? ""
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Label(L("install.crash.found", app, run.name, CrashWording(finding.diagnosis, app: app).title),
                                  systemImage: "exclamationmark.octagon.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(nsColor: .systemRed))
                                .fixedSize(horizontal: false, vertical: true)
                            if let recordID = flow.importedRecordID {
                                Button(L("install.crash.details")) {
                                    model.explainCrash(JobKey(recordID: recordID, deviceID: run.deviceID))
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 12))
                            }
                        }
                    }
                }
            }
        }
    }
}
