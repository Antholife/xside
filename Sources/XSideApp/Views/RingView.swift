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

/// Conic ring that empties until expiry, with the days left in the center. Neutral grey for a
/// paused app: its expiry is no longer urgent, the user chose to let it go.
struct RingView: View {
    let validity: Validity
    var isPaused = false
    /// A job runs on the row: a bright arc turns around the ring.
    var isBusy = false

    /// 34 on its own; smaller next to the app's icon.
    var size: CGFloat = 34
    private var line: CGFloat { size * 0.1 }

    private var colors: [Color] {
        if isPaused { return [Color.secondary, Color.secondary] }
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
            if isBusy { SpinningArc(lineWidth: line) }
            center
        }
        .frame(width: size, height: size)
        .help(validity.spokenText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(validity.spokenText)
    }

    @ViewBuilder private var center: some View {
        if validity.isExpired {
            Image(systemName: "exclamationmark")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(isPaused ? Color.secondary : Color(nsColor: .systemRed))
        } else {
            Text(L("popover.ring.days", validity.daysLeft))
                .font(.system(size: size * 0.31, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isPaused ? .secondary : .primary)
        }
    }
}

/// A short brand-colored arc going round, over the ring, while its app is being refreshed.
private struct SpinningArc: View {
    let lineWidth: CGFloat
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(AngularGradient(colors: [Theme.violet.opacity(0), Theme.violet, Theme.pink], center: .center,
                                    startAngle: .zero, endAngle: .degrees(100)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = !reduceMotion } // Reduce Motion: a still arc
    }
}
