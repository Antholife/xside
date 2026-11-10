import Foundation

/// What decides the "Simulate signed-out iCloud" option for an app, read from its .ipa at import.
/// Only the entitlements say the app uses iCloud: plenty of apps link CloudKit without ever
/// calling it (YouTube does, and runs fine without the option), so linking it alone recommends
/// nothing. An app whose entitlements were stripped and that does crash in iCloud is caught by the
/// crash diagnosis instead (`CrashAction.turnOnICloudSignedOut`).
/// Records written before this split (one `usesICloud` key) don't decode: "not known".
public struct ICloudAppInfo: Codable, Equatable, Sendable {
    /// The app's original entitlements ask for iCloud (`ICloudSignedOut.entitlementKeys`).
    public var declaresICloud: Bool
    /// Its main executable links CloudKit: it may use iCloud, or not at all.
    public var linksCloudKit: Bool
    /// The CloudKit containers its original entitlements declare (`iCloud.<id>`), checked and
    /// capped (see `ICloudSignedOut.containerIdentifiers`).
    public var containers: [String]
    /// What a paid team needs to give the app iCloud (`ICloudPaidTeam`); nil in a record imported
    /// before XSide read them. The iCloud services it declares (`CloudKit`, `CloudDocuments`), its
    /// iCloud Drive containers (checked like `containers`), whether it has a key-value store.
    public var services: [String]?
    public var ubiquityContainers: [String]?
    public var keyValueStore: Bool?

    public init(declaresICloud: Bool, linksCloudKit: Bool = false, containers: [String] = [],
                services: [String]? = nil, ubiquityContainers: [String]? = nil, keyValueStore: Bool? = nil) {
        self.declaresICloud = declaresICloud
        self.linksCloudKit = linksCloudKit
        self.containers = containers
        self.services = services
        self.ubiquityContainers = ubiquityContainers
        self.keyValueStore = keyValueStore
    }

    /// From the original entitlements (nil: unsigned or unreadable) and the main executable.
    public static func read(executable: URL, entitlements: [String: Any]?) -> ICloudAppInfo {
        ICloudAppInfo(declaresICloud: ICloudSignedOut.entitlementsUseICloud(entitlements),
                      linksCloudKit: ICloudSignedOut.linksCloudKit(executable),
                      containers: ICloudSignedOut.containerIdentifiers(entitlements),
                      services: ICloudSignedOut.services(entitlements),
                      ubiquityContainers: ICloudSignedOut.containerIdentifiers(
                          entitlements, key: "com.apple.developer.ubiquity-container-identifiers"),
                      keyValueStore: (entitlements?["com.apple.developer.ubiquity-kvstore-identifier"] as? String)?.isEmpty == false)
    }
}

/// The "Simulate signed-out iCloud" install option. An app signed with a free account gets no
/// iCloud entitlement, and CloudKit stops it at its first use (`[CKContainer defaultContainer]`
/// traps). With the option, XSide adds a small library of its own (`XSideICloud.dylib`, built from
/// `App/ICloud`, independent of XSide's module) that makes iCloud look signed out: no account,
/// every CloudKit call and operation fails "not authenticated", the key-value store stays on the
/// device, no ubiquity container. Per installation, like the iPhone Duo option; off by default.
public enum ICloudSignedOut {
    /// The library's file name in the app's `Frameworks/`, and the load command naming it.
    public static let dylibName = "XSideICloud.dylib"
    public static let loadPath = "@executable_path/Frameworks/\(dylibName)"
    /// Info.plist keys the library reads (from the file on disk): the app's own bundle id (the
    /// signed one is `<original>.<TEAM>`), and the CloudKit containers its entitlements declared.
    public static let originalBundleIDKey = "XSideOriginalBundleID"
    public static let containersKey = "XSideICloudContainers"
    /// Written only when the option applied: the library does nothing without it (an .ipa XSide
    /// signed before may still carry the library with the option off).
    public static let enabledKey = "XSideICloudSignedOut"

    /// Entitlements that mean the app uses iCloud (CloudKit, iCloud Drive, key-value store).
    public static let entitlementKeys = [
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.icloud-services",
        "com.apple.developer.ubiquity-kvstore-identifier",
        "com.apple.developer.ubiquity-container-identifiers",
    ]

    /// At most this many containers are kept (an app declares one or two).
    static let maxContainers = 16
    /// Longest container identifier kept.
    static let maxContainerLength = 255

    /// Whether one of `entitlementKeys` has a truthy value: a non-empty list or string, or `true`.
    /// Anything else (`false`, a number, a dictionary: an untrusted .ipa) is no.
    public static func entitlementsUseICloud(_ entitlements: [String: Any]?) -> Bool {
        guard let entitlements else { return false }
        return entitlementKeys.contains { key in
            switch entitlements[key] {
            case let list as [Any]: !list.isEmpty
            case let text as String: !text.isEmpty
            case let flag as Bool: flag
            default: false
            }
        }
    }

    /// The CloudKit containers of `com.apple.developer.icloud-container-identifiers`, in order,
    /// each once: only `iCloud.` identifiers of letters, digits, `.`, `-` and `_` (no wildcard nor
    /// build variable: the entitlements come from an untrusted .ipa), at most `maxContainers`.
    public static func containerIdentifiers(_ entitlements: [String: Any]?,
                                            key: String = "com.apple.developer.icloud-container-identifiers") -> [String] {
        guard let list = entitlements?[key] as? [Any] else { return [] }
        var result: [String] = []
        for case let id as String in list where isValidContainer(id) && !result.contains(id) {
            result.append(id)
            if result.count == maxContainers { break }
        }
        return result
    }

    /// The iCloud services a paid team can grant.
    public static let knownServices = ["CloudKit", "CloudDocuments"]

    /// `com.apple.developer.icloud-services`: the known ones it lists, in `knownServices` order;
    /// `"*"` is all of them. Anything else (another type, unknown names) is left out.
    public static func services(_ entitlements: [String: Any]?) -> [String] {
        switch entitlements?["com.apple.developer.icloud-services"] {
        case let text as String: return text == "*" ? knownServices : knownServices.filter { $0 == text }
        case let list as [Any]:
            let names = Set(list.compactMap { $0 as? String })
            return names.contains("*") ? knownServices : knownServices.filter(names.contains)
        default: return []
        }
    }

    static func isValidContainer(_ id: String) -> Bool {
        guard id.hasPrefix("iCloud."), id.utf8.count > "iCloud.".count, id.utf8.count <= maxContainerLength,
              !id.hasSuffix("."), !id.contains("..") else { return false }
        return id.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
        }
    }

    /// Load commands naming a library: LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
    /// LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB.
    static let dylibCommands: Set<UInt32> = [0xC, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023]

    /// Whether a slice of the Mach-O at `url` loads CloudKit. Anything unreadable or malformed
    /// (an untrusted file) is "no"; every offset is checked by `MachOPatcher.loadCommands`.
    public static func linksCloudKit(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let starts = try? IPAInspector.sliceOffsets(data) else { return false }
        for start in Set(starts) {
            guard let commands = try? MachOPatcher.loadCommands(data, at: start) else { continue }
            for c in commands where dylibCommands.contains(c.cmd) {
                if let name = MachOPatcher.dylibName(data, c), isCloudKit(name) { return true }
            }
        }
        return false
    }

    static func isCloudKit(_ path: String) -> Bool {
        path.hasSuffix("/CloudKit.framework/CloudKit") || path.contains("/CloudKit.framework/Versions/")
    }

    /// How the option shows for an app. Always usable, with any account: with a free team XSide
    /// can give no app iCloud, so this is the only fix for an app that crashes in it; a paid team
    /// keeps the app's iCloud (`ICloudPaidTeam`), so there it is offered, not recommended.
    public enum OptionState: Equatable, Sendable {
        /// The app's entitlements declare iCloud and the team is free: highlighted, still off
        /// until turned on.
        case recommended
        /// The app's entitlements declare iCloud and the team is paid: XSide keeps its iCloud
        /// (not yet tried with a real paid team). Offered, not highlighted.
        case keptByPaidTeam
        /// The app links CloudKit but declares no iCloud: offered, "useful if it crashes because
        /// of iCloud", not highlighted.
        case useful
        /// The app doesn't use iCloud: offered, "not needed".
        case notNeeded
        /// What the app uses isn't known (imported by an older XSide): offered.
        case unknown

        /// Highlighted (badge, tinted row).
        public var isRecommended: Bool { self == .recommended }
    }

    /// `paidTeam`: the signing team is a paid one (`SigningEnvironment.isPaidTeam`).
    public static func optionState(app: ICloudAppInfo?, paidTeam: Bool = false) -> OptionState {
        guard let app else { return .unknown }
        if app.declaresICloud { return paidTeam ? .keptByPaidTeam : .recommended }
        return app.linksCloudKit ? .useful : .notNeeded
    }

    /// Writes what the library reads into the app's Info.plist; removes it first (an app signed by
    /// XSide before may carry it).
    public static func applyInfoPlist(_ plist: inout [String: Any], originalBundleID: String?, containers: [String]) {
        clearInfoPlist(&plist)
        plist[enabledKey] = true
        if let originalBundleID, !originalBundleID.isEmpty { plist[originalBundleIDKey] = originalBundleID }
        if !containers.isEmpty { plist[containersKey] = containers }
    }

    public static func clearInfoPlist(_ plist: inout [String: Any]) {
        plist[originalBundleIDKey] = nil
        plist[containersKey] = nil
        plist[enabledKey] = nil
    }
}
