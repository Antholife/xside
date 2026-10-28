import AppKit
import Observation
import ServiceManagement
import SwiftUI

enum AppLinks {
    // TODO: set the public repository URL once it is decided (placeholder, not a real project page).
    static let repository = URL(string: "https://github.com/")!
}

/// Launch-at-login state, backed by `SMAppService.mainApp` (the source of truth: the user can also
/// change it in System Settings > General > Login Items).
@MainActor @Observable
final class LaunchAtLogin {
    private static let defaultAppliedKey = "launchAtLoginDefaultApplied"
    private let service = SMAppService.mainApp

    private(set) var status: SMAppService.Status
    private(set) var failed = false

    init() { status = SMAppService.mainApp.status }

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = service.status }

    func set(_ enabled: Bool) {
        failed = false
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            failed = true
        }
        refresh()
    }

    /// Enables launch at login on the very first launch only: a user who turns it off later is
    /// never overridden. Needs a real app bundle (no-op under `swift run`).
    static func applyDefaultOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultAppliedKey),
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        defaults.set(true, forKey: defaultAppliedKey)
        try? SMAppService.mainApp.register()
    }
}

/// The Settings window.
struct SettingsView: View {
    /// Task 18 (wake the Mac to refresh) is gated: flip this once it is validated, and bind the toggle.
    private static let showWakeSetting = false

    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @State private var login = LaunchAtLogin()

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    var body: some View {
        Form {
            Section {
                Toggle(L("settings.launchAtLogin"), isOn: Binding(get: { login.isEnabled }, set: login.set))
                if login.needsApproval {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("settings.launchAtLogin.approval"))
                        Button(L("settings.openLoginItems")) { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                if login.failed {
                    Label(L("settings.launchAtLogin.error"), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Picker(L("settings.language"), selection: $language) {
                    Text(L("settings.language.system")).tag(AppLanguage.system.rawValue)
                    Text(L("settings.language.en")).tag(AppLanguage.en.rawValue)
                    Text(L("settings.language.fr")).tag(AppLanguage.fr.rawValue)
                }
                if Self.showWakeSetting {
                    // Task 18: Toggle(L("settings.wakeMac")) + Text(L("settings.wakeMac.warning")).
                }
            }
            Section {
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }
}
