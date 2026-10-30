import AppKit
import SwiftUI

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
            Section(L("settings.about")) {
                AboutCard()
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
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
}
