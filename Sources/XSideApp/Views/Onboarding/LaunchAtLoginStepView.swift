import AppKit
import SwiftUI

/// Step 5 (optional): launch at login, on by default (`LaunchAtLogin.applyDefaultOnFirstLaunch`).
struct LaunchAtLoginStepView: View {
    let login: LaunchAtLogin

    var body: some View {
        JourneyPage(symbol: "power", title: L("journey.login.title"), subtitle: L("journey.login.subtitle")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 24)
                    Text(L("settings.launchAtLogin")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Toggle(L("settings.launchAtLogin"), isOn: Binding(get: { login.isEnabled }, set: login.set))
                        .toggleStyle(.switch)
                        .tint(Theme.violet)
                        .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                LaunchAtLoginNotes(login: login)
            }
        }
        .onAppear(perform: login.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }
}
