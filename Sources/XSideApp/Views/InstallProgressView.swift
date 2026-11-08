import SwiftUI
import XSideCore

/// Step-by-step progress: an overall bar that advances one segment per finished step, and the
/// list of steps (done, current, waiting, failed, upcoming). A failed step shows `failureMessage`.
struct InstallProgressView: View {
    let timeline: StepTimeline
    var failureMessage: String?
    /// The bar above the steps; off when a progress ring already shows it (install window header).
    var showsBar = true
    /// The running step's percentage, when its tool reports one: shown on its row.
    var activePercent: Int?
    /// When the running step started: without a percentage, the time spent shows instead.
    var activeSince: Date?
    /// The app goes without XSide's features: the module step says it's skipped.
    var withoutXSideFeatures = false
    /// The app is deleted from the device before it's installed (the module goes, opted in): the
    /// install step says so.
    var deletesFirst = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsBar {
                ProgressView(value: Double(timeline.completedCount), total: Double(max(timeline.total, 1)))
                    .progressViewStyle(.linear)
                    .tint(timeline.isFailed ? Color(nsColor: .systemRed) : Theme.violet)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(timeline.steps, id: \.self) { step in
                    row(step)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.smooth(duration: 0.3), value: timeline)
    }

    private func row(_ step: ProgressStep) -> some View {
        let status = timeline.status(of: step)
        let index = (timeline.steps.firstIndex(of: step) ?? 0) + 1
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                indicator(status)
                    .frame(width: 16, height: 16)
                Text(step.label(withoutXSideFeatures: withoutXSideFeatures, deletesFirst: deletesFirst))
                    .font(.system(size: 13, weight: status == .active || status == .waiting || status == .failed ? .semibold : .regular))
                    .foregroundStyle(titleStyle(status))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                if status == .waiting {
                    Text(L("install.step.waiting") + "…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if status == .active, activePercent == nil, let activeSince {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Duration.seconds(max(0, context.date.timeIntervalSince(activeSince)))
                            .formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if status == .active, let activePercent {
                    Text(percentText(activePercent))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.brand)
                        .contentTransition(.numericText())
                }
            }
            if status == .active, let activePercent {
                ProgressView(value: Double(activePercent), total: 100)
                    .progressViewStyle(.linear)
                    .tint(Theme.violet)
                    .controlSize(.mini)
                    .padding(.leading, 24)
                    .animation(.smooth(duration: 0.4), value: activePercent)
            }
            // What "XSide features" means, once that step has started.
            if step == .welcome, !withoutXSideFeatures, status == .active || status == .done {
                XSideFeaturesList()
                    .padding(.leading, 24)
                    .padding(.top, 3)
            }
            if status == .failed, let failureMessage {
                Text(failureMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("install.progress.accessibility", index, timeline.total,
                              step.label(withoutXSideFeatures: withoutXSideFeatures, deletesFirst: deletesFirst), status.label))
    }

    private func titleStyle(_ status: StepStatus) -> HierarchicalShapeStyle {
        status == .pending || status == .skipped ? .secondary : .primary
    }

    @ViewBuilder private func indicator(_ status: StepStatus) -> some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
        case .active:
            ActiveDot()
        case .waiting:
            Image(systemName: "clock.fill")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Color(nsColor: .systemRed))
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        }
    }
}

/// Under the "Injecting the XSide module" step, what it really does (device feedback round 2,
/// M4): what this step writes into the app now, then what the module does in the app once it's
/// opened (quick actions and notifications are set up there, at run time, not at install).
private struct XSideFeaturesList: View {
    private static let now: [(symbol: String, key: String)] = [
        ("puzzlepiece.extension.fill", "install.feature.module"),
        ("gearshape.fill", "install.feature.settings"),
        ("wifi", "install.feature.network"),
    ]
    private static let atLaunch: [(symbol: String, key: String)] = [
        ("rectangle.portrait.bottomhalf.inset.filled", "install.feature.sheet"),
        ("rectangle.topthird.inset.filled", "install.feature.pill"),
        ("rectangle.bottomthird.inset.filled", "install.feature.banner"),
        ("bell.badge.fill", "install.feature.reminder"),
        ("hand.tap.fill", "install.feature.quick"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            group(L("install.feature.title"), Self.now)
            group(L("install.feature.atLaunch"), Self.atLaunch)
                .padding(.top, 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.violet.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.violet.opacity(0.18)))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func group(_ title: String, _ items: [(symbol: String, key: String)]) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
        ForEach(items, id: \.key) { item in
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 22, height: 22)
                    .background(Theme.violet.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(L(item.key))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The step running now: a brand dot in a softly pulsing halo.
private struct ActiveDot: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Theme.brand)
            .frame(width: 10, height: 10)
            .background(Circle().fill(Theme.violet.opacity(0.3)).scaleEffect(pulse ? 1.8 : 1.2))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = !reduceMotion }
    }
}

extension ProgressStep {
    var label: String {
        switch self {
        case .preparing: L("install.step.preparing")
        case .profile: L("install.step.profile")
        case .welcome: L("install.step.welcome")
        case .signing: L("install.step.signing")
        case .installing: L("install.step.installing")
        case .wifiCheck: L("wifi.title")
        }
    }

    /// The module step says it's skipped when the app goes without XSide's features; the install
    /// step says when the app is deleted from the device first.
    func label(withoutXSideFeatures: Bool, deletesFirst: Bool = false) -> String {
        if self == .welcome && withoutXSideFeatures { return L("install.step.welcomeSkipped") }
        if self == .installing && deletesFirst { return L("install.step.deleteThenInstall") }
        return label
    }
}

extension StepStatus {
    var label: String {
        switch self {
        case .done: L("install.status.done")
        case .active: L("install.status.active")
        case .waiting: L("install.status.waiting")
        case .failed: L("install.status.failed")
        case .pending: L("install.status.pending")
        case .skipped: L("install.status.skipped")
        }
    }
}

extension JobStage {
    /// Name of the stage, as in the step list (no ellipsis).
    var label: String {
        switch self {
        case .preparing: L("install.step.preparing")
        case .waiting: L("install.step.waiting")
        case .step(let s): ProgressStep(s).label
        }
    }

    /// Compact text for the popover row, with its ellipsis.
    var rowText: String {
        switch self {
        case .preparing: L("install.step.preparing") + "…"
        case .waiting: L("install.step.waiting") + "…"
        case .step(let s): ProgressStep(s).label + "…"
        }
    }
}
