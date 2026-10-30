import AppKit
import SwiftUI
import XSideCore

/// Root of the install window. Re-created on language change so every `L()` text refreshes
/// (the flow state itself lives in `AppModel`).
struct InstallWindowRoot: View {
    let model: AppModel
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let flow = model.install {
                InstallSheet(model: model, flow: flow) {
                    if !model.dismissFlow() { dismissWindow(id: InstallWindow.id) }
                }
            } else {
                Button(L("popover.install")) {
                    if let url = chooseIPA() { openWindow.presentInstall(url, model: model) }
                }
                .buttonStyle(GradientButtonStyle())
                .padding(24)
            }
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(KeepWindowOnScreen())
        .navigationTitle(L("install.title"))
        .id(language)
        .onAppear(perform: model.installWindowAppeared)
        .onDisappear(perform: model.installWindowDisappeared)
    }
}

/// App summary, target devices, folded options, Install button and per-step progress (one row
/// per device when installing on several).
struct InstallSheet: View {
    let model: AppModel
    let flow: InstallFlow
    let close: () -> Void
    /// Natural height of the scrolling middle.
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            // Only the middle scrolls: the app header and the buttons stay in view, and the window
            // never grows past the screen (the options can be long once unfolded).
            // The middle gets its measured height, capped: a ScrollView alone has no ideal height,
            // so the window would stay at its old size and clip everything when the options unfold.
            ScrollView(.vertical) {
                content
                    .padding(.horizontal, 20)
                    .padding(.vertical, 2)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, Self.maxContentHeight))
            .padding(.horizontal, -20)
            if !model.queuedIPAs.isEmpty { QueueLine(files: model.queuedIPAs) }
            buttons
        }
        .padding(20)
        .animation(.smooth(duration: 0.25), value: flow.phase)
    }

    /// Room left for the scrolling middle on the current screen, minus header, buttons and chrome.
    private static var maxContentHeight: CGFloat {
        max(240, (NSScreen.main?.visibleFrame.height ?? 800) - 240)
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch flow.phase {
            case .inspecting:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            case .rejected(let message):
                ErrorText(message)
                ExportLogsLink(model: model)
            case .editing, .running:
                // The run's status comes first, right under the app header.
                if case .running(let stage) = flow.phase {
                    if !flow.isMultiDevice { InstallProgressView(timeline: StepTimeline(steps: steps, stage: stage)) }
                } else if let failure = flow.failure, case .editing = flow.phase {
                    InstallProgressView(timeline: StepTimeline(steps: steps, stage: failure.stage, failed: true),
                                        failureMessage: failure.message)
                    ExportLogsLink(model: model)
                } else if case .editing(let error?) = flow.phase {
                    ErrorText(error)
                } else if case .editing(nil) = flow.phase, flow.wasCancelled {
                    CancelledNote()
                }
                if flow.isRunning && flow.isMultiDevice {
                    DeviceRunList(model: model, flow: flow, steps: steps)
                } else {
                    DevicePicker(model: model, flow: flow)
                }
                InstallOptionsSection(model: model, flow: flow)
                if case .editing = flow.phase { BlockedNotice(model: model, flow: flow) }
            case .finished:
                if flow.isMultiDevice {
                    DeviceRunList(model: model, flow: flow, steps: steps)
                    summary
                    if !flow.failedDeviceIDs.isEmpty { ExportLogsLink(model: model) }
                } else {
                    InstallProgressView(timeline: StepTimeline(
                        steps: steps, current: flow.wifiCheck != nil ? .wifiCheck : nil, skipped: skippedSteps))
                    Label(L("install.success", flow.runs.first?.name ?? ""), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                }
                // Wi-Fi checks one device at a time, then every first-install guide.
                if let check = flow.wifiCheck {
                    WifiCheckView(model: model, flow: flow, check: check,
                                  deviceName: flow.isMultiDevice ? name(of: flow.wifiDeviceID) : nil)
                        .id(flow.wifiDeviceID)
                } else if !flow.isMultiDevice, flow.runs.first?.wifiVerified == true {
                    Label(L("wifi.ok"), systemImage: "wifi")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                }
                if !flow.retryableDeviceIDs.isEmpty, flow.wifiCheck == nil { BlockedNotice(model: model, flow: flow) }
                if flow.wifiCheck == nil {
                    ForEach(flow.guides, id: \.deviceID) { guide in
                        FirstInstallGuideView(guide: guide,
                                              deviceName: flow.isMultiDevice ? name(of: guide.deviceID) : nil)
                            .onAppear { model.guideDisplayed(guide) }
                    }
                }
            }
        }
    }

    /// Steps of the run, fixed up front: Wi-Fi verification is planned or not, never added later.
    private var steps: [ProgressStep] { ProgressStep.list(includingWifiCheck: flow.wifiStepPlanned) }

    /// The Wi-Fi check ended without success (skipped, USB chosen or window closed).
    private var skippedSteps: Set<ProgressStep> {
        guard flow.wifiStepPlanned, case .finished = flow.phase,
              flow.wifiCheck == nil, flow.runs.first?.wifiVerified != true else { return [] }
        return [.wifiCheck]
    }

    private func name(of deviceID: String?) -> String? {
        flow.runs.first { $0.deviceID == deviceID }?.name
    }

    /// Outcome of a run on several devices.
    @ViewBuilder private var summary: some View {
        let done = flow.succeededCount
        if done == flow.runs.count {
            Label(L("install.successMany", done), systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemGreen))
        } else if done > 0 {
            Label(L("install.successSome", done, flow.runs.count), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemOrange))
        } else if !flow.failedDeviceIDs.isEmpty {
            ErrorText(L("install.failedAll")) // with the cancelled note below if some were cancelled
        }
        if flow.wasCancelled { CancelledNote() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // A custom icon chosen in the options wins over the app's own.
            AppGlyph(iconURL: flow.draft.iconPath.map(model.iconURL) ?? flow.appIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(flow.info?.name ?? flow.ipa.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        guard let info = flow.info else { return flow.ipa.lastPathComponent }
        return [info.version, info.bundleID].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            Spacer()
            switch flow.phase {
            case .finished where !flow.retryableDeviceIDs.isEmpty:
                Button(L("install.done"), action: close)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    .disabled(flow.wifiCheck != nil)
                // Only cancelled devices: nothing failed, plain "Retry".
                Button(L(flow.failedDeviceIDs.isEmpty ? "install.retry" : "install.retryFailed"),
                       action: model.retryFailedInstalls)
                    .buttonStyle(GradientButtonStyle())
                    .frame(width: 170)
                    // During the Wi-Fi check, Return is its "Retry".
                    .keyboardShortcut(flow.wifiCheck == nil ? .defaultAction : nil)
                    .disabled(flow.wifiCheck != nil || !model.isPipelineReady)
            case .finished:
                Button(L("install.done"), action: close)
                    .keyboardShortcut(flow.wifiCheck == nil ? .defaultAction : nil)
                    .controlSize(.large)
                    .disabled(flow.wifiCheck != nil)
            case .inspecting, .rejected:
                Button(L("install.cancel"), action: close)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            case .editing, .running:
                if flow.isRunning {
                    // Immediate, even mid-transfer: no confirmation, so no Escape shortcut either.
                    Button(L("install.cancelRun"), action: model.cancelInstall)
                        .controlSize(.large)
                        .disabled(flow.cancelRequested)
                } else {
                    Button(L("install.cancel"), action: close)
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                }
                Button(installLabel, action: model.startInstall)
                    .buttonStyle(GradientButtonStyle())
                    .frame(width: flow.deviceIDs.count > 1 ? 200 : 130)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canInstall)
            }
        }
    }

    private var installLabel: String {
        flow.deviceIDs.count > 1 ? L("install.onDevices", flow.deviceIDs.count) : L("install.title")
    }

    private var canInstall: Bool {
        guard !flow.isRunning, case .success? = model.environment else { return false }
        return model.devices.contains { flow.deviceIDs.contains($0.id) && $0.isAvailable }
    }
}

/// Why "Install" (or "Retry failed") can't be pressed: the first check still running, the
/// environment failing (with its fix), or the chosen devices gone.
private struct BlockedNotice: View {
    let model: AppModel
    let flow: InstallFlow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if flow.isRunning {
            EmptyView()
        } else if model.environment == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("install.blocked.checking")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if let error = model.environmentError {
            VStack(alignment: .leading, spacing: 8) {
                ErrorText(error.localizedMessage)
                Group {
                    // A failed check has nothing to fix: checking again is the action.
                    if error.isSetupCheckFailure {
                        Button(L("onboarding.recheck"), action: model.recheckEnvironment)
                            .disabled(model.isProbing)
                    } else {
                        Button(L("environment.banner.fix")) {
                            NSApp.activate()
                            openSettings()
                        }
                    }
                }
                .controlSize(.small)
                .padding(.leading, 22)
            }
        } else if case .editing = flow.phase, !flow.deviceIDs.isEmpty,
                  !model.devices.contains(where: { flow.deviceIDs.contains($0.id) && $0.isAvailable }) {
            Label(L("install.noAvailableDevice"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Next: Foo.ipa, Bar.ipa" — files requested while this install runs.
private struct QueueLine: View {
    let files: [URL]

    var body: some View {
        Label(L("install.queued", files.map(\.lastPathComponent).joined(separator: ", ")),
              systemImage: "clock")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
    }
}

/// The paired devices, several can be checked; only reachable ones. "＋ New device" (or no
/// reachable device at all) shows the first-pairing helper, which watches the list and checks the
/// new device.
private struct DevicePicker: View {
    let model: AppModel
    let flow: InstallFlow
    @State private var helperRequested = false
    @State private var knownIDs: Set<String>?
    @State private var detectedName: String?

    private var devices: [Device] { model.pairedDevices }
    private var showHelper: Bool { helperRequested || !devices.contains(where: \.isAvailable) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(devices.count > 1 ? L("install.devices") : L("install.device"))
            VStack(spacing: 0) {
                ForEach(devices) { device in
                    DeviceChoice(device: device, isSelected: flow.deviceIDs.contains(device.id)) {
                        flow.toggle(device.id)
                    }
                    .disabled(!device.isAvailable || flow.isRunning)
                    // Per device, the same setting as in the popover: refresh this one over Wi-Fi.
                    if flow.deviceIDs.contains(device.id) {
                        Toggle(L("popover.device.wifiRefresh"), isOn: Binding(
                            get: { model.devicePrefs.wifiRefresh(for: device.id) },
                            set: { model.setWifiRefresh($0, for: device.id) }))
                            .toggleStyle(.checkbox)
                            .tint(Theme.violet)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 38)
                            .padding(.bottom, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(flow.isRunning)
                    }
                    Divider().padding(.leading, 38)
                }
                NewDeviceRow(isOpen: showHelper) { helperRequested.toggle() }
                    .disabled(flow.isRunning)
            }
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let detectedName {
                Label(L("install.newDevice.detected", detectedName), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemGreen))
            }
            if showHelper && !flow.isRunning { NewDeviceHelp() }
        }
        .onAppear { if knownIDs == nil { knownIDs = availableIDs } }
        .onChange(of: model.devices) { _, _ in checkForNewDevice() }
        // Visibility-gated: refreshes only while the helper is on screen (the task ends with the view).
        .task(id: showHelper && !flow.isRunning) {
            guard showHelper, !flow.isRunning else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await model.listDevices()
            }
        }
    }

    private var availableIDs: Set<String> { Set(devices.filter(\.isAvailable).map(\.id)) }

    private func checkForNewDevice() {
        let known = knownIDs ?? []
        defer { knownIDs = availableIDs }
        guard showHelper, !flow.isRunning,
              let device = devices.first(where: { $0.isAvailable && !known.contains($0.id) }) else { return }
        // The new device replaces the default choice, or joins the user's own.
        if !flow.selectionEdited { flow.deviceIDs = [] }
        if !flow.deviceIDs.contains(device.id) { flow.deviceIDs.append(device.id) }
        flow.selectionEdited = true
        helperRequested = false
        detectedName = device.name
        Task {
            try? await Task.sleep(for: .seconds(4))
            if detectedName == device.name { detectedName = nil }
        }
    }
}

private struct NewDeviceRow: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .frame(width: 18)
                    .foregroundStyle(Theme.violet)
                Text(L("install.newDevice")).font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DeviceChoice: View {
    let device: Device
    let isSelected: Bool
    let select: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: device.symbolName)
                    .font(.system(size: 16))
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.system(size: 13, weight: .medium))
                    HStack(spacing: 5) {
                        StatusDot(isOn: device.isAvailable)
                            .scaleEffect(0.75)
                        Text(device.transportLabel)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.violet) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The devices of a run on several devices, one row each with its status. The device being
/// installed shows its step timeline under its row.
private struct DeviceRunList: View {
    let model: AppModel
    let flow: InstallFlow
    let steps: [ProgressStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L("install.devices"))
            VStack(spacing: 0) {
                ForEach(flow.runs) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        DeviceRunRow(run: run, symbolName: symbolName(run.deviceID),
                                     checkingWifi: flow.wifiCheck != nil && flow.wifiDeviceID == run.deviceID)
                        if case .running(let stage) = run.status {
                            InstallProgressView(timeline: StepTimeline(steps: steps, stage: stage))
                                .padding(.leading, 28)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    if run.id != flow.runs.last?.id { Divider().padding(.leading, 38) }
                }
            }
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func symbolName(_ deviceID: String) -> String {
        model.devices.first { $0.id == deviceID }?.symbolName ?? "iphone"
    }
}

private struct DeviceRunRow: View {
    let run: DeviceRun
    let symbolName: String
    let checkingWifi: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 16))
                .frame(width: 18)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.name).font(.system(size: 13, weight: .medium))
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(run.isFailed ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            indicator
                .frame(width: 16, height: 16)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch run.status {
        case .waiting: L("install.step.waiting") + "…"
        case .running(let stage): stage.rowText
        case .succeeded where checkingWifi: L("wifi.title") + "…"
        case .succeeded: run.wifiVerified ? L("install.run.doneWifi") : L("install.run.done")
        case .failed(let failure): failure.message
        case .cancelled: L("install.run.cancelled")
        }
    }

    @ViewBuilder private var indicator: some View {
        switch run.status {
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Color(nsColor: .systemRed))
        case .cancelled:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }
}

/// "Install cancelled.": the last run was stopped by the user (not an error).
private struct CancelledNote: View {
    var body: some View {
        Label(L("install.cancelled"), systemImage: "xmark.circle")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

/// The app's icon: the custom one chosen, else the IPA's own, else a placeholder.
struct AppGlyph: View {
    let iconURL: URL?
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let iconURL, let image = NSImage(contentsOf: iconURL) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.brand
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: size * 0.46, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}

/// Under a failure: the logs, zipped and redacted, ready to attach to a GitHub issue.
struct ExportLogsLink: View {
    let model: AppModel

    var body: some View {
        Button {
            Diagnostics.export(model: model)
        } label: {
            Label(L("logs.exportLink"), systemImage: "doc.text.magnifyingglass")
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
    }
}

struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.octagon.fill")
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: .systemRed))
    }
}
