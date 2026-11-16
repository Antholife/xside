import Foundation

/// When XSide looks for new releases of the apps and tweaks that have a GitHub update source:
/// once a day. Kept in memory (a restart just looks again).
public struct UpdateSchedule: Sendable {
    public static let interval: TimeInterval = 86_400

    /// Due when never checked, when `interval` has passed, or when the clock went back.
    public static func isDue(lastChecked: Date?, now: Date) -> Bool {
        guard let lastChecked, lastChecked <= now else { return true }
        return now.timeIntervalSince(lastChecked) >= interval
    }
}
