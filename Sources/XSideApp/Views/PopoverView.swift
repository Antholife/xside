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
    /// Closes the popover: every action that leads elsewhere (window, web page) does.
    @Environment(\.dismiss) private var dismiss
    @AppStorage(JourneyStep.completedKey) private var journeyCompleted = false
    @State private var isDropTargeted = false

    var body: some View {
        if !journeyCompleted {
            setupBody
        } else {
            mainBody
        }
    }

    /// Until setup is done: only the setup card and the minimal footer.
    private var setupBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            SetupCard {
                dismiss()
                openWindow.presentJourney(model)
            }
            PopoverFooter(appIDsRemaining: nil, showsSettings: false)
        }
        .padding(12)
        .frame(width: 320)
    }

    private var mainBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.environmentProblems, id: \.key) { error in
                EnvironmentBanner(error: error, onOpen: { dismiss() }, onRecheck: model.recheckEnvironment,
                                  isChecking: model.isProbing)
            }
            if model.macBetaWithReleaseXcode { MacBetaBanner { dismiss() } }
            if let issue = model.library.loadIssue, !model.libraryIssueDismissed {
                LibraryIssueBanner(issue: issue, onDismiss: model.dismissLibraryIssue)
            }
            ForEach(model.unpairedDevices) { device in
                PairPrompt(device: device, isPairing: model.pairing.contains(device.id),
                           error: model.pairErrors[device.id]) { model.pair(device) }
            }
            devices
            Button(L("popover.install")) {
                // Close the popover first: the file picker opens on its own, not over it.
                dismiss()
                DispatchQueue.main.async {
                    if let url = chooseIPA() { openWindow.presentInstall(url, model: model) }
                }
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
            dismiss()
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
                    DeviceCard(group: group,
                               onWifiRefresh: { model.setWifiRefresh($0, for: group.id) },
                               onRemove: { Task { await model.removeDevice(group.id) } })
                    if group.apps.isEmpty {
                        Text(L("popover.empty"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(group.apps) { entry in
                            AppRow(entry: entry, step: model.jobs[entry.id], canRefresh: model.canRefresh(entry),
                                   canManage: model.canManage(entry),
                                   isUninstalling: model.uninstalling.contains(entry.id),
                                   needsUSB: group.needsUSB, deviceName: group.name,
                                   onRefresh: { model.refreshNow(entry.job) },
                                   onUninstall: { uninstall(entry, deviceName: group.name) },
                                   onStopRefreshing: { stopRefreshing(entry, deviceName: group.name) })
                        }
                    }
                }
            }
        }
    }

    /// Confirmed first; on failure (device out of reach, devicectl error) the alert offers to stop
    /// refreshing instead. Alerts wait for the menu to close, so they don't open under it.
    private func uninstall(_ entry: AppEntry, deviceName: String) {
        let app = entry.record.options.displayName ?? entry.record.displayName
        DispatchQueue.main.async {
            guard AppRowAlerts.confirmUninstall(app: app, device: deviceName) else { return }
            Task {
                do {
                    try await model.uninstall(entry)
                } catch {
                    if AppRowAlerts.uninstallFailed(app: app, device: deviceName, error: error) {
                        await model.stopRefreshing(entry)
                    }
                }
            }
        }
    }

    private func stopRefreshing(_ entry: AppEntry, deviceName: String) {
        let app = entry.record.options.displayName ?? entry.record.displayName
        DispatchQueue.main.async {
            guard AppRowAlerts.confirmStopRefreshing(app: app, device: deviceName) else { return }
            Task { await model.stopRefreshing(entry) }
        }
    }
}

/// After setup, the signing environment broke (Xcode removed, signed out, certificate gone): no
/// refresh can run until it's fixed in Settings.
struct EnvironmentBanner: View {
    let error: XSideError
    /// Called after Settings opens (the popover closes itself).
    var onOpen: () -> Void = {}
    /// Checks the environment again (a failed check); nil shows "Fix in Settings" instead.
    var onRecheck: (() -> Void)?
    var isChecking = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 15))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 6) {
                Text(error.setupTitle).font(.system(size: 12.5, weight: .semibold))
                Text(error.environmentReason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // A failed check has nothing to fix: checking again is the action.
                if error.isSetupCheckFailure, let onRecheck {
                    Button(L("onboarding.recheck"), action: onRecheck)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.violet)
                        .controlSize(.small)
                        .disabled(isChecking)
                } else {
                    Button(L("environment.banner.fix")) {
                        onOpen()
                        NSApp.activate()
                        openSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.violet)
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// `state.json` couldn't be fully read at launch: say what was lost, once (dismissed until next launch).
struct LibraryIssueBanner: View {
    let issue: LibraryLoadIssue
    /// Nil in Settings, where the line stays.
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(issue.localizedMessage)
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                if let onDismiss {
                    Button(L("background.hint.ok"), action: onDismiss)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension LibraryLoadIssue {
    var localizedMessage: String {
        switch self {
        case .recordsSkipped(let count): L("library.issue.recordsSkipped", count)
        case .restoredFromBackup: L("library.issue.restoredFromBackup")
        case .unreadable: L("library.issue.unreadable")
        }
    }
}

/// macOS beta with a release Xcode: a warning, nothing is blocked.
struct MacBetaBanner: View {
    /// Called after the download page opens (the popover closes itself).
    var onOpen: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("macBeta.banner.title")).font(.system(size: 12.5, weight: .semibold))
                Text(L("macBeta.banner.text"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("journey.xcode.downloadBeta")) {
                    NSWorkspace.shared.open(XcodeLauncher.betaURL)
                    onOpen()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.violet)
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// "Finish setting up": a welcoming card whose button reopens the journey where it left off.
struct SetupCard: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Theme.violet.opacity(0.3), radius: 8, y: 3)
            Text(L("journey.popover.title")).font(.system(size: 14, weight: .semibold))
            Text(L("journey.popover.text"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("journey.popover.button"), action: action)
                .buttonStyle(GradientButtonStyle())
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
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
    var showsSettings = true
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

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
                if showsSettings {
                    Button(L("popover.settings")) {
                        dismiss()
                        NSApp.activate()
                        openSettings()
                    }
                }
                Spacer()
                // Confirmed by `AppDelegate.applicationShouldTerminate` while it would stop a refresh.
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
