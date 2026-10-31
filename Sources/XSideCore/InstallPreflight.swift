import Foundation

/// What can be told before an install starts, instead of after it fails: an iOS too old for the
/// app, no App ID left this week, a device already holding its 3 apps. Warnings only: Apple
/// decides in the end (the App ID count is an estimate, apps installed outside XSide aren't known).
public enum InstallPreflight {
    /// Free accounts run at most 3 sideloaded apps per device.
    public static let appsPerDevice = 3

    public struct Target: Sendable {
        public let deviceID: String
        public let osVersion: String?
        /// Names of the other apps XSide installed there (this one excluded).
        public let otherApps: [String]
        /// This app is already there: reinstalling doesn't take a new slot.
        public let hasThisApp: Bool

        public init(deviceID: String, osVersion: String?, otherApps: [String], hasThisApp: Bool) {
            self.deviceID = deviceID
            self.osVersion = osVersion
            self.otherApps = otherApps
            self.hasThisApp = hasThisApp
        }
    }

    public enum Warning: Equatable, Sendable {
        /// The device runs an iOS older than the app needs.
        case iOSTooOld(deviceID: String, required: String, actual: String)
        /// Already 3 XSide apps on the device: one has to go first.
        case deviceFull(deviceID: String, apps: [String])
        /// The new App ID this install needs isn't left this week (estimate).
        case noAppIDLeft
        /// The last App ID of the week.
        case lastAppID
    }

    /// `needsNewAppID`: the signed bundle id isn't registered yet (a first install, or a new id).
    public static func check(minimumOS: String?, targets: [Target], needsNewAppID: Bool,
                             appIDsRemaining: Int?) -> [Warning] {
        var warnings: [Warning] = []
        for target in targets {
            if let minimumOS, let os = target.osVersion, compare(os, minimumOS) == .orderedAscending {
                warnings.append(.iOSTooOld(deviceID: target.deviceID, required: minimumOS, actual: os))
            }
            if !target.hasThisApp, target.otherApps.count >= appsPerDevice {
                warnings.append(.deviceFull(deviceID: target.deviceID, apps: target.otherApps))
            }
        }
        if needsNewAppID, let left = appIDsRemaining {
            if left <= 0 { warnings.append(.noAppIDLeft) } else if left == 1 { warnings.append(.lastAppID) }
        }
        return warnings
    }

    /// Numeric comparison of dotted versions ("17.4" < "17.10", "18" == "18.0").
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
