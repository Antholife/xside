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

    /// How long before expiry the app's own reminder fires: half the refresh window, at most a
    /// day, so it only shows when the refresh that should have happened didn't.
    public static func reminderLead(threshold: TimeInterval) -> TimeInterval {
        min(24 * 3600, threshold / 2)
    }

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

    /// `certificateChanged`: signed with a replaced or revoked certificate, so it may stop
    /// launching any time: never held back either.
    public func allows(expiresAt: Date, now: Date, certificateChanged: Bool = false, calendar: Calendar = .current) -> Bool {
        if certificateChanged || expiresAt.timeIntervalSince(now) <= Self.urgent { return true }
        if let pausedUntil, now < pausedUntil { return false }
        if acOnly, onBattery { return false }
        if let preferredHours, !preferredHours.range.contains(calendar.component(.hour, from: now)) { return false }
        return true
    }
}

/// How often the background engine lists devices: every tick (15 s) while the person is looking
/// at them, in the panel or in Settings > Mes apps (where a failed refresh's « Réessayer » waits
/// for the device to be back), every minute otherwise.
public enum DevicePolling {
    public static let fast: Duration = .seconds(15)
    public static let slow: Duration = .seconds(60)

    public static func interval(panelOpen: Bool, myAppsShown: Bool) -> Duration {
        panelOpen || myAppsShown ? fast : slow
    }
}
