import Foundation

/// Safety nets for when XSide can't refresh an app in time (not running, device away): a
/// reminder scheduled with the system, the menu-bar badge and the quit warning.
public enum ExpiryWatch {
    /// The reminder fires this long before expiry.
    public static let reminderLead: TimeInterval = 24 * 3600
    /// A quit is confirmed while an app expires within this delay (a free-account app's lifetime).
    public static let quitWarningWindow: TimeInterval = 7 * 86_400

    /// Identifier of the scheduled reminder of one installation (one per app and device).
    public static func reminderID(recordID: UUID, deviceID: String) -> String {
        "expiry.\(recordID.uuidString).\(deviceID)"
    }

    public static let reminderPrefix = "expiry."

    /// When the reminder of an installation expiring at `expiresAt` fires: 24 h before, nil when
    /// that moment is already past.
    public static func reminderDate(expiresAt: Date, now: Date) -> Date? {
        let date = expiresAt.addingTimeInterval(-reminderLead)
        return date > now ? date : nil
    }

    /// An expired installation XSide still refreshes (paused ones don't count): the badge turns critical.
    public static func hasExpired(_ records: [AppRecord], now: Date) -> Bool {
        records.contains { $0.installations.contains { !$0.refreshPaused && $0.expiresAt <= now } }
    }

    /// Something the user should look at: an expired app, an app within the refresh threshold
    /// whose last attempt failed. Paused installations don't count: the user chose to let them expire.
    public static func needsAttention(_ records: [AppRecord], now: Date, threshold: TimeInterval) -> Bool {
        records.contains { record in
            record.installations.contains { installation in
                guard !installation.refreshPaused else { return false }
                return installation.expiresAt <= now
                    || (installation.lastErrorKey != nil && installation.expiresAt.timeIntervalSince(now) <= threshold)
            }
        }
    }

    /// True when an installed app is still valid and expires within `quitWarningWindow`: quitting
    /// would stop its refresh. A paused one isn't refreshed anyway.
    public static func quitStopsRefreshes(_ records: [AppRecord], now: Date) -> Bool {
        records.contains { record in
            record.installations.contains { installation in
                guard !installation.refreshPaused else { return false }
                let left = installation.expiresAt.timeIntervalSince(now)
                return left > 0 && left <= quitWarningWindow
            }
        }
    }
}
