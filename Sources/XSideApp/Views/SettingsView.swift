import AppKit
import SwiftUI
import XSideCore

enum AppLinks {
    static let repository = URL(string: "https://github.com/Antholife/xside")!
    static let author = URL(string: "https://github.com/Antholife")!
    /// A new issue on the bug report form (.github/ISSUE_TEMPLATE/bug_report.yml).
    /// Files on `main`: they exist on GitHub from the release that ships them.
    static let agentsGuide = URL(string: "https://github.com/Antholife/xside/blob/main/AGENTS.md")!
    static let contributing = URL(string: "https://github.com/Antholife/xside/blob/main/CONTRIBUTING.md")!
    static let issues = URL(string: "https://github.com/Antholife/xside/issues")!
    static let pullRequests = URL(string: "https://github.com/Antholife/xside/pulls")!
    static let newBugReport = URL(string: "https://github.com/Antholife/xside/issues/new?template=bug_report.yml")!
}

/// The pages of the Settings window.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, refresh, install, inApp, apps, notifications, signing, updates, logs, build, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("settings.pane.general")
        case .refresh: L("settings.pane.refresh")
        case .install: L("settings.pane.install")
        case .inApp: L("settings.pane.inApp")
        case .apps: L("settings.pane.apps")
        case .signing: L("settings.signing")
        case .notifications: L("settings.notifications")
        case .updates: L("updates.title")
        case .logs: L("settings.pane.reports")
        case .build: L("settings.pane.build")
        case .about: L("settings.about")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .refresh: "arrow.clockwise"
        case .install: "square.and.arrow.down.fill"
        case .inApp: "apps.iphone"
        case .apps: "square.grid.2x2.fill"
        case .signing: "hammer.fill"
        case .notifications: "bell.badge.fill"
        case .updates: "arrow.triangle.2.circlepath"
        case .logs: "doc.text.magnifyingglass"
        case .build: "hammer.circle.fill"
        case .about: "info.circle.fill"
        }
    }
}

/// How tall a Settings page's content is, reported by the page (`reportsPaneHeight`) so the
/// window takes that height: no page scrolls at the default text size when the screen has room
/// (device feedback round 2, M1). `part` tells apart two scrolling parts of one page (Mes apps:
/// its list and its options); the window fits the taller.
private struct PaneHeightReporter: EnvironmentKey {
    static let defaultValue: @MainActor (_ part: String, _ height: CGFloat) -> Void = { _, _ in }
}

extension EnvironmentValues {
    fileprivate var reportPaneHeight: @MainActor (_ part: String, _ height: CGFloat) -> Void {
        get { self[PaneHeightReporter.self] }
        set { self[PaneHeightReporter.self] = newValue }
    }
}

private struct ReportsPaneHeight: ViewModifier {
    let part: String
    let extra: CGFloat
    @Environment(\.reportPaneHeight) private var report

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report(part, $0 + extra) }
    }
}

private struct ReportsFormHeight: ViewModifier {
    @Environment(\.reportPaneHeight) private var report

    func body(content: Content) -> some View {
        // A grouped Form scrolls by itself: its content's height, insets included.
        content.onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
        } action: { _, height in
            report("main", height)
        }
    }
}

extension View {
    /// Put on a Settings page's content inside its ScrollView (its natural height), with `extra`
    /// for what sits above the ScrollView. See `PaneHeightReporter`.
    func reportsPaneHeight(_ part: String = "main", adding extra: CGFloat = 0) -> some View {
        modifier(ReportsPaneHeight(part: part, extra: extra))
    }
}

/// The Settings window: a sidebar of pages, like System Settings. The window is as tall as the
/// page shown needs (within the screen), so pages don't scroll at the default text size; they
/// only do on a short screen or with large text. Opens on the page `model.settingsPane` names
/// (set by whoever opened it).
struct SettingsView: View {
    let model: AppModel
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    /// The pages' reported heights (see `PaneHeightReporter`), by page and part.
    @State private var paneHeights: [SettingsPane: [String: CGFloat]] = [:]

    /// Shortest window: the sidebar's eleven rows and the version.
    private static let minHeight: CGFloat = 470
    /// Before the page reports: the former fixed height.
    private static let defaultHeight: CGFloat = 560

    /// The page's content height, within the screen (less the title bar and a margin).
    private var height: CGFloat {
        let screen = (NSScreen.main?.visibleFrame.height ?? 800) - 28 - 24
        guard let content = paneHeights[model.settingsPane]?.values.max() else { return min(Self.defaultHeight, screen) }
        return min(max(Self.minHeight, content.rounded(.up)), screen)
    }

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
            Group {
                // Its own list and scrolling, not a Form.
                if model.settingsPane == .apps { AppsSettingsPage(model: model) }
                else if model.settingsPane == .build { BuildSettingsPage() }
                else { SettingsPage(model: model, pane: model.settingsPane) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: height)
        .environment(\.reportPaneHeight) { [pane = model.settingsPane] part, value in
            // Small moves (a hover, a line wrapping differently) don't resize the window.
            if abs((paneHeights[pane]?[part] ?? 0) - value) >= 2 { paneHeights[pane, default: [:]][part] = value }
        }
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
        .accessibilityValue(needsAttention ? L("settings.signing.hero.todo") : "")
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
            .accessibilityHidden(true)
    }
}

/// One page of Settings.
private struct SettingsPage: View {
    let model: AppModel
    let pane: SettingsPane
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @AppStorage(Notifier.notifyRefreshSuccessKey) private var notifyRefreshSuccess = true
    @AppStorage(AppModel.openAppAfterInstallKey) private var openAppAfterInstall = true
    @AppStorage(AppModel.openTrustSettingsKey) private var openTrustSettings = true
    @AppStorage(AppModel.forgetDeletedAppsKey) private var forgetDeletedApps = true
    @AppStorage(AppModel.reviewInstallOptionsKey) private var reviewInstallOptions = true
    @AppStorage(BackgroundEngine.refreshDaysBeforeKey) private var refreshDaysBefore = 2
    @AppStorage(BackgroundEngine.pausedUntilKey) private var pausedUntil = 0.0
    @AppStorage(BackgroundEngine.acOnlyKey) private var acOnly = false
    @AppStorage(BackgroundEngine.preferredHoursKey) private var preferredHours = ""
    @AppStorage(AppModel.notifyAppRemovedKey) private var notifyAppRemoved = true
    @Environment(\.openWindow) private var openWindow
    @State private var login = LaunchAtLogin()
    @State private var notifications = NotificationPermission()

    var body: some View {
        Form {
            switch pane {
            case .general: general
            case .refresh: refreshPage
            case .install: installPage
            case .inApp: InAppDefaultsPage()
            case .apps, .build: EmptyView() // shown by SettingsView (AppsSettingsPage, BuildSettingsPage)
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
        .modifier(ReportsFormHeight())
        .toggleStyle(.xside)
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
            KeepInDockToggle()
        }
        if let issue = model.library.loadIssue {
            Section { LibraryIssueBanner(issue: issue) }
        }
        Section {
            CommandLineRow()
        }
        Section {
            LabeledContent(L("settings.journey")) {
                Button(L("settings.replayJourney")) { openWindow.presentJourney(model, at: .language) }
            }
        }
    }

    /// Automatic refreshes, and what XSide notices on the devices.
    @ViewBuilder private var refreshPage: some View {
        Section {
            Picker(selection: $refreshDaysBefore) {
                ForEach(RefreshPlanner.daysBeforeChoices, id: \.self) { days in
                    Text(L(days == 1 ? "settings.refreshDaysBefore.one" : "settings.refreshDaysBefore.many", days)).tag(days)
                }
            } label: {
                Text(L("settings.refreshDaysBefore"))
                Text(L("settings.refreshDaysBefore.note"))
            }
            .onChange(of: refreshDaysBefore) { model.onNeedsEvaluation?() }
            PauseRow(pausedUntil: $pausedUntil, onChange: { model.onNeedsEvaluation?() })
            Toggle(isOn: $acOnly) {
                Text(L("settings.acOnly"))
                Text(L("settings.acOnly.note"))
            }
            Picker(selection: $preferredHours) {
                Text(L("settings.hours.any")).tag("")
                Text(L("settings.hours.night")).tag(RefreshPolicy.Hours.night.rawValue)
                Text(L("settings.hours.evening")).tag(RefreshPolicy.Hours.evening.rawValue)
            } label: {
                Text(L("settings.hours"))
                Text(L("settings.hours.note"))
            }
            .onChange(of: preferredHours) { model.onNeedsEvaluation?() }
        } header: {
            Text(L("settings.autoRefresh"))
        } footer: {
            Text(L("settings.autoRefresh.footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            Toggle(isOn: Binding(get: { model.devicePrefs.newDevicesWifi }, set: { model.setNewDevicesWifi($0) })) {
                Text(L("settings.newDevicesWifi"))
                Text(L("settings.newDevicesWifi.note"))
            }
            Toggle(isOn: $forgetDeletedApps) {
                Text(L("settings.forgetDeletedApps"))
                Text(L("settings.forgetDeletedApps.note"))
            }
        }
    }

    /// The install window's defaults, and the firewall prompt the apps' channel can bring.
    @ViewBuilder private var installPage: some View {
        Section {
            Toggle(isOn: $reviewInstallOptions) {
                Text(L("settings.reviewOptions"))
                Text(L("settings.reviewOptions.note"))
            }
            Toggle(isOn: $openAppAfterInstall) {
                Text(L("settings.openAppAfterInstall"))
                Text(L("settings.openAppAfterInstall.note"))
            }
            Toggle(isOn: $openTrustSettings) {
                Text(L("settings.openTrustSettings"))
                Text(L("settings.openTrustSettings.note"))
            }
            .disabled(!openAppAfterInstall)
        } footer: {
            Text(L("settings.afterInstall.footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            LabeledContent {
                Image(systemName: "network.badge.shield.half.filled")
                    .foregroundStyle(.secondary)
            } label: {
                Text(L("settings.firewall"))
                Text(L("settings.firewall.note"))
            }
        }
    }

    @ViewBuilder private var notificationsPage: some View {
        Section {
            Toggle(L("settings.notifyRefreshSuccess"), isOn: $notifyRefreshSuccess)
            Toggle(isOn: $notifyAppRemoved) {
                Text(L("settings.notifyAppRemoved"))
                Text(L("settings.notifyAppRemoved.note"))
            }
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
                Button(L("report.button")) { Diagnostics.reportIssue(model: model) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.violet)
                    .fixedSize()
            } label: {
                Label(L("report.title"), systemImage: "ladybug.fill")
                Text(L("report.subtitle"))
            }
        }
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
/// "Pause automatic refreshes": a menu of durations, or until when and "Resume" while paused.
private struct PauseRow: View {
    @Binding var pausedUntil: Double
    let onChange: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let until = RefreshPause.until(pausedUntil, now: context.date) {
                LabeledContent {
                    Button(L("settings.pause.resume")) { set(nil) }
                } label: {
                    Label(RefreshPause.label(until), systemImage: "pause.circle.fill")
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
            } else {
                LabeledContent(L("settings.pause")) {
                    Menu(L("settings.pause.menu")) { RefreshPause.choices { set($0) } }
                        .fixedSize()
                }
            }
        }
    }

    private func set(_ date: Date?) {
        pausedUntil = date?.timeIntervalSince1970 ?? 0
        onChange()
    }
}

/// The pause of automatic refreshes, shared by Settings and the popover (stored as seconds since
/// 1970 under `BackgroundEngine.pausedUntilKey`, 0 when not paused).
@MainActor enum RefreshPause {
    /// When the pause ends, nil when not paused (or over).
    static func until(_ stored: Double, now: Date = Date()) -> Date? {
        let until = Date(timeIntervalSince1970: stored)
        return stored > 0 && until > now ? until : nil
    }

    static func label(_ until: Date) -> String {
        until == .distantFuture ? L("settings.pause.indefinitely")
                                : L("settings.pause.until", until.formatted(date: .abbreviated, time: .shortened))
    }

    /// The menu's durations.
    @ViewBuilder static func choices(_ pick: @escaping @MainActor (Date) -> Void) -> some View {
        Button(L("settings.pause.hour")) { pick(Date().addingTimeInterval(3600)) }
        Button(L("settings.pause.tomorrow")) { pick(tomorrowMorning) }
        Button(L("settings.pause.untilResumed")) { pick(.distantFuture) }
    }

    /// Tomorrow at 8:00.
    static var tomorrowMorning: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

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
                // Nothing to say yet while checking.
                if model.environment != nil {
                    Text(L(ready ? "settings.signing.hero.readyText" : "settings.signing.hero.todoText"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
    @State private var installsAutomatically = false
    @State private var frequency = Updater.Frequency.daily
    @State private var channel = Updater.Channel.beta

    var body: some View {
        Section(L("updates.title")) {
            Toggle(L("updates.automatic"), isOn: $automatic)
                .onChange(of: automatic) { _, on in updater.automaticallyChecks = on }
            Toggle(isOn: $installsAutomatically) {
                Text(L("updates.autoInstall"))
                Text(L("updates.autoInstall.detail"))
            }
            .disabled(!automatic)
            .onChange(of: installsAutomatically) { _, on in updater.automaticallyInstalls = on }
            Picker(selection: $frequency) {
                Text(L("updates.frequency.hourly")).tag(Updater.Frequency.hourly)
                Text(L("updates.frequency.daily")).tag(Updater.Frequency.daily)
                Text(L("updates.frequency.weekly")).tag(Updater.Frequency.weekly)
                Text(L("updates.frequency.monthly")).tag(Updater.Frequency.monthly)
            } label: {
                Text(L("updates.frequency"))
                Text(L("updates.frequency.note"))
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
            installsAutomatically = updater.automaticallyInstalls
            frequency = updater.frequency
            channel = Updater.channel
        }
    }
}

/// Settings > General: put `xside` in the Terminal, or say how.
private struct CommandLineRow: View {
    @State private var cli = CommandLineInstall.shared

    var body: some View {
        LabeledContent {
            if cli.link != nil {
                Button(L("cli.uninstall"), action: cli.uninstall)
            } else {
                Button(L("cli.install"), action: cli.install)
            }
        } label: {
            Text(L("cli.title"))
            if let link = cli.link {
                Text(L("cli.installed", link.deletingLastPathComponent().path))
            } else if cli.needsManual {
                Text(L("cli.manual"))
                CommandLineManual()
            } else {
                Text(L("cli.detail"))
            }
        }
        .onAppear(perform: cli.refresh)
    }
}

/// The command to run by hand when no usual folder is writable, with Copy.
struct CommandLineManual: View {
    var body: some View {
        HStack(spacing: 6) {
            Text(CommandLineTool.manualCommand)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
            Button(L("cli.copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(CommandLineTool.manualCommand, forType: .string)
            }
            .controlSize(.small)
        }
    }
}

/// Settings > Module XSide dans les apps: what new installs start with (each app then keeps its own),
/// and, apart, installing every app without XSide's features.
private struct InAppDefaultsPage: View {
    @AppStorage(AppModel.inAppShowValidityKey) private var showValidity = true
    @AppStorage(AppModel.inAppAlertLateKey) private var alertLate = true
    @AppStorage(AppModel.inAppRefreshCardKey) private var refreshCard = true
    @AppStorage(AppModel.deviceReminderKey) private var reminder = true
    @AppStorage(AppModel.inAppLanguageKey) private var language = MessageLanguage.automatic.rawValue
    @AppStorage(AppModel.installWithoutFeaturesKey) private var withoutFeatures = false
    @State private var confirmingNoFeatures = false

    /// The stored defaults (the `@AppStorage` values above keep the page current).
    private var defaults: InAppSettings {
        _ = (showValidity, alertLate, refreshCard, reminder, language)
        return AppModel.inAppDefaults(at: Date())
    }

    private func edit(_ change: InAppEdit) {
        AppModel.setInAppDefaults(change(defaults))
    }

    var body: some View {
        Section {
            WhereBox(appName: L("inApp.where.anyApp"))
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            LabeledContent {
                MessagesMenu(level: defaults.derivedLevel) { level in edit { $0.applying(level: level, at: Date(), by: .mac) } }
            } label: {
                Text(L("inApp.messages"))
                Text(defaults.derivedLevel.note)
            }
            toggle(.showValidity, $showValidity)
            toggle(.alertLate, $alertLate)
            toggle(.refreshCard, $refreshCard)
            toggle(.reminder, $reminder)
            LabeledContent {
                LanguagePicker(language: defaults.language.value) { language = $0.rawValue }
            } label: {
                Text(L("inApp.language"))
                Text(L("inApp.language.note"))
            }
        } header: {
            Text(L("settings.inApp.defaults"))
        } footer: {
            Text(L("settings.inApp.footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            Toggle(isOn: Binding(get: { withoutFeatures }, set: { on in
                if on { confirmingNoFeatures = true } else { withoutFeatures = false }
            })) {
                Text(L("settings.withoutFeatures"))
                Text(L("settings.withoutFeatures.note"))
            }
        }
        .sheet(isPresented: $confirmingNoFeatures) {
            NoFeaturesConfirmation(appName: nil) { withoutFeatures = true }
        }
    }

    private func toggle(_ option: InAppOption, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Text(option.title)
            Text(option.note)
        }
    }
}
