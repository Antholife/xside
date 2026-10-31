import Foundation

public enum AppIDCounter {
    /// Estimates remaining App IDs: distinct non-wildcard bundle IDs of the team whose
    /// oldest profile was created within `window` count against `limit`.
    ///
    /// `firstUse` (signed bundle id -> first XSide install, see `firstUses`) dates XSide's own App
    /// IDs: XSide removes their cached profiles at each refresh, so the oldest cached profile would
    /// make a long-known App ID look new. The earlier of the two dates is used.
    public static func remaining(_ profiles: [ProvisioningProfile], teamID: String, now: Date,
                                 firstUse: [String: Date] = [:],
                                 limit: Int = 10, window: TimeInterval = 7 * 86_400) -> Int {
        max(0, limit - releases(profiles, teamID: teamID, now: now, firstUse: firstUse, window: window).count)
    }

    /// When each App ID counted this week frees up (its first use + `window`), soonest first:
    /// the same estimate as `remaining`, one date per App ID.
    public static func releases(_ profiles: [ProvisioningProfile], teamID: String, now: Date,
                                firstUse: [String: Date] = [:],
                                window: TimeInterval = 7 * 86_400) -> [Date] {
        var oldest: [String: Date] = [:]
        for p in profiles where p.teamID == teamID && p.bundleID != "*" {
            if let d = oldest[p.bundleID], d <= p.creationDate { continue }
            oldest[p.bundleID] = p.creationDate
        }
        for (bundleID, date) in oldest {
            if let known = firstUse[bundleID], known < date { oldest[bundleID] = known }
        }
        return oldest.values.filter { now.timeIntervalSince($0) < window }
            .map { $0.addingTimeInterval(window) }
            .sorted()
    }

    /// First XSide install per signed bundle id across `records`. Records written before this was
    /// tracked fall back to their earliest installation date.
    public static func firstUses(_ records: [AppRecord]) -> [String: Date] {
        var result: [String: Date] = [:]
        for r in records {
            var dates = r.appIDFirstUse ?? [:]
            if r.appIDFirstUse == nil, let earliest = r.installations.map(\.installedAt).min() {
                dates[r.signedBundleID] = earliest
            }
            result.merge(dates) { min($0, $1) }
        }
        return result
    }
}
