import Foundation

/// When XSide looks for new releases of the apps and tweaks that have a GitHub update source. The
/// cadence is a setting (per app, else the global default); `lastCheckedAt` is kept per source.
public struct UpdateSchedule: Sendable {
    /// The global default when nothing is set (and the value a fresh install starts with).
    public static let interval: TimeInterval = 86_400
    /// A check cadence floor: GitHub's unauthenticated API is rate-limited, so even a custom value
    /// is never run more often than this.
    public static let minimumInterval: TimeInterval = 900 // 15 min

    /// After a pass where every source failed (offline, rate limited): not tried again before this.
    public static let failureInterval: TimeInterval = 3_600

    /// `nil` interval = the global default; `<= 0` = never (manual checks only). Anything positive is
    /// clamped up to `minimumInterval`.
    public static func effectiveInterval(_ perApp: TimeInterval?, default globalDefault: TimeInterval) -> TimeInterval {
        let base = perApp ?? globalDefault // nil per-app follows the global default (which may be « never »)
        guard base > 0 else { return 0 } // never
        return max(base, minimumInterval)
    }

    /// Due when never checked, when `interval` has passed, or when the clock went back. `interval <= 0`
    /// (never) is never due from the background pass.
    public static func isDue(lastChecked: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard interval > 0 else { return false }
        guard let lastChecked, lastChecked <= now else { return true }
        return now.timeIntervalSince(lastChecked) >= interval
    }

    /// The daily-cadence form kept for the global failure back-off gate (whole pass).
    public static func isDue(lastChecked: Date?, now: Date) -> Bool {
        isDue(lastChecked: lastChecked, interval: interval, now: now)
    }

    /// Same, and a pass that failed entirely at `lastFailure` waits `failureInterval` before the
    /// next try (retry soon, but not at every tick).
    public static func isDue(lastChecked: Date?, lastFailure: Date?, now: Date) -> Bool {
        guard isDue(lastChecked: lastChecked, now: now) else { return false }
        guard let lastFailure, lastFailure <= now else { return true }
        return now.timeIntervalSince(lastFailure) >= failureInterval
    }
}
