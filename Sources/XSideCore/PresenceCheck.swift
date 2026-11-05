import Foundation

/// Finds the apps deleted from a device behind XSide's back (home screen), so they are forgotten
/// there instead of reinstalled by the next refresh.
public enum PresenceCheck {
    /// How often a reachable device's app list is read.
    public static let interval: TimeInterval = 3600

    /// Available devices holding at least one XSide app, not checked within `interval`, in
    /// `devices` order.
    public static func devicesToCheck(_ devices: [Device], records: [AppRecord],
                                      lastChecked: [String: Date], now: Date) -> [String] {
        let withApps = Set(records.flatMap { $0.installations.map(\.deviceID) })
        return devices.filter { d in
            d.isAvailable && withApps.contains(d.id)
                && lastChecked[d.id].map { now.timeIntervalSince($0) >= interval } ?? true
        }.map(\.id)
    }

    /// Installations on `deviceID` whose app (the bundle id that device was signed with) isn't in
    /// `installed`, the list read at `queriedAt`. One installed since then is kept: the list may
    /// predate it.
    public static func missing(_ records: [AppRecord], deviceID: String, installed: Set<String>,
                               queriedAt: Date) -> [RefreshJob] {
        records.flatMap { record in
            record.installations
                .filter { i in
                    i.deviceID == deviceID && i.installedAt < queriedAt
                        && !installed.contains(i.signedBundleID ?? record.signedBundleID)
                }
                .map { _ in RefreshJob(recordID: record.id, deviceID: deviceID) }
        }
    }
}
