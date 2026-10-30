import SwiftUI

/// Layout shared by every step: hero, title, subtitle, then the step's own content.
struct JourneyPage<Hero: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let hero: Hero
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            hero.padding(.bottom, 14)
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.top, 8)
            content
                .frame(maxWidth: 420)
                .padding(.top, 18)
        }
        .padding(.horizontal, 40)
        .padding(.top, 14)
        // Top-aligned: the hero stays put while the status card below changes size.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension JourneyPage where Hero == JourneySymbol {
    init(symbol: String, title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, hero: { JourneySymbol(name: symbol) }, content: content)
    }
}

/// The step's SF Symbol on a brand-gradient tile.
struct JourneySymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white)
            .symbolRenderingMode(.hierarchical)
            .frame(width: 64, height: 64)
            .background(Theme.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: Theme.violet.opacity(0.3), radius: 10, y: 4)
    }
}

/// The detected state of a step: checking (spinner), done (green check) or to do (orange).
enum JourneyStatus {
    case checking, done, todo
}

/// A rounded card with the step's status, a title, an optional detail and a trailing action.
struct StatusCard<Accessory: View>: View {
    let status: JourneyStatus
    let title: String
    var detail: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            // Buttons keep their full label: the text on the left wraps instead.
            accessory.fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .animation(.smooth, value: status)
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white, Theme.reachable)
                .transition(.scale.combined(with: .opacity))
        case .todo:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white, .orange)
        }
    }
}

extension StatusCard where Accessory == EmptyView {
    init(status: JourneyStatus, title: String, detail: String? = nil) {
        self.init(status: status, title: title, detail: detail) { EmptyView() }
    }
}

/// A bullet with an SF Symbol (welcome and ready steps).
struct FeatureRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.brand)
                .frame(width: 26)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One idea of an explainer step: an icon tile, a title and two or three short lines.
struct ConceptCard: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 40, height: 40)
                .background(Theme.violet.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

/// "1  Xcode > Settings (⌘,)": a numbered instruction.
struct NumberedRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Theme.brand, in: Circle())
            Text(text)
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "XSide detects it automatically…" with a spinner while a probe runs, and "Check again".
struct AutoDetectFooter: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text(L("onboarding.autoDetect"))
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
            Button(L("onboarding.recheck"), action: model.recheckEnvironment)
                .buttonStyle(.link)
                .font(.system(size: 11.5))
                .disabled(model.isProbing)
        }
    }
}

/// One dot per step; the current one stretches into a gradient capsule.
struct ProgressDots: View {
    let current: JourneyStep

    var body: some View {
        HStack(spacing: 7) {
            ForEach(JourneyStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == current ? AnyShapeStyle(Theme.brand)
                          : AnyShapeStyle(Color.primary.opacity(step < current ? 0.35 : 0.12)))
                    .frame(width: step == current ? 22 : 7, height: 7)
            }
        }
        .animation(.smooth(duration: 0.35), value: current)
        .accessibilityElement()
        .accessibilityLabel(L("journey.progress", current.rawValue + 1, JourneyStep.allCases.count))
    }
}

/// Quiet text button of the footer ("Back", "Skip").
struct JourneyTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        JourneyTextButtonLabel(configuration: configuration)
    }
}

private struct JourneyTextButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isHovering ? .primary : .secondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Theme.hoverFill : .clear))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}
