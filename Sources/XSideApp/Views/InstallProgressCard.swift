import SwiftUI
import XSideCore

/// Takes the place of "＋ Install an app" in the popover while an install runs (or once it ended
/// with something left to see and its window closed): the app, the device and step, a bar, and
/// "Cancel". Clicking the card reopens the install window on the same run.
struct InstallProgressCard: View {
    let model: AppModel
    let flow: InstallFlow
    /// Closes the popover and shows the install window.
    let open: () -> Void
    @State private var isHovering = false

    /// Shown for a running install, or a finished one with something to see while its window is closed.
    static func isShown(for flow: InstallFlow, in model: AppModel) -> Bool {
        if flow.isRunning { return true }
        guard !model.isInstallWindowOpen else { return false }
        return flow.isBusy || hasFailure(flow)
    }

    private static func hasFailure(_ flow: InstallFlow) -> Bool {
        if case .editing(let error?) = flow.phase { return !error.isEmpty }
        if case .finished = flow.phase { return !flow.failedDeviceIDs.isEmpty }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    AppGlyph(iconURL: flow.draft.iconPath.map(model.iconURL) ?? flow.appIcon, size: 34)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(L("popover.installCard.title", appName))
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if let position = devicePosition {
                                Text(position)
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Self.hasFailure(flow) ? AnyShapeStyle(Color(nsColor: .systemRed))
                                                                   : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let progress {
                            ProgressView(value: Double(progress.done) + Double(model.runPercent(flow) ?? 0) / 100,
                                         total: Double(max(progress.total, 1)))
                                .progressViewStyle(.linear)
                                .tint(Theme.violet)
                                .controlSize(.small)
                        }
                        if !model.queuedIPAs.isEmpty {
                            Text(L("popover.installCard.queued", model.queuedIPAs.count))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)

            if flow.isRunning {
                Button(L("install.cancel"), action: model.cancelInstall)
                    .controlSize(.small)
                    .disabled(flow.cancelRequested)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isHovering ? Color.primary.opacity(0.09) : Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.violet.opacity(0.35), lineWidth: 1))
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.25), value: flow.phase)
    }

    private var appName: String {
        flow.draft.options.displayName ?? flow.info?.name ?? flow.ipa.deletingPathExtension().lastPathComponent
    }

    private var steps: [ProgressStep] { ProgressStep.list(includingWifiCheck: flow.wifiStepPlanned) }

    /// The device being installed and its stage (between two devices: the run's own stage).
    private var current: (name: String?, stage: JobStage)? {
        if let current = flow.currentRun { return (current.run.name, current.stage) }
        if case .running(let stage) = flow.phase { return (nil, stage) }
        return nil
    }

    /// Steps done out of the steps of the current device; nil once the run is over.
    private var progress: (done: Int, total: Int)? {
        guard flow.isRunning, let current else { return nil }
        let timeline = StepTimeline(steps: steps, stage: current.stage)
        return (timeline.completedCount, timeline.total)
    }

    /// "1/2" with several devices.
    private var devicePosition: String? {
        guard flow.isRunning, flow.runs.count > 1, let index = flow.currentRun?.index else { return nil }
        return "\(index + 1)/\(flow.runs.count)"
    }

    /// "iPhone de Anthony · Signature" while running; the failure, Wi-Fi check or result after.
    private var detail: String {
        if flow.isRunning, let current {
            let stage = model.runPercent(flow).map { "\(current.stage.label) · \(percentText($0))" } ?? current.stage.label
            guard let name = current.name else { return stage }
            return L("popover.installCard.step", name, stage)
        }
        if Self.hasFailure(flow) { return L("popover.installCard.failed") }
        if flow.wifiCheck != nil { return L("wifi.title") }
        return L("install.run.done")
    }

    private var accessibilityLabel: String {
        let title = L("popover.installCard.title", appName)
        guard let progress else { return "\(title), \(detail)" }
        let percent = progress.done * 100 / max(progress.total, 1)
        return L("popover.installCard.accessibility", title, detail, percent)
    }
}
