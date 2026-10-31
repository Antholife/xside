import AppKit
import SwiftUI
import XSideCore

enum AppLinks {
    static let repository = URL(string: "https://github.com/Antholife/xside")!
    static let author = URL(string: "https://github.com/Antholife")!
    /// A new issue on the bug report form (.github/ISSUE_TEMPLATE/bug_report.yml).
    static let newBugReport = URL(string: "https://github.com/Antholife/xside/issues/new?template=bug_report.yml")!
}

/// The pages of the Settings window.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, signing, notifications, updates, logs, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("settings.pane.general")
        case .signing: L("settings.signing")
        case .notifications: L("settings.notifications")
        case .updates: L("updates.title")
        case .logs: L("logs.title")
        case .about: L("settings.about")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .signing: "hammer.fill"
        case .notifications: "bell.badge.fill"
        case .updates: "arrow.triangle.2.circlepath"
        case .logs: "doc.text.magnifyingglass"
        case .about: "info.circle.fill"
        }
    }
}

/// The Settings window: a sidebar of pages, like System Settings; each page is short enough
/// not to scroll. Opens on the page `model.settingsPane` names (set by whoever opened it).
struct SettingsView: View {
    let model: AppModel
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    private var panes: [SettingsPane] {
        SettingsPane.allCases.filter { $0 != .updates || model.updater.isAvailable }
    }

    var body: some View {
        // Hand-made sidebar: NavigationSplitView inside the Settings scene left the window at a
        // few points wide.
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(panes) { pane in
                    SidebarRow(pane: pane, isSelected: model.settingsPane == pane,
                               needsAttention: pane == .signing && model.environmentFailed) {
                        model.settingsPane = pane
                    }
                }
                Spacer(minLength: 0)
                Text("XSide \(Bundle.main.shortVersion ?? "") β")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
            }
            .padding(10)
            .frame(width: 210)
            .frame(maxHeight: .infinity)
            .background(.background.secondary)
            Divider()
            SettingsPage(model: model, pane: model.settingsPane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 500)
        .navigationTitle(model.settingsPane.title)
        .id(language)
        // While something fails, re-check every 5 s so a fix in Xcode shows up here by itself.
        .task {
            while !Task.isCancelled {
                if model.environmentFailed { model.recheckEnvironment() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// One page in the sidebar: icon tile, title, a dot when it needs a look.
private struct SidebarRow: View {
    let pane: SettingsPane
    let isSelected: Bool
    let needsAttention: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                PaneIcon(symbol: pane.symbol)
                Text(pane.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if needsAttention {
                    Circle().fill(Color(nsColor: .systemOrange)).frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.violet.opacity(0.28))
                                 : isHovering ? AnyShapeStyle(Theme.hoverFill) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A sidebar icon: white symbol on the brand gradient, like System Settings' colored tiles.
private struct PaneIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Theme.brand, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// One page of Settings.
private struct SettingsPage: View {
    let model: AppModel
    let pane: SettingsPane
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @AppStorage(Notifier.notifyRefreshSuccessKey) private var notifyRefreshSuccess = true
    @Environment(\.openWindow) private var openWindow
    @State private var login = LaunchAtLogin()
    @State private var notifications = NotificationPermission()

    var body: some View {
        Form {
            switch pane {
            case .general: general
            case .signing:
                Section { SigningHero(model: model) }
                SigningSettingsSection(model: model)
            case .notifications: notificationsPage
            case .updates: UpdatesSection(updater: model.updater)
            case .logs: logs
            case .about: Section { AboutCard() }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: login.refresh)
        .task { await notifications.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
            Task { await notifications.refresh() }
        }
    }

    @ViewBuilder private var general: some View {
        Section {
            Toggle(L("settings.launchAtLogin"), isOn: Binding(get: { login.isEnabled }, set: login.set))
            LaunchAtLoginNotes(login: login)
            Picker(L("settings.language"), selection: $language) {
                Text(L("settings.language.system")).tag(AppLanguage.system.rawValue)
                Text(L("settings.language.en")).tag(AppLanguage.en.rawValue)
                Text(L("settings.language.fr")).tag(AppLanguage.fr.rawValue)
            }
        }
        if let issue = model.library.loadIssue {
            Section { LibraryIssueBanner(issue: issue) }
        }
        Section {
            LabeledContent(L("settings.journey")) {
                Button(L("settings.replayJourney")) { openWindow.presentJourney(model, at: .language) }
            }
        }
    }

    @ViewBuilder private var notificationsPage: some View {
        Section {
            Toggle(L("settings.notifyRefreshSuccess"), isOn: $notifyRefreshSuccess)
            if notifications.state == .notDetermined || notifications.state == .denied {
                NotificationPermissionCard(permission: notifications)
            }
        } footer: {
            Text(L("settings.notifications.footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var logs: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    Button(L("logs.show")) { NSWorkspace.shared.open(Diagnostics.directory) }
                    Button(L("logs.export")) { Diagnostics.export(model: model) }
                }
                .fixedSize()
            } label: {
                Text(L("logs.title"))
                Text(L("logs.subtitle"))
            }
        }
    }
}

/// Top of the signing page: everything ready, or what to fix first.
private struct SigningHero: View {
    let model: AppModel

    var body: some View {
        let ready = model.environment != nil && !model.environmentFailed
        HStack(spacing: 14) {
            Image(systemName: ready ? "checkmark" : model.environment == nil ? "ellipsis" : "exclamationmark")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(ready ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color(nsColor: .systemOrange)),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: (ready ? Theme.violet : .orange).opacity(0.3), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(ready ? "settings.signing.hero.ready" : model.environment == nil
                       ? "settings.signing.checking" : "settings.signing.hero.todo"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L(ready ? "settings.signing.hero.readyText" : "settings.signing.hero.todoText"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// Automatic checks and how often, the channel, "Check now" and when the last check ran.
private struct UpdatesSection: View {
    let updater: Updater
    @State private var automatic = false
    @State private var frequency = Updater.Frequency.daily
    @State private var channel = Updater.Channel.beta

    var body: some View {
        Section(L("updates.title")) {
            Toggle(L("updates.automatic"), isOn: $automatic)
                .onChange(of: automatic) { _, on in updater.automaticallyChecks = on }
            Picker(L("updates.frequency"), selection: $frequency) {
                Text(L("updates.frequency.daily")).tag(Updater.Frequency.daily)
                Text(L("updates.frequency.weekly")).tag(Updater.Frequency.weekly)
                Text(L("updates.frequency.monthly")).tag(Updater.Frequency.monthly)
            }
            .disabled(!automatic)
            .onChange(of: frequency) { _, value in updater.frequency = value }
            LabeledContent {
                Picker(L("updates.channel"), selection: $channel) {
                    Text(L("updates.channel.beta")).tag(Updater.Channel.beta)
                    Text(L("updates.channel.stable")).tag(Updater.Channel.stable)
                        .selectionDisabled(!Updater.Channel.stableAvailable)
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: channel) { _, value in Updater.channel = value }
            } label: {
                Text(L("updates.channel"))
                if !Updater.Channel.stableAvailable {
                    Text(L("updates.channel.noStable"))
                }
            }
            LabeledContent {
                Button(L("updates.checkNow"), action: updater.checkNow)
                    .disabled(!updater.canCheck)
            } label: {
                Text(L("updates.current", Bundle.main.shortVersion ?? "?"))
                if let last = updater.lastCheck {
                    Text(L("updates.lastCheck", last.formatted(.relative(presentation: .named).locale(appLocale))))
                }
            }
        }
        .onAppear {
            automatic = updater.automaticallyChecks
            frequency = updater.frequency
            channel = Updater.channel
        }
    }
}
