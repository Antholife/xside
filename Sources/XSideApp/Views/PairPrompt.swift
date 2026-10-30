import SwiftUI
import XSideCore

/// A device CoreDevice discovered but that isn't paired yet: "New device found — Pair?".
struct PairPrompt: View {
    let device: Device
    let isPairing: Bool
    let error: String?
    let onPair: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: device.symbolName)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("popover.newDevice"))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(isPairing ? L("popover.pairing") : device.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isPairing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L("popover.pair"), action: onPair)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.violet)
                        .controlSize(.small)
                }
            }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.violet.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
