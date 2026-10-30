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
    }
}

private struct PopoverContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// Closes the popover: every action that leads elsewhere (window, web page) does.
    @Environment(\.closePopover) private var dismiss
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
            PopoverFooter(model: model, appIDsRemaining: nil, showsSettings: false)
        }
        .padding(12)
        .frame(width: 340)
        .background(PopoverTint())
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
            if let flow = model.install, InstallProgressCard.isShown(for: flow, in: model) {
                // The run lives in the model: the window shows it where it is.
                InstallProgressCard(model: model, flow: flow) {
                    dismiss()
                    openWindow(id: InstallWindow.id)
                    NSApp.activate()
                }
            } else {
                actionTiles
            }
            PopoverDivider()
            devices
            PopoverFooter(model: model, appIDsRemaining: model.appIDsRemaining)
        }
        .padding(12)
        .frame(width: 340)
        .background(PopoverTint())
        .overlay { if isDropTargeted { DropHighlight() } }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: AppDelegate.isIPA) else { return false }
            dismiss()
            openWindow.presentInstall(url, model: model)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    /// Install an app, refresh them all.
    private var actionTiles: some View {
        let refreshable = model.refreshableEntries.count
        return HStack(spacing: 8) {
            Button {
                // Close the popover first: the file picker opens on its own, not over it.
                dismiss()
                DispatchQueue.main.async {
                    if let url = chooseIPA() { openWindow.presentInstall(url, model: model) }
                }
            } label: {
                ActionTileLabel(symbol: "arrow.down.app.fill", title: L("popover.tile.install"))
            }
            .buttonStyle(ActionTileStyle(prominent: true))
            Button(action: model.refreshAll) {
                ActionTileLabel(symbol: "arrow.triangle.2.circlepath", title: L("popover.tile.refreshAll"))
            }
            .buttonStyle(ActionTileStyle(prominent: false))
            .disabled(refreshable == 0)
            .help(refreshable == 0 ? L("popover.tile.refreshAll.none") : L("popover.tile.refreshAll.help", refreshable))
        }
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
                               onRemove: {
                                   afterClosing {
                                       guard AppRowAlerts.confirmRemoveDevice() else { return }
                                       Task { await model.removeDevice(group.id) }
                                   }
                               })
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
                                   icon: model.icons.image(for: entry.record),
                                   onRefresh: { model.refreshNow(entry.job) },
                                   onUninstall: { uninstall(entry, deviceName: group.name) },
                                   onStopRefreshing: { stopRefreshing(entry, deviceName: group.name) },
                                   onResume: { resume(entry) },
                                   onRemoveFromList: { removeFromList(entry, deviceName: group.name) })
                        }
                    }
                }
            }
        }
    }

    /// Closes the popover, then runs `alert` once XSide is active, on a later runloop turn: the
    /// confirmation shows alone, not over the panel (nor under the row's menu, still closing).
    private func afterClosing(_ alert: @escaping @MainActor () -> Void) {
        dismiss()
        DispatchQueue.main.async {
            NSApp.activate()
            DispatchQueue.main.async { alert() }
        }
    }

    /// Confirmed first; on failure (device out of reach, devicectl error) the alert offers to stop
    /// refreshing (pause) instead, unless it's already paused. The popover is closed by then.
    private func uninstall(_ entry: AppEntry, deviceName: String) {
        let app = entry.record.options.displayName ?? entry.record.displayName
        afterClosing {
            guard AppRowAlerts.confirmUninstall(app: app, device: deviceName) else { return }
            Task {
                do {
                    try await model.uninstall(entry)
                } catch {
                    // The popover may have been opened again meanwhile: closed again first.
                    afterClosing {
                        guard AppRowAlerts.uninstallFailed(app: app, device: deviceName, error: error,
                                                           offerPause: !entry.installation.refreshPaused) else { return }
                        Task { await model.stopRefreshing(entry) }
                    }
                }
            }
        }
    }

    private func stopRefreshing(_ entry: AppEntry, deviceName: String) {
        let app = entry.record.options.displayName ?? entry.record.displayName
        afterClosing {
            guard AppRowAlerts.confirmStopRefreshing(app: app, device: deviceName) else { return }
            Task { await model.stopRefreshing(entry) }
        }
    }

    /// No confirmation: undoing it is just stopping again. The popover closes like for the others.
    private func resume(_ entry: AppEntry) {
        dismiss()
        Task { await model.resumeRefreshing(entry) }
    }

    private func removeFromList(_ entry: AppEntry, deviceName: String) {
        let app = entry.record.options.displayName ?? entry.record.displayName
        afterClosing {
            guard AppRowAlerts.confirmRemoveFromList(app: app, device: deviceName) else { return }
            Task { await model.removeFromList(entry) }
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

/// "~N/10 App IDs left…", then icon tiles: Settings, What's New, logs, the version, Quit.
private struct PopoverFooter: View {
    let model: AppModel
    let appIDsRemaining: Int?
    var showsSettings = true
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.closePopover) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "") β"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let appIDsRemaining {
                Text(L("popover.appIDsRemaining", appIDsRemaining))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            PopoverDivider()
            HStack(spacing: 6) {
                if showsSettings {
                    IconTile(symbol: "gearshape.fill", help: L("popover.settings")) {
                        dismiss()
                        NSApp.activate()
                        openSettings()
                    }
                    IconTile(symbol: "sparkles", help: L("whatsNew.window")) {
                        dismiss()
                        openWindow(id: WhatsNewWindow.id)
                        NSApp.activate()
                    }
                    IconTile(symbol: "doc.text.magnifyingglass", help: L("logs.exportLink")) {
                        dismiss()
                        DispatchQueue.main.async { Diagnostics.export(model: model) }
                    }
                }
                Spacer()
                Text(version)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                // Confirmed by `AppDelegate.applicationShouldTerminate` while it would stop a refresh:
                // the popover closes first, so a cancelled quit doesn't leave it open behind.
                IconTile(symbol: "power", help: L("popover.quit")) {
                    dismiss()
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
                .keyboardShortcut("q")
            }
        }
    }
}

/// A thin separator, lighter than `Divider` on the glass.
private struct PopoverDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
    }
}

/// A faint brand wash behind the popover's material.
private struct PopoverTint: View {
    var body: some View {
        LinearGradient(colors: [Theme.violet.opacity(0.12), Theme.pink.opacity(0.05), .clear],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// Big square-ish tile: an icon over its title.
private struct ActionTileLabel: View {
    let symbol: String
    let title: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64)
    }
}

/// `prominent`: the brand gradient with white content; else a glass tile with brand content.
private struct ActionTileStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        ActionTileBody(configuration: configuration, prominent: prominent)
    }
}

private struct ActionTileBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        configuration.label
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.brand))
            .background {
                if prominent {
                    shape.fill(Theme.brand)
                        .shadow(color: Theme.violet.opacity(isHovering ? 0.45 : 0.3), radius: isHovering ? 8 : 5, y: 2)
                } else {
                    shape.fill(Theme.violet.opacity(isHovering ? 0.16 : 0.09))
                }
            }
            .overlay(shape.strokeBorder(prominent ? Color.white.opacity(0.18) : Theme.violet.opacity(0.18), lineWidth: 0.5))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
            .onHover { isHovering = $0 && isEnabled }
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Small icon-only footer tile, with its name as tooltip.
private struct IconTile: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovering ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.secondary))
                .frame(width: 32, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Theme.violet.opacity(0.14) : Color.primary.opacity(0.05)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
