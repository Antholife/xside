import SwiftUI

/// Shown after the first successful install on a device: stay unlocked, trust the developer,
/// and enable Developer Mode when the device reports it off.
struct FirstInstallGuideView: View {
    let guide: FirstInstallGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("guide.title"), systemImage: "hand.raised.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.violet)
            step(1, symbol: "lock.open", L("guide.unlock"))
            step(2, symbol: "checkmark.shield", L("guide.trust", guide.accountName))
            if guide.needsDeveloperMode {
                step(3, symbol: "hammer", L("guide.developerMode"))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func step(_ n: Int, symbol: String, _ text: String) -> some View {
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
