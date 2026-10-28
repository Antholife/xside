import SwiftUI
import XSideCore

/// Step 6 (optional): connect the iPhone; the list updates live while the step is on screen.
struct DeviceStepView: View {
    let model: AppModel

    private var developerModeOff: Device? { model.devices.first { $0.developerModeEnabled == false } }

    var body: some View {
        JourneyPage(symbol: "iphone.gen3", title: L("journey.device.title"), subtitle: L("journey.device.subtitle")) {
            VStack(spacing: 12) {
                if model.devices.isEmpty {
                    StatusCard(status: .checking, title: L("journey.device.searching"),
                               detail: L("journey.device.searching.detail"))
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(model.devices) { device in
                                JourneyDeviceRow(device: device, isPairing: model.pairing.contains(device.id),
                                                 error: model.pairErrors[device.id]) { model.pair(device) }
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 132)
                }
                if let device = developerModeOff {
                    Label(L("journey.device.developerMode", device.name), systemImage: "hammer")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .animation(.smooth, value: model.devices)
        }
        // Visibility-gated: lists devices every 5 s only while this step is shown in a visible window.
        .task(id: model.isOnboardingWindowOpen) {
            guard model.isOnboardingWindowOpen else { return }
            while !Task.isCancelled {
                await model.listDevices()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

private struct JourneyDeviceRow: View {
    let device: Device
    let isPairing: Bool
    let error: String?
    let onPair: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: device.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(device.isAvailable ? Theme.reachable : Theme.unreachable)
                            .frame(width: 6, height: 6)
                        Text(device.transportLabel)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !device.isPaired {
                    if isPairing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L("popover.pair"), action: onPair)
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.violet)
                    }
                } else if device.isAvailable {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, Theme.reachable)
                }
            }
            if isPairing || error != nil {
                Text(error ?? L("popover.pairing"))
                    .font(.system(size: 11))
                    .foregroundStyle(error == nil ? Color.secondary : Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
