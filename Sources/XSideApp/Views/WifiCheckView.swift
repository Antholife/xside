import SwiftUI
import XSideCore

/// Last step of a first USB install: unplug the cable and check the device answers over Wi-Fi.
/// Polls the device list only while it is on screen.
struct WifiCheckView: View {
    let model: AppModel
    let flow: InstallFlow
    let check: WifiCheck
    /// Shown above the step when several devices were installed (one check each, in turn).
    var deviceName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let deviceName {
                Text(deviceName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            switch check.status {
            case .waitingForUnplug:
                Label(L("wifi.title"), systemImage: "cable.connector.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.violet)
                Text(L("wifi.unplug")).font(.system(size: 12))
                if check.needsNudge {
                    Text(L("wifi.nudge")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(L("wifi.skip")) { model.skipWifiCheck(flow) }
                }
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("wifi.checking")).font(.system(size: 12, weight: .medium))
                }
                HStack {
                    Spacer()
                    Button(L("wifi.skip")) { model.skipWifiCheck(flow) }
                }
            case .failed, .ok:
                Label(L("wifi.failed.title"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                VStack(alignment: .leading, spacing: 4) {
                    bullet(L("wifi.failed.sameNetwork"))
                    bullet(L("wifi.failed.isolation"))
                    bullet(L("wifi.failed.unlocked"))
                }
                HStack {
                    Spacer()
                    Button(L("wifi.useUSB")) { model.chooseUSBRefresh(flow) }
                    Button(L("wifi.retry")) { model.retryWifiCheck(flow) }
                        .buttonStyle(GradientButtonStyle())
                        .frame(width: 110)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Visibility-gated: the task ends with the view, and restarts when the step changes.
        .task(id: check.status == .failed ? 0 : 1) {
            guard check.status != .failed else { return }
            model.evaluateWifiCheck(flow)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await model.pollWifiCheck(flow)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
    }
}
