import SwiftUI

/// The first-pairing helper: a never-paired device isn't visible over Wi-Fi, so the first
/// connection must be over USB. Shown inline in the install window.
struct NewDeviceHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("install.newDevice.intro"))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            NumberedRow(number: 1, text: L("install.newDevice.step1"))
            NumberedRow(number: 2, text: L("install.newDevice.step2"))
            NumberedRow(number: 3, text: L("install.newDevice.step3"))
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L("install.newDevice.waiting"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
