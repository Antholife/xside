import SwiftUI
import XSideCore

/// Under an option of Settings > Mes apps that only applies when the app is signed again, while
/// its stored choice differs from what the installed copy has: says the change waits for the next
/// refresh on that device, with a button to refresh now. Gone once a refresh installs the new state
/// (`Installation.pendingSigningChanges`).
struct PendingChangeNotice: View {
    let deviceName: String
    var isDisabled = false
    let refreshNow: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .accessibilityHidden(true)
            Text(L("pending.line", deviceName))
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L("pending.refreshNow"), action: refreshNow)
                .controlSize(.small)
                .disabled(isDisabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .systemOrange).opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }
}
