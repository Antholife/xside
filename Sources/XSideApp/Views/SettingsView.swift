import AppKit
import SwiftUI

enum AppLinks {
    // TODO: set the public repository URL once it is decided (placeholder, not a real project page).
    static let repository = URL(string: "https://github.com/")!
}

/// The Settings window.
struct SettingsView: View {
    let model: AppModel
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @AppStorage(Notifier.notifyRefreshSuccessKey) private var notifyRefreshSuccess = true
    @Environment(\.openWindow) private var openWindow
    @State private var login = LaunchAtLogin()
    @State private var notifications = NotificationPermission()

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    var body: some View {
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
            Section(L("settings.notifications")) {
                Toggle(L("settings.notifyRefreshSuccess"), isOn: $notifyRefreshSuccess)
                if notifications.state == .notDetermined || notifications.state == .denied {
                    NotificationPermissionCard(permission: notifications)
                }
            }
            Section {
                Button(L("settings.replayJourney")) { openWindow.presentJourney(model, at: .welcome) }
                Text(L("settings.version", version)).foregroundStyle(.secondary)
                Link(L("settings.github"), destination: AppLinks.repository)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(L("popover.settings"))
        .id(language)
        .onAppear(perform: login.refresh)
        .task { await notifications.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
            Task { await notifications.refresh() }
        }
    }
}
