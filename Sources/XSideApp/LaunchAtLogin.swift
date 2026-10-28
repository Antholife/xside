import Observation
import ServiceManagement
import SwiftUI

/// Launch-at-login state, backed by `SMAppService.mainApp` (the source of truth: the user can also
/// change it in System Settings > General > Login Items). Shared by Settings and the welcome journey.
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

    /// Enables launch at login on the very first launch only (so it is on by default, journey
    /// seen or not): a user who turns it off later is never overridden. Needs a real app bundle
    /// (no-op under `swift run`).
    static func applyDefaultOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultAppliedKey),
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        defaults.set(true, forKey: defaultAppliedKey)
        try? SMAppService.mainApp.register()
    }
}

/// "Approval needed…" and error lines under a launch-at-login switch.
struct LaunchAtLoginNotes: View {
    let login: LaunchAtLogin

    var body: some View {
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
    }
}
