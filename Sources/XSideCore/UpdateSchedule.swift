import Foundation

/// When XSide looks for new releases of the apps and tweaks that have a GitHub update source:
/// once a day. Kept in memory (a restart just looks again).
public struct UpdateSchedule: Sendable {
    public static let interval: TimeInterval = 86_400

    /// After a pass where every source failed (offline, rate limited): not tried again before this.
    public static let failureInterval: TimeInterval = 3_600

    /// Due when never checked, when `interval` has passed, or when the clock went back.
    public static func isDue(lastChecked: Date?, now: Date) -> Bool {
        guard let lastChecked, lastChecked <= now else { return true }
        return now.timeIntervalSince(lastChecked) >= interval
    }

    /// Same, and a pass that failed entirely at `lastFailure` waits `failureInterval` before the
    /// next try (retry soon, but not at every tick).
    public static func isDue(lastChecked: Date?, lastFailure: Date?, now: Date) -> Bool {
        guard isDue(lastChecked: lastChecked, now: now) else { return false }
        guard let lastFailure, lastFailure <= now else { return true }
        return now.timeIntervalSince(lastFailure) >= failureInterval
    }
}
