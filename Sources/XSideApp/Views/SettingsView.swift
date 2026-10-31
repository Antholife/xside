import AppKit
import SwiftUI
import XSideCore

enum AppLinks {
    static let repository = URL(string: "https://github.com/Antholife/xside")!
    static let author = URL(string: "https://github.com/Antholife")!
}

/// The Settings window.
struct SettingsView: View {
    let model: AppModel
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @AppStorage(Notifier.notifyRefreshSuccessKey) private var notifyRefreshSuccess = true
    @Environment(\.openWindow) private var openWindow
    @State private var login = LaunchAtLogin()
    @State private var notifications = NotificationPermission()
    /// Natural height of the form, to size the window to it (scrolling only past the screen).
    @State private var formHeight: CGFloat = 400

    /// Room for the form on the current screen, minus the title bar.
    private static var maxHeight: CGFloat {
        max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 60)
    }

    var body: some View {
        // The window fits the form; a ScrollView alone has no ideal height, so the form's measured
        // one is used, capped by the screen.
        ScrollView(.vertical) {
            form
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 420, height: min(formHeight, Self.maxHeight))
        .navigationTitle(L("popover.settings"))
        .id(language)
        .onAppear(perform: login.refresh)
        .task { await notifications.refresh() }
        // While something fails, re-check every 5 s so a fix in Xcode shows up here by itself.
        .task {
            while !Task.isCancelled {
                if model.environmentFailed { model.recheckEnvironment() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
            Task { await notifications.refresh() }
        }
    }

    private var form: some View {
        Form {
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
            SigningSettingsSection(model: model)
            Section(L("settings.notifications")) {
                Toggle(L("settings.notifyRefreshSuccess"), isOn: $notifyRefreshSuccess)
                if notifications.state == .notDetermined || notifications.state == .denied {
                    NotificationPermissionCard(permission: notifications)
                }
            }
            Section {
                Button(L("settings.replayJourney")) { openWindow.presentJourney(model, at: .language) }
            }
            if model.updater.isAvailable {
                UpdatesSection(updater: model.updater)
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
            Section(L("settings.about")) {
                AboutCard()
            }
        }
        .formStyle(.grouped)
    }
}

/// Automatic checks, "Check now" and when the last check ran.
private struct UpdatesSection: View {
    let updater: Updater
    @State private var automatic = false

    var body: some View {
        Section(L("updates.title")) {
            Toggle(L("updates.automatic"), isOn: $automatic)
                .onChange(of: automatic) { _, on in updater.automaticallyChecks = on }
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
        .onAppear { automatic = updater.automaticallyChecks }
    }
}
