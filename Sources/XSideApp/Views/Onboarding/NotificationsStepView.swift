import AppKit
import SwiftUI

/// Step 4 (optional): why notifications matter, and the real authorization state.
struct NotificationsStepView: View {
    let permission: NotificationPermission
    @AppStorage(Notifier.notifyRefreshSuccessKey) private var notifyRefreshSuccess = true

    var body: some View {
        JourneyPage(symbol: "bell.badge.fill", title: L("journey.notifications.title"),
                    subtitle: L("journey.notifications.subtitle")) {
            VStack(spacing: 14) {
                NotificationPermissionCard(permission: permission)
                Toggle(L("settings.notifyRefreshSuccess"), isOn: $notifyRefreshSuccess)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
            }
        }
        .task { await permission.refresh() }
        // Back from System Settings: the user may have changed it there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permission.refresh() }
        }
    }
}

/// The authorization state with the action that fits it ("Allow" or "Open System Settings").
struct NotificationPermissionCard: View {
    let permission: NotificationPermission

    var body: some View {
        switch permission.state {
        case .checking:
            StatusCard(status: .checking, title: L("journey.notifications.checking"))
        case .unavailable:
            StatusCard(status: .todo, title: L("journey.notifications.unavailable"))
        case .authorized:
            StatusCard(status: .done, title: L("journey.notifications.done"))
        case .notDetermined:
            StatusCard(status: .todo, title: L("journey.notifications.notDetermined")) {
                Button(L("journey.notifications.allow")) { Task { await permission.request() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.violet)
            }
        case .denied:
            StatusCard(status: .todo, title: L("journey.notifications.denied"),
                       detail: L("journey.notifications.denied.detail")) {
                Button(L("journey.notifications.openSettings"), action: permission.openSystemSettings)
            }
        }
    }
}
