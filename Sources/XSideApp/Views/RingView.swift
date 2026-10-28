import SwiftUI
import XSideCore

/// Remaining validity of a signed app at a given moment.
struct Validity {
    static let lifetime: TimeInterval = 7 * 86_400

    let remaining: TimeInterval
    let expiresAt: Date

    init(expiresAt: Date, now: Date) {
        self.expiresAt = expiresAt
        remaining = expiresAt.timeIntervalSince(now)
    }

    var fraction: Double { min(max(remaining / Self.lifetime, 0), 1) }
    var isExpired: Bool { remaining <= 0 }
    /// Whole days left, rounded up (a fresh install reads 7).
    var daysLeft: Int { Int((remaining / 86_400).rounded(.up)) }

    /// "Expires in 5 d" / "Expires today" / "Expired".
    var spokenText: String {
        if isExpired { return L("popover.expired") }
        if Calendar.current.isDateInToday(expiresAt) { return L("popover.expires.today") }
        return L("popover.expires.days", daysLeft)
    }
}

/// Conic ring that empties until expiry, with the days left in the center.
struct RingView: View {
    let validity: Validity
    var isBusy = false

    private let size: CGFloat = 34
    private let line: CGFloat = 3.5

    private var colors: [Color] {
        if validity.remaining > RefreshPlanner.threshold { return [Theme.violet, Theme.pink] }
        if validity.remaining > 86_400 { return [Color(nsColor: .systemOrange), Color(nsColor: .systemYellow)] }
        return [Color(nsColor: .systemRed), Color(nsColor: .systemPink)]
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.09), lineWidth: line)
            Circle()
                .trim(from: 0, to: validity.fraction)
                .stroke(AngularGradient(colors: colors, center: .center,
                                        startAngle: .zero, endAngle: .degrees(360 * max(validity.fraction, 0.01))),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(isBusy ? 0.35 : 1)
                .animation(.smooth, value: validity.fraction)
            center
        }
        .frame(width: size, height: size)
        .help(validity.spokenText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(validity.spokenText)
    }

    @ViewBuilder private var center: some View {
        if isBusy {
            ProgressView().controlSize(.small)
        } else if validity.isExpired {
            Image(systemName: "exclamationmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemRed))
        } else {
            Text(L("popover.ring.days", validity.daysLeft))
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }
}
