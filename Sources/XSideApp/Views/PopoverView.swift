import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XSideCore

/// Root of the menu-bar popover. Re-created on language change so every `L()` text refreshes.
struct PopoverView: View {
    let model: AppModel
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        PopoverContent(model: model)
            .id(language)
            // Outside `.id` so a language change doesn't report a close/open.
            .background(WindowVisibilityReader { model.popoverVisibilityChanged($0) })
    }
}

private struct PopoverContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .failure(let error)? = model.environment {
                OnboardingView(model: model, error: error, compact: true)
            }
            ForEach(model.unpairedDevices) { device in
                PairPrompt(device: device, isPairing: model.pairing.contains(device.id),
                           error: model.pairErrors[device.id]) { model.pair(device) }
            }
            devices
            Button(L("popover.install")) {
                if let url = chooseIPA() { openWindow.presentInstall(url, model: model) }
            }
            .buttonStyle(GradientButtonStyle())
            .padding(.top, 2)
            PopoverFooter(appIDsRemaining: model.appIDsRemaining)
        }
        .padding(12)
        .frame(width: 320)
        .overlay { if isDropTargeted { DropHighlight() } }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: AppDelegate.isIPA) else { return false }
            openWindow.presentInstall(url, model: model)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    @ViewBuilder private var devices: some View {
        let groups = model.deviceGroups
        if groups.isEmpty {
            if model.unpairedDevices.isEmpty {
                Placeholder(symbol: "iphone.slash", text: L("popover.noDevice"))
            }
        } else {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    DeviceCard(group: group)
                    if group.apps.isEmpty {
                        Text(L("popover.empty"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(group.apps) { entry in
                            AppRow(entry: entry, step: model.jobs[entry.id], canRefresh: model.canRefresh(entry)) {
                                model.refreshNow(entry.job)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct Placeholder: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct DropHighlight: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.violet, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.brand)
                Text(L("popover.dropHint"))
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .padding(4)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// "~N/10 App IDs left…" then "Settings · Quit".
private struct PopoverFooter: View {
    let appIDsRemaining: Int?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let appIDsRemaining {
                Text(L("popover.appIDsRemaining", appIDsRemaining))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            HStack {
                Button(L("popover.settings")) {
                    NSApp.activate()
                    openSettings()
                }
                Spacer()
                Button(L("popover.quit")) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(FooterButtonStyle())
        }
    }
}

private struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FooterButtonLabel(configuration: configuration)
    }
}

private struct FooterButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(isHovering ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(isHovering ? Theme.hoverFill : .clear))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}
