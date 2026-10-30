import SwiftUI
import XSideCore

/// Device header card: status dot (green when reachable over USB or Wi-Fi, grey when out of range),
/// name, model and transport.
struct DeviceCard: View {
    let name: String
    let detail: String
    let symbolName: String
    let isReachable: Bool
    let wifiRefresh: Bool
    let canRemove: Bool
    let onWifiRefresh: @MainActor @Sendable (Bool) -> Void
    let onRemove: () -> Void


    init(group: DeviceGroup, onWifiRefresh: @escaping @MainActor @Sendable (Bool) -> Void, onRemove: @escaping () -> Void) {
        wifiRefresh = group.wifiRefresh
        canRemove = group.canRemove
        self.onWifiRefresh = onWifiRefresh
        self.onRemove = onRemove
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
                .accessibilityHidden(true)
            Menu {
                Toggle(L("popover.device.wifiRefresh"), isOn: Binding(get: { wifiRefresh }, set: onWifiRefresh))
                Divider()
                // Confirmed by the caller, once the popover is closed: an alert inside it would
                // close along with it.
                Button(L("popover.device.remove"), role: .destructive, action: onRemove)
                    .disabled(!canRemove)
                if !canRemove { Text(L("popover.device.removeBusy")) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L("popover.device.menu"))
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
