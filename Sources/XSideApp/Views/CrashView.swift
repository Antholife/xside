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
    /// The suggested fix was asked for here: whether its refresh started.
    @State private var actionStarted: Bool?
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
                Button(L("fixes.request.button")) { model.requestFix(for: entry, finding: check?.finding) }
                    .help(L("fixes.request.crashHelp"))
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
            if let action = CrashAction.suggested(for: d) {
                HStack(spacing: 8) {
                    Button(L("crash.action.\(action.rawValue)")) {
                        guard let all = model.crashActionScope(action, on: entry.id, diagnosis: d) else { return }
                        Task { actionStarted = await model.perform(action, on: entry.id, allDevices: all, diagnosis: d) }
                    }
                    .disabled(model.jobs[entry.id] != nil || actionStarted == true)
                    if model.jobs[entry.id] != nil || actionStarted == true {
                        Text(L("crash.action.started")).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if actionStarted == false {
                        Text(L("crash.action.failed")).font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemOrange))
                    }
                }
            }
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

/// After an install: "checking it starts", then, if it crashed, a banner per device with the
/// cause, "See why" and the fix it suggests.
struct CrashNotes: View {
    let model: AppModel
    let flow: InstallFlow
    /// The suggested fix was asked for, by device: whether its refresh started.
    @State private var actionStarted: [String: Bool] = [:]

    var body: some View {
        let checking = flow.runs.filter(\.checkingLaunch)
        let crashed = flow.runs.filter { $0.crash != nil }
        if !checking.isEmpty || !crashed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(checking) { run in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(L("install.crash.checking", run.name)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                ForEach(crashed) { run in
                    if let finding = run.crash {
                        let key = flow.importedRecordID.map { JobKey(recordID: $0, deviceID: run.deviceID) }
                        CrashBanner(app: flow.info?.name ?? "", device: run.name, diagnosis: finding.diagnosis,
                                    isFixing: key.map { model.jobs[$0] != nil } ?? false,
                                    actionStarted: actionStarted[run.deviceID],
                                    onWhy: key.map { key in { model.explainCrash(key) } },
                                    onAction: key.map { key in
                                        { action in
                                            let d = finding.diagnosis
                                            guard let all = model.crashActionScope(action, on: key, diagnosis: d) else { return }
                                            Task {
                                                actionStarted[run.deviceID] = await model.perform(action, on: key, allDevices: all,
                                                                                                  diagnosis: d)
                                            }
                                        }
                                    })
                    }
                }
            }
        }
    }
}

/// The app stopped at launch, said loud: on a red card, which app on which device, the cause in
/// plain words, "See why" (the crash window) and the suggested fix as a button when XSide can do
/// it (install without XSide's features, without the Duo compatibility, sign again).
struct CrashBanner: View {
    let app: String
    let device: String
    let diagnosis: CrashDiagnosis
    /// The fix's refresh is running on that installation.
    var isFixing = false
    /// The fix was asked for: whether its refresh started (nil: not asked).
    var actionStarted: Bool?
    let onWhy: (() -> Void)?
    let onAction: ((CrashAction) -> Void)?

    private var red: Color { Color(nsColor: .systemRed) }

    var body: some View {
        let wording = CrashWording(diagnosis, app: app)
        let action = CrashAction.suggested(for: diagnosis)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(red)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("crash.banner.title", app, device))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(red)
                    .fixedSize(horizontal: false, vertical: true)
                Text(wording.title)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(wording.advice)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let onWhy {
                        Button(L("crash.seeWhy"), action: onWhy)
                            .buttonStyle(CrashFilledButtonStyle(tint: red, size: 13))
                    }
                    if let action, let onAction {
                        Button(L("crash.action.\(action.rawValue)")) { onAction(action) }
                            .buttonStyle(.bordered)
                            .disabled(isFixing || actionStarted == true)
                    }
                }
                .controlSize(.regular)
                .padding(.top, 2)
                if isFixing || actionStarted == true {
                    Text(L("crash.action.started"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if actionStarted == false {
                    Text(L("crash.action.failed"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(red.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// A filled button in the crash's color, white text: as loud whether or not its window is key
/// (a prominent system button greys out in the menu-bar panel's inactive window).
struct CrashFilledButtonStyle: ButtonStyle {
    let tint: Color
    var size: CGFloat = 11
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, size * 0.85)
            .padding(.vertical, size * 0.3)
            .background(tint.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
    }
}

extension AppModel {
    /// Before a crash's fix: where "Reinstall without XSide features" applies when the app is on
    /// several devices, and « Désactiver ce tweak » / « Désactiver les tweaks convertis » when
    /// more than one installation has the tweak (this device, the default, or all of them).
    /// False: this device only; true: all; nil: cancelled. Other fixes are per device already:
    /// false without asking.
    func crashActionScope(_ action: CrashAction, on key: JobKey, diagnosis: CrashDiagnosis? = nil) -> Bool? {
        guard let record = records.first(where: { $0.id == key.recordID }),
              let crashed = record.installations.first(where: { $0.deviceID == key.deviceID }) else { return false }
        let device = devices.first { $0.id == key.deviceID }?.name ?? cachedNames[key.deviceID] ?? L("popover.unknownDevice")
        let alert = NSAlert()
        switch action {
        case .reinstallWithoutXSide:
            guard record.installations.count > 1 else { return false }
            alert.messageText = L("crash.scope.title", record.displayName)
            alert.informativeText = L("crash.scope.message", device, record.installations.count)
        case .disableTweak, .disableConvertedTweaks:
            let count = TweakCrashFix.affected(action, subject: diagnosis?.subject, crashed: crashed, record: record).count
            guard count > 1 else { return false }
            let tweak = diagnosis?.tweakName ?? diagnosis?.subject ?? "?"
            alert.messageText = action == .disableTweak ? L("crash.scope.disableTweak.title", tweak)
                                                        : L("crash.scope.disableConvertedTweaks.title", record.displayName)
            alert.informativeText = L("crash.scope.tweaks.message", device, count)
        default:
            return false
        }
        alert.addButton(withTitle: L("crash.scope.thisDevice", device))
        alert.addButton(withTitle: L("crash.scope.allDevices"))
        alert.addButton(withTitle: L("install.cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return false
        case .alertSecondButtonReturn: return true
        default: return nil
        }
    }
}
