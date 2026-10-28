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
                InstallSheet(model: model, flow: flow) { dismissWindow(id: InstallWindow.id) }
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
        .onDisappear(perform: model.closeInstall)
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
                if case .running(let step) = flow.phase {
                    StepProgress(current: step)
                }
                if case .editing(let error?) = flow.phase { ErrorText(error) }
                if case .failure(let error)? = model.environment { ErrorText(error.localizedMessage) }
            case .succeeded(let deviceName, let guide):
                StepProgress(current: nil)
                Label(L("install.success", deviceName), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemGreen))
                if let guide { FirstInstallGuideView(guide: guide) }
            }
            buttons
        }
        .padding(20)
        .animation(.smooth(duration: 0.25), value: flow.phase)
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

/// The paired devices; only reachable ones can be chosen.
private struct DevicePicker: View {
    let model: AppModel
    let flow: InstallFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L("install.device"))
            let devices = model.pairedDevices
            if devices.isEmpty {
                Text(L("popover.noDevice"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(devices) { device in
                        DeviceChoice(device: device, isSelected: flow.deviceID == device.id) {
                            flow.deviceID = device.id
                        }
                        .disabled(!device.isAvailable || flow.isRunning)
                        if device.id != devices.last?.id { Divider().padding(.leading, 38) }
                    }
                }
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if !devices.contains(where: \.isAvailable) {
                    Text(L("install.noAvailableDevice"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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

/// Profile → Signing → Installing. `current == nil` means everything is done.
private struct StepProgress: View {
    let current: InstallStep?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(InstallStep.allCases, id: \.self) { step in
                HStack(spacing: 5) {
                    indicator(for: step)
                        .frame(width: 14, height: 14)
                    Text(step.label)
                        .font(.system(size: 12, weight: step == current ? .semibold : .regular))
                        .foregroundStyle(state(of: step) == .pending ? .secondary : .primary)
                }
                if step != InstallStep.allCases.last {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private enum StepState { case done, active, pending }

    private func state(of step: InstallStep) -> StepState {
        guard let current else { return .done }
        if step.rawValue < current.rawValue { return .done }
        return step == current ? .active : .pending
    }

    @ViewBuilder private func indicator(for step: InstallStep) -> some View {
        switch state(of: step) {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
        case .active:
            ProgressView().controlSize(.mini)
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        }
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
