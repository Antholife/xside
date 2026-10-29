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
        .navigationTitle(L("install.title"))
        .id(language)
        .onAppear(perform: model.installWindowAppeared)
        .onDisappear(perform: model.installWindowDisappeared)
    }
}

/// App summary, target device, folded options, Install button and per-step progress.
struct InstallSheet: View {
    let model: AppModel
    let flow: InstallFlow
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch flow.phase {
            case .inspecting:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            case .rejected(let message):
                ErrorText(message)
            case .editing, .running:
                DevicePicker(model: model, flow: flow)
                InstallOptionsSection(model: model, flow: flow)
                if case .running(let stage) = flow.phase {
                    InstallProgressView(timeline: StepTimeline(steps: steps, stage: stage))
                } else if let failure = flow.failure, case .editing = flow.phase {
                    InstallProgressView(timeline: StepTimeline(steps: steps, stage: failure.stage, failed: true),
                                        failureMessage: failure.message)
                } else if case .editing(let error?) = flow.phase {
                    ErrorText(error)
                }
                if case .failure(let error)? = model.environment { ErrorText(error.localizedMessage) }
            case .succeeded(let deviceName, let guide):
                InstallProgressView(timeline: StepTimeline(
                    steps: steps, current: flow.wifiCheck != nil ? .wifiCheck : nil))
                Label(L("install.success", deviceName), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemGreen))
                if let check = flow.wifiCheck {
                    WifiCheckView(model: model, flow: flow, check: check)
                } else if flow.wifiVerified {
                    Label(L("wifi.ok"), systemImage: "wifi")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                }
                if let guide, flow.wifiCheck == nil {
                    FirstInstallGuideView(guide: guide)
                        .onAppear { model.guideDisplayed(guide) }
                }
            }
            if !model.queuedIPAs.isEmpty { QueueLine(files: model.queuedIPAs) }
            buttons
        }
        .padding(20)
        .animation(.smooth(duration: 0.25), value: flow.phase)
    }

    /// Steps of the run: Wi-Fi verification only when the run ends with it and it wasn't skipped.
    private var steps: [ProgressStep] {
        var includesWifi = flow.wifiStepPlanned
        if case .succeeded = flow.phase { includesWifi = includesWifi && (flow.wifiCheck != nil || flow.wifiVerified) }
        return ProgressStep.list(includingWifiCheck: includesWifi)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppGlyph(iconURL: flow.draft.iconPath.map(model.iconURL))
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
            case .succeeded:
                Button(L("install.done"), action: close)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(flow.wifiCheck != nil)
            case .inspecting, .rejected:
                Button(L("install.cancel"), action: close)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            case .editing, .running:
                Button(L("install.cancel"), action: close)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    .disabled(flow.isRunning)
                Button(L("install.title"), action: model.startInstall)
                    .buttonStyle(GradientButtonStyle())
                    .frame(width: 130)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canInstall)
            }
        }
    }

    private var canInstall: Bool {
        guard !flow.isRunning, case .success? = model.environment else { return false }
        return model.devices.contains { $0.id == flow.deviceID && $0.isAvailable }
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

/// The paired devices; only reachable ones can be chosen. "＋ New device" (or no reachable device
/// at all) shows the first-pairing helper, which watches the list and selects the new device.
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
            SectionTitle(L("install.device"))
            VStack(spacing: 0) {
                ForEach(devices) { device in
                    DeviceChoice(device: device, isSelected: flow.deviceID == device.id) {
                        flow.deviceID = device.id
                    }
                    .disabled(!device.isAvailable || flow.isRunning)
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
        flow.deviceID = device.id
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
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.violet) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }
}

/// App icon placeholder (or the chosen custom icon).
private struct AppGlyph: View {
    let iconURL: URL?

    var body: some View {
        Group {
            if let iconURL, let image = NSImage(contentsOf: iconURL) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.brand
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
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
