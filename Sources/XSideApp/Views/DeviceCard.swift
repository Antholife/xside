import SwiftUI
import XSideCore

/// Device header card: status dot (green when reachable over USB or Wi-Fi, grey when out of range),
/// name, model and transport.
struct DeviceCard: View {
    let name: String
    let detail: String
    let symbolName: String
    let isReachable: Bool

    init(group: DeviceGroup) {
        name = group.name
        symbolName = group.device?.symbolName ?? "iphone"
        isReachable = group.device?.isAvailable ?? false
        let transport = group.device?.transportLabel ?? L("popover.transport.unreachable")
        let model = group.device?.model ?? ""
        detail = model.isEmpty ? transport : "\(model) · \(transport)"
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(isOn: isReachable)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: symbolName)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct StatusDot: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .fill(isOn ? Theme.reachable : Theme.unreachable)
            .frame(width: 8, height: 8)
            .shadow(color: isOn ? Theme.reachable.opacity(0.8) : .clear, radius: 3)
    }
}
