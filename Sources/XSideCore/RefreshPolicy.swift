import Foundation

/// When automatic refreshes may start (Settings): paused until a date, only on AC power, only at
/// preferred hours. Never at the cost of an app: one expiring within `urgent` goes anyway. Manual
/// refreshes don't ask.
public struct RefreshPolicy: Sendable, Equatable {
    public enum Hours: String, Sendable, CaseIterable {
        /// 1:00 – 5:59.
        case night
        /// 19:00 – 22:59.
        case evening

        public var range: ClosedRange<Int> {
            switch self {
            case .night: 1...5
            case .evening: 19...22
            }
        }
    }

    public static let urgent: TimeInterval = 12 * 3600

    public var pausedUntil: Date?
    public var acOnly: Bool
    public var onBattery: Bool
    public var preferredHours: Hours?

    public init(pausedUntil: Date? = nil, acOnly: Bool = false, onBattery: Bool = false, preferredHours: Hours? = nil) {
        self.pausedUntil = pausedUntil
        self.acOnly = acOnly
        self.onBattery = onBattery
        self.preferredHours = preferredHours
    }

    public func allows(expiresAt: Date, now: Date, calendar: Calendar = .current) -> Bool {
        if expiresAt.timeIntervalSince(now) <= Self.urgent { return true }
        if let pausedUntil, now < pausedUntil { return false }
        if acOnly, onBattery { return false }
        if let preferredHours, !preferredHours.range.contains(calendar.component(.hour, from: now)) { return false }
        return true
    }
}
