import Foundation

/// What can be told before an install starts, instead of after it fails: Developer Mode off,
/// an iOS too old for the app, no App ID left this week, a device already holding its 3 apps.
/// Warnings only, except Developer Mode (Xcode refuses the device outright): Apple decides in the end (the App ID count is an estimate, apps installed outside XSide aren't known).
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
        /// From devicectl; nil when it doesn't say (then nothing is assumed).
        public let developerModeEnabled: Bool?
        /// The version of this app on the device, when it's there and known.
        public let installedVersion: String?
        /// An iPhone Duo (see `DeviceModel.isDuo`).
        public let isDuo: Bool

        public init(deviceID: String, osVersion: String?, otherApps: [String], hasThisApp: Bool,
                    developerModeEnabled: Bool? = nil, installedVersion: String? = nil, isDuo: Bool = false) {
            self.isDuo = isDuo
            self.installedVersion = installedVersion
            self.deviceID = deviceID
            self.developerModeEnabled = developerModeEnabled
            self.osVersion = osVersion
            self.otherApps = otherApps
            self.hasThisApp = hasThisApp
        }
    }

    public enum Warning: Equatable, Sendable {
        /// Developer Mode is off on the device: nothing can be installed there until it's on.
        case developerModeOff(deviceID: String)
        /// The device runs an iOS older than the app needs.
        case iOSTooOld(deviceID: String, required: String, actual: String)
        /// Already 3 XSide apps on the device: one has to go first.
        case deviceFull(deviceID: String, apps: [String])
        /// The new App ID this install needs isn't left this week (estimate).
        case noAppIDLeft
        /// The last App ID of the week.
        case lastAppID
        /// An iPhone Duo and an app built before SDK 27.1: it won't fill the Duo's screens.
        /// `optionPossible`: the install option "Add iPhone Duo compatibility" can be turned on for
        /// this app (the note then says it can help). An older SDK on any other device says
        /// nothing: the visible difference is the Duo's.
        case notMadeForDuo(deviceID: String, optionPossible: Bool)
        /// An older version than the one on the device (the wrong file?).
        case olderVersion(deviceID: String, installing: String, installed: String)
        /// The app uses iCloud, which a free account can't give it: it may crash. Said once, unless
        /// "Simulate signed-out iCloud" is on for every device. `optionOn`: on for some of them.
        case usesICloud(optionOn: Bool)
    }

    /// `needsNewAppID`: the signed bundle id isn't registered yet (a first install, or a new id).
    /// `sdkVersion` / `appVersion`: the .ipa's build SDK and version (nil: not checked).
    /// `duo`: what the .ipa supports for the iPhone Duo option (nil: not known).
    /// `icloud`: what the .ipa uses of iCloud; `paidTeam`: signed with a paid team (no note then);
    /// `iCloudSignedOutDevices`: the targets getting "Simulate signed-out iCloud".
    public static func check(minimumOS: String?, targets: [Target], needsNewAppID: Bool,
                             appIDsRemaining: Int?, sdkVersion: String? = nil, appVersion: String? = nil,
                             duo: DuoAppInfo? = nil, icloud: ICloudAppInfo? = nil, paidTeam: Bool = false,
                             iCloudSignedOutDevices: Set<String> = []) -> [Warning] {
        var warnings: [Warning] = []
        for target in targets {
            if target.developerModeEnabled == false {
                warnings.append(.developerModeOff(deviceID: target.deviceID))
                continue // the other checks wait until the device can take an app at all
            }
            if let minimumOS, let os = target.osVersion, compare(os, minimumOS) == .orderedAscending {
                warnings.append(.iOSTooOld(deviceID: target.deviceID, required: minimumOS, actual: os))
            }
            if !target.hasThisApp, target.otherApps.count >= appsPerDevice {
                warnings.append(.deviceFull(deviceID: target.deviceID, apps: target.otherApps))
            }
            if target.isDuo, let sdk = sdkVersion, !DuoCompatibility.supportsDuo(sdk: sdk) {
                let possible = DuoCompatibility.optionState(isDuo: true, app: duo).canTurnOn
                warnings.append(.notMadeForDuo(deviceID: target.deviceID, optionPossible: possible))
            }
            if let appVersion, let installed = target.installedVersion, compare(appVersion, installed) == .orderedAscending {
                warnings.append(.olderVersion(deviceID: target.deviceID, installing: appVersion, installed: installed))
            }
        }
        let ready = targets.filter { $0.developerModeEnabled != false }.map(\.deviceID)
        if icloud?.usesICloud == true, !paidTeam, !ready.isEmpty {
            let on = ready.filter(iCloudSignedOutDevices.contains)
            if on.count < ready.count { warnings.append(.usesICloud(optionOn: !on.isEmpty)) }
        }
        if needsNewAppID, let left = appIDsRemaining {
            if left <= 0 { warnings.append(.noAppIDLeft) } else if left == 1 { warnings.append(.lastAppID) }
        }
        return warnings
    }

    /// Numeric comparison of dotted versions ("17.4" < "17.10", "18" == "18.0").
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        // The leading digits of each part: "1.10a" is 1.10, "04" is 4.
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
