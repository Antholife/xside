import Foundation

/// Device models XSide treats specially.
public enum DeviceModel {
    /// The iPhone Duo (foldable) product types known so far. Xcode 27.3 names it just "iPhone",
    /// so the product type is what tells; a later Xcode may name it, see `isDuo`.
    public static let duoProductTypes: Set<String> = ["iPhone19,4"]

    /// An iPhone Duo: a known product type, or a name that says so.
    public static func isDuo(productType: String?, marketingName: String?) -> Bool {
        if let productType, duoProductTypes.contains(productType) { return true }
        return marketingName?.range(of: "Duo", options: .caseInsensitive) != nil
    }
}

/// What decides the "Add iPhone Duo compatibility" option for an app, read from its .ipa at import.
public struct DuoAppInfo: Codable, Equatable, Sendable {
    /// iOS SDK the main executable was built with (`LC_BUILD_VERSION`, else
    /// `LC_VERSION_MIN_IPHONEOS`, else Info.plist `DTPlatformVersion`).
    public var sdkVersion: String?
    /// The Info.plist declares a `UIApplicationSceneManifest`: the app already runs with scenes.
    public var adoptsScenes: Bool
    /// The app's own scene delegate class (runtime name), found in its main executable.
    public var sceneDelegateClass: String?

    public init(sdkVersion: String?, adoptsScenes: Bool, sceneDelegateClass: String?) {
        self.sdkVersion = sdkVersion
        self.adoptsScenes = adoptsScenes
        self.sceneDelegateClass = sceneDelegateClass
    }

    /// No scene manifest and no scene delegate of its own: the option then brings XSide's small
    /// compatibility module (`DuoCompatibility.legacyDylibName`), whose delegate the manifest names.
    public var needsLegacyModule: Bool { !adoptsScenes && sceneDelegateClass == nil }

    /// Reads the facts from the unpacked app's main executable and Info.plist. The class scan is
    /// skipped when the app needs no manifest.
    public static func read(executable: URL, plist: [String: Any]) -> DuoAppInfo {
        let sdk = MachOBuildInfo.sdkVersion(of: executable)
            ?? (plist["DTPlatformVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let adopts = plist["UIApplicationSceneManifest"] is [String: Any]
        let needsClass = !adopts && !DuoCompatibility.supportsDuo(sdk: sdk)
        return DuoAppInfo(sdkVersion: sdk, adoptsScenes: adopts,
                          sceneDelegateClass: needsClass ? ObjCClassScanner.sceneDelegateClass(in: executable) : nil)
    }
}

/// What a signing did with the iPhone Duo option it was asked for.
public enum DuoOutcome: String, Codable, Equatable, Sendable {
    /// The app now declares SDK 27.1 (and names its scene delegate when it had no manifest).
    case added
    /// The app now declares SDK 27.1 and runs with XSide's compatibility module as its scene
    /// delegate: it had no scene support of its own.
    case addedWithModule
    /// Built with SDK 27.1 or later: nothing to add.
    case alreadySupported
    /// No scene support of its own and this build lacks the compatibility module: nothing added.
    case notPossible
    /// The patch didn't work (unreadable executable, vtool failed…): installed without it.
    case failed

    /// The app got the compatibility (with or without the module).
    public var isAdded: Bool { self == .added || self == .addedWithModule }
}

/// The iPhone Duo compatibility install option. On a Duo, iOS lays an app out by the SDK it was
/// built with: before 27.0 a narrow column on black, 27.0 wider with margins, 27.1 and later the
/// full inner and outer screens. Declaring SDK 27.1 makes an older app fill them; since apps built
/// with SDK 27 must use the scene lifecycle (UIKit stops them at launch otherwise), the app also
/// gets a scene manifest naming its own scene delegate (one it ships unused, like YouTube's
/// `YTSceneDelegate`). An app with no scene support at all (no manifest, no scene delegate) gets a
/// small library of XSide's instead (`XSideDuoLegacy.dylib`, built from `App/DuoLegacy`): its
/// `XSDuoSceneDelegate` adopts the app's legacy window and forwards links, quick actions and the
/// lifecycle to the app delegate. Done at signing on the Mac, with or without XSide's module
/// (independent of it); per device.
public enum DuoCompatibility {
    /// The SDK the Duo needs for full-screen layout.
    public static let sdk = "27.1"
    public static let sdkName = "iphoneos27.1"

    /// The compatibility module for apps without scene support: its file name in the app's
    /// `Frameworks/`, the load command naming it, and the scene delegate class it provides.
    public static let legacyDylibName = "XSideDuoLegacy.dylib"
    public static let legacyLoadPath = "@executable_path/Frameworks/\(legacyDylibName)"
    public static let legacySceneDelegateClass = "XSDuoSceneDelegate"

    /// How the option makes an app (built before SDK 27.1) use scenes.
    public enum SceneSupport: Equatable, Sendable {
        /// It has a manifest: it already runs with scenes; only the SDK is raised.
        case ownManifest
        /// It ships a scene delegate it doesn't use: the new manifest names it.
        case ownSceneDelegate(String)
        /// Neither: XSide's module is added and the manifest names its delegate.
        case legacyModule
    }

    /// Nil when the app needs nothing (already built for the Duo).
    public static func sceneSupport(for app: DuoAppInfo) -> SceneSupport? {
        if supportsDuo(sdk: app.sdkVersion) { return nil }
        if app.adoptsScenes { return .ownManifest }
        if let own = app.sceneDelegateClass { return .ownSceneDelegate(own) }
        return .legacyModule
    }

    /// The delegate a new manifest names (nil: the app keeps its own manifest).
    public static func manifestDelegate(for support: SceneSupport) -> String? {
        switch support {
        case .ownManifest: nil
        case .ownSceneDelegate(let name): name
        case .legacyModule: legacySceneDelegateClass
        }
    }

    public static func supportsDuo(sdk: String?) -> Bool {
        guard let sdk else { return false }
        return InstallPreflight.compare(sdk, Self.sdk) != .orderedAscending
    }

    /// How the option shows for an app on a device.
    public enum OptionState: Equatable, Sendable {
        /// Not a Duo: offered, off, "not recommended".
        case notADuo
        /// A Duo and an app built for an older SDK: highlighted, still off until turned on.
        case recommended
        /// A Duo, but what the app supports isn't known (imported by an older XSide): offered, off.
        case unknown
        /// Built with SDK 27.1 or later: nothing to do (greyed).
        case alreadySupported
        /// The app has no scene support and this build of XSide has no compatibility module
        /// (built without the iOS SDK): not possible (greyed).
        case unavailable

        public var canTurnOn: Bool { self != .alreadySupported && self != .unavailable }
    }

    /// An app without scene support of its own is no exception: it gets XSide's module
    /// (`DuoAppInfo.needsLegacyModule` says so, for the wording), when this build has it
    /// (`legacyModuleAvailable`).
    public static func optionState(isDuo: Bool, app: DuoAppInfo?, legacyModuleAvailable: Bool = true) -> OptionState {
        guard let app else { return isDuo ? .unknown : .notADuo }
        if supportsDuo(sdk: app.sdkVersion) { return .alreadySupported }
        if app.needsLegacyModule, !legacyModuleAvailable { return .unavailable }
        return isDuo ? .recommended : .notADuo
    }

    /// The text of a usage description XSide adds (iOS shows it when the app asks for access).
    public static let usageDescription = "The app asks for this access. (Text added by XSide: the app was made before iOS required one.)"

    /// The usage descriptions iOS requires, by the framework that leads to them (an app built
    /// with an old SDK may have none, and the SDK raise makes iOS kill it without them).
    static let usageDescriptionsByFramework: [String: [String]] = [
        "MediaPlayer": ["NSAppleMusicUsageDescription"],
        "Photos": ["NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"],
        "AssetsLibrary": ["NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"],
        "AVFoundation": ["NSCameraUsageDescription", "NSMicrophoneUsageDescription"],
        "CoreLocation": ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription"],
        "Contacts": ["NSContactsUsageDescription"],
        "AddressBook": ["NSContactsUsageDescription"],
        "EventKit": ["NSCalendarsUsageDescription", "NSRemindersUsageDescription"],
        "CoreBluetooth": ["NSBluetoothAlwaysUsageDescription"],
        "CoreMotion": ["NSMotionUsageDescription"],
    ]

    /// Declares SDK 27.1 and, when the app has no scene manifest, adds one with a single
    /// application scene whose delegate is `sceneDelegateClass` (nothing when it's nil). An
    /// existing manifest is kept as it is: the app already uses scenes. Adds the usage
    /// descriptions the app lacks for the frameworks in `linkedLibraries` (its load commands).
    public static func applyInfoPlist(_ plist: inout [String: Any], sceneDelegateClass: String?,
                                      linkedLibraries: [String] = []) {
        plist["DTPlatformVersion"] = sdk
        plist["DTSDKName"] = sdkName
        for library in linkedLibraries {
            let parts = library.split(separator: "/")
            guard let framework = parts.first(where: { $0.hasSuffix(".framework") })?.dropLast(".framework".count),
                  let keys = usageDescriptionsByFramework[String(framework)] else { continue }
            for key in keys where plist[key] == nil { plist[key] = usageDescription }
        }
        guard plist["UIApplicationSceneManifest"] == nil, let sceneDelegateClass else { return }
        plist["UIApplicationSceneManifest"] = [
            "UIApplicationSupportsMultipleScenes": false,
            "UISceneConfigurations": [
                "UIWindowSceneSessionRoleApplication": [[
                    "UISceneConfigurationName": "Default",
                    "UISceneDelegateClassName": sceneDelegateClass,
                ]],
            ],
        ] as [String: Any]
    }

    /// The `xcrun` arguments that give every slice SDK 27.1, keeping its minimum iOS. One call
    /// when the slices share it, else one per slice (`-arch`), chained through `temp(i)`. Nil when
    /// a slice isn't an iOS one or its minimum is unknown.
    public static func vtoolCalls(input: String, output: String, slices: [MachOBuildInfo.Slice],
                                  temp: (Int) -> String) -> [[String]]? {
        guard !slices.isEmpty,
              slices.allSatisfy({ $0.minOS != nil && ($0.platform == nil || $0.platform == MachOBuildInfo.platformIOS) })
        else { return nil }
        let minimums = Set(slices.compactMap(\.minOS))
        if minimums.count == 1, let minOS = minimums.first {
            return [["vtool", "-set-build-version", "ios", minOS, sdk, "-replace", "-output", output, input]]
        }
        guard slices.allSatisfy({ $0.archName != nil }) else { return nil }
        var calls: [[String]] = []
        var from = input
        for (i, slice) in slices.enumerated() {
            let to = i == slices.count - 1 ? output : temp(i)
            calls.append(["vtool", "-arch", slice.archName!, "-set-build-version", "ios", slice.minOS!, sdk,
                          "-replace", "-output", to, from])
            from = to
        }
        return calls
    }

    /// Run paths that point into the Mac the app was built on (Xcode's toolchain), useless on a
    /// device: removed only when the header needs room for the new commands.
    public static let buildMacToolchainPrefixes = ["/private/var/select/", "/var/db/xcode_select_link/"]

    public static func isBuildMacToolchainPath(_ path: String) -> Bool {
        buildMacToolchainPrefixes.contains { path.hasPrefix($0) }
    }
}

/// The version load commands of a Mach-O, per slice.
public enum MachOBuildInfo {
    static let buildVersion: UInt32 = 0x32
    static let versionMinIPhoneOS: UInt32 = 0x25
    public static let platformIOS: UInt32 = 2

    public struct Slice: Equatable, Sendable {
        public let cpuType: UInt32
        public let cpuSubtype: UInt32
        /// `LC_BUILD_VERSION` platform (2: iOS); nil with `LC_VERSION_MIN_IPHONEOS` or none.
        public let platform: UInt32?
        public let minOS: String?
        public let sdk: String?

        public init(cpuType: UInt32, cpuSubtype: UInt32, platform: UInt32?, minOS: String?, sdk: String?) {
            self.cpuType = cpuType
            self.cpuSubtype = cpuSubtype
            self.platform = platform
            self.minOS = minOS
            self.sdk = sdk
        }

        /// The name `vtool -arch` takes, nil for an architecture an iOS app doesn't ship.
        public var archName: String? {
            switch cpuType {
            case 0x0100_000C: (cpuSubtype & 0xFF) == 2 ? "arm64e" : "arm64"
            case 0x0100_0007: "x86_64"
            default: nil
            }
        }
    }

    public static func slices(of executable: URL) throws -> [Slice] {
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe),
              let starts = try? IPAInspector.sliceOffsets(data) else { throw MachOPatcher.Failure.notMachO }
        return try starts.map { start in
            let commands = try MachOPatcher.loadCommands(data, at: start)
            let u32 = { MachOPatcher.u32(data, $0) }
            var platform: UInt32?, minOS: String?, sdk: String?
            if let c = commands.first(where: { $0.cmd == buildVersion && $0.size >= 24 }) {
                platform = u32(c.pos + 8); minOS = version(u32(c.pos + 12)); sdk = version(u32(c.pos + 16))
            } else if let c = commands.first(where: { $0.cmd == versionMinIPhoneOS && $0.size >= 16 }) {
                minOS = version(u32(c.pos + 8)); sdk = version(u32(c.pos + 12))
            }
            return Slice(cpuType: u32(start + 4), cpuSubtype: u32(start + 8), platform: platform, minOS: minOS, sdk: sdk)
        }
    }

    /// The oldest SDK among the slices, nil when none says.
    public static func sdkVersion(of executable: URL) -> String? {
        guard let slices = try? slices(of: executable) else { return nil }
        return slices.compactMap(\.sdk).min { InstallPreflight.compare($0, $1) == .orderedAscending }
    }

    /// The bytes `vtool -set-build-version … -replace` adds to the load commands of the slice that
    /// grows most: its version commands become one `LC_BUILD_VERSION` without tools (24 bytes).
    public static func versionCommandGrowth(of executable: URL) throws -> Int {
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe),
              let starts = try? IPAInspector.sliceOffsets(data) else { throw MachOPatcher.Failure.notMachO }
        var growth = 0
        for start in starts {
            let existing = try MachOPatcher.loadCommands(data, at: start)
                .filter { [buildVersion, versionMinIPhoneOS].contains($0.cmd) }.reduce(0) { $0 + $1.size }
            growth = max(growth, 24 - existing)
        }
        return growth
    }

    /// xxxx.yy.zz nibbles as "X.Y" or "X.Y.Z".
    static func version(_ v: UInt32) -> String {
        let major = v >> 16, minor = (v >> 8) & 0xFF, patch = v & 0xFF
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }
}
