import Foundation

public enum AppIDCounter {
    /// Estimates remaining App IDs: distinct non-wildcard bundle IDs of the team whose
    /// oldest profile was created within `window` count against `limit`.
    public static func remaining(_ profiles: [ProvisioningProfile], teamID: String, now: Date,
                                 limit: Int = 10, window: TimeInterval = 7 * 86_400) -> Int {
        var oldest: [String: Date] = [:]
        for p in profiles where p.teamID == teamID && p.bundleID != "*" {
            if let d = oldest[p.bundleID], d <= p.creationDate { continue }
            oldest[p.bundleID] = p.creationDate
        }
        let used = oldest.values.filter { now.timeIntervalSince($0) < window }.count
        return max(0, limit - used)
    }
}
