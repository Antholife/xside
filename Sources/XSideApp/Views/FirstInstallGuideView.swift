import SwiftUI

/// Shown after the first successful install on a device: what to set on the device before the
/// app opens (Developer Mode when the device reports it off, then trust the developer).
struct FirstInstallGuideView: View {
    let guide: FirstInstallGuide
    /// Named in the title when several devices were installed (one guide each).
    var deviceName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(deviceName.map { L("guide.titleDevice", $0) } ?? L("guide.title"), systemImage: "hand.raised.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.violet)
            Text(L("guide.unlock"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Developer Mode first: turning it on restarts the device.
            if guide.needsDeveloperMode {
                step(1, L("guide.developerMode"))
            }
            step(guide.needsDeveloperMode ? 2 : 1, L("guide.trust", guide.accountName))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Theme.brand, in: Circle())
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
