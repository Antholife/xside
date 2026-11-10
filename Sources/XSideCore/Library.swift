import Foundation
import CryptoKit
import Darwin
import os

/// A tweak of the app's pool (`AppRecord.tweaks`) as chosen for one device.
public struct TweakUse: Codable, Equatable, Sendable {
    /// `TweakPackage.id`.
    public var id: String
    public var enabled: Bool
    /// « Injecter quand même »: the person overrode an overridable ❌. nil: not overridden.
    public var force: Bool?
    /// Turned off because the person uninstalled this dependency here (Settings > Tweaks,
    /// « Désinstaller… »): its name, for « Désactivé : tu as retiré … ». Such a tweak isn't
    /// « À régler »; turning it back on clears it (`AppLibrary.setTweaks`). nil: not that.
    public var removedDependency: String?

    public init(id: String, enabled: Bool = true, force: Bool? = nil, removedDependency: String? = nil) {
        self.id = id
        self.enabled = enabled
        self.force = force
        self.removedDependency = removedDependency
    }
}

/// Why a signing left an enabled tweak out.
public enum TweakSkip: Codable, Equatable, Sendable {
    case incompatible(TweakProblem)
    /// The app's header had no room left for its load command.
    case noRoom
    /// Its stored files were missing or damaged, or copying them failed.
    case failed
}

/// What the last signing did with one enabled tweak.
public enum TweakResult: Codable, Equatable, Sendable {
    case injected(converted: Bool)
    case skipped(TweakSkip)
}

/// A tweak as one signing injected it: kept with the installation until its next signing, so a
/// crash still names it after the person replaced the version or dropped it from the pool.
public struct InjectedTweak: Codable, Equatable, Sendable {
    /// `TweakPackage.id`.
    public var id: String
    public var name: String
    public var packageID: String
    public var version: String?
    /// Its Mach-O files' names, as crash logs name the images.
    public var imageNames: [String]
    /// What XSide changed so that it works without a jailbreak. nil: injected as it is.
    public var conversions: [TweakConversion]?

    public init(id: String, name: String, packageID: String, version: String? = nil, imageNames: [String],
                conversions: [TweakConversion]? = nil) {
        self.id = id
        self.name = name
        self.packageID = packageID
        self.version = version
        self.imageNames = imageNames
        self.conversions = conversions
    }

    public init(_ package: TweakPackage, conversions: [TweakConversion]?) {
        self.init(id: package.id, name: package.name, packageID: package.packageID, version: package.version,
                  imageNames: package.binaries.map(\.imageName), conversions: conversions)
    }

    public var converted: Bool { conversions != nil }
}

public struct Installation: Codable, Equatable, Sendable {
    public var deviceID: String
    public var installedAt: Date
    public var expiresAt: Date
    public var lastAttempt: Date?
    public var lastErrorKey: String?
    /// Bundle id this device was signed with. nil in state written before it was tracked: the
    /// record's `signedBundleID` then.
    public var signedBundleID: String?
    /// Certificate (SHA-1) and team of the last successful signing. nil when unknown (older state):
    /// a certificate change then can't be detected for this installation.
    public var signingIdentitySHA1: String?
    public var teamID: String?
    /// The user stopped XSide refreshing it there: the app stays on the device (and in the
    /// popover) until it expires. A new install of the app on that device clears it.
    public var refreshPaused: Bool
    /// When a pause of this app alone ends by itself (the panel's "Pause > 2 h / 1 jour", device
    /// feedback 3, E5): XSide then resumes it. nil: paused until resumed, or not paused.
    public var pausedUntil: Date?
    /// The app's version installed there (the custom one, else the .ipa's). nil in older state.
    public var appVersion: String?
    /// XSide-in-app settings for this installation. nil in older state (seeded at migration).
    public var inApp: InAppSettings?
    /// Who paused the refresh (`refreshPaused`): the Mac or the device. nil when unknown.
    public var pausedBy: ChangeOrigin?
    /// First time the app was installed on this device (kept across refreshes). nil in older state.
    public var firstInstalledAt: Date?
    /// Last refresh outcome reported by the phone. nil until a check-in.
    public var lastRefreshOutcome: RefreshOutcome?
    /// Secret shared with the dylib for the local network channel. nil until generated.
    public var channelSecret: Data?
    /// Last time the phone checked in through the channel. nil if never.
    public var lastCheckIn: Date?
    /// Last refresh the phone itself asked for and XSide started: the phone's refresh limit counts
    /// from it. Set only by XSide; nothing the phone sends resets it. nil if never.
    public var lastDeviceRefreshRequest: Date?
    /// Last time the Mac's user changed this installation's in-app settings (the per-app window,
    /// a pause from the panel, a field changed in the install window). Seeded or default values
    /// aren't edits. nil if never. Drives `SettingsDelivery`.
    public var lastMacEdit: Date?
    /// Signed without XSide's features at its last signing (nothing in the app to talk to XSide).
    /// nil in older state, or when signed with them.
    public var withoutXSideFeatures: Bool?
    /// The person turned XSide's features off for this device only (a crash's fix): its signings
    /// go without them whatever the app's choice. nil: the app's choice (`InstallOptions`).
    public var withoutXSideFeaturesHere: Bool?
    /// The user turned iPhone Duo compatibility on for this installation: each signing applies it
    /// (see `DuoCompatibility`). nil: off.
    public var duoCompatibility: Bool?
    /// Asked for at the last signing, but the app installed doesn't have it (not possible, or the
    /// patch failed and the app was installed without it). nil otherwise.
    public var duoCompatibilityMissing: Bool?
    /// The last signing added the Duo compatibility module (an app without scenes). nil otherwise.
    public var duoLegacyModule: Bool?
    /// The device was an iPhone Duo at the last signing: remembered for when it isn't connected.
    public var onDuo: Bool?
    /// The user turned "Simulate signed-out iCloud" on for this installation: each signing adds
    /// the library (see `ICloudSignedOut`). nil: off.
    public var iCloudSignedOut: Bool?
    /// Asked for at the last signing, but the app installed doesn't have it (this build has no
    /// library, or it couldn't be added). nil otherwise.
    public var iCloudSignedOutMissing: Bool?
    /// Missing because the app's header had room for one more library only, and XSide's module
    /// got it (turning the XSide features off for the app makes room). nil otherwise.
    public var iCloudSignedOutSkippedForModule: Bool?
    /// What the last signing was asked to do for the options that only apply at signing (nil in
    /// older state: not known). Compared with the choices now by `pendingSigningChanges`.
    public var signedChoices: SigningChoices?
    /// The tweaks of the app's pool chosen for this device, in load order. nil in older state
    /// (none). What its last signing was asked for is `signedChoices.tweaks`.
    public var tweaks: [TweakUse]?
    /// What the last signing did with each enabled tweak, by `TweakPackage.id`. nil: no tweak
    /// was asked (or older state).
    public var tweakResults: [String: TweakResult]?
    /// Package ids of the dependencies XSide added by itself at the last signing (for the crash
    /// wording). nil: none.
    public var embeddedDependencies: [String]?
    /// The tweaks the last signing injected (name, version, images, conversions). nil: none, or
    /// older state (`injectedTweakHistory(pool:)` then reads the pool).
    public var injectedTweaks: [InjectedTweak]?
    /// Image names of the libraries the last signing added for converted tweaks: ElleKit, the
    /// support library, XSide's embedded dependencies. nil: none, or older state.
    public var tweakSupportImages: [String]?
    /// Tweaks the app on the device has.
    public var injectedTweakCount: Int {
        (tweakResults ?? [:]).values.reduce(0) { n, r in if case .injected = r { n + 1 } else { n } }
    }
    /// One of them was converted to work without a jailbreak.
    public var hasConvertedTweak: Bool {
        (tweakResults ?? [:]).values.contains(.injected(converted: true))
    }
    /// The app on the device has the library: asked for, and the last signing added it.
    /// (Turned on since that signing, e.g. while it ran: not there yet.)
    public var hasICloudSignedOut: Bool {
        iCloudSignedOut == true && iCloudSignedOutMissing != true && signedChoices?.iCloudSignedOut != false
    }
    /// The app on the device has iPhone Duo compatibility: asked for, and the last signing applied it.
    public var hasDuoCompatibility: Bool {
        duoCompatibility == true && duoCompatibilityMissing != true && signedChoices?.duoCompatibility != false
    }
    /// The app on the device has XSide's module (`withoutXSideFeatures` is what the last signing did).
    public var hasXSideModule: Bool { withoutXSideFeatures != true }

    public init(deviceID: String, installedAt: Date, expiresAt: Date,
                lastAttempt: Date? = nil, lastErrorKey: String? = nil, signedBundleID: String? = nil,
                signingIdentitySHA1: String? = nil, teamID: String? = nil, refreshPaused: Bool = false,
                appVersion: String? = nil, inApp: InAppSettings? = nil, pausedBy: ChangeOrigin? = nil,
                firstInstalledAt: Date? = nil, lastRefreshOutcome: RefreshOutcome? = nil,
                channelSecret: Data? = nil, lastCheckIn: Date? = nil, lastDeviceRefreshRequest: Date? = nil,
                lastMacEdit: Date? = nil, withoutXSideFeatures: Bool? = nil,
                duoCompatibility: Bool? = nil, duoCompatibilityMissing: Bool? = nil, onDuo: Bool? = nil,
                iCloudSignedOut: Bool? = nil, iCloudSignedOutMissing: Bool? = nil,
                iCloudSignedOutSkippedForModule: Bool? = nil, duoLegacyModule: Bool? = nil,
                withoutXSideFeaturesHere: Bool? = nil, signedChoices: SigningChoices? = nil,
                tweaks: [TweakUse]? = nil, tweakResults: [String: TweakResult]? = nil,
                embeddedDependencies: [String]? = nil, injectedTweaks: [InjectedTweak]? = nil,
                tweakSupportImages: [String]? = nil) {
        self.injectedTweaks = injectedTweaks
        self.tweakSupportImages = tweakSupportImages
        self.tweaks = tweaks
        self.tweakResults = tweakResults
        self.embeddedDependencies = embeddedDependencies
        self.signedChoices = signedChoices
        self.withoutXSideFeaturesHere = withoutXSideFeaturesHere
        self.duoLegacyModule = duoLegacyModule
        self.iCloudSignedOutSkippedForModule = iCloudSignedOutSkippedForModule
        self.onDuo = onDuo
        self.iCloudSignedOut = iCloudSignedOut
        self.iCloudSignedOutMissing = iCloudSignedOutMissing
        self.duoCompatibility = duoCompatibility
        self.duoCompatibilityMissing = duoCompatibilityMissing
        self.lastMacEdit = lastMacEdit
        self.withoutXSideFeatures = withoutXSideFeatures
        self.lastDeviceRefreshRequest = lastDeviceRefreshRequest
        self.inApp = inApp
        self.pausedBy = pausedBy
        self.firstInstalledAt = firstInstalledAt
        self.lastRefreshOutcome = lastRefreshOutcome
        self.channelSecret = channelSecret
        self.lastCheckIn = lastCheckIn
        self.appVersion = appVersion
        self.deviceID = deviceID
        self.installedAt = installedAt
        self.expiresAt = expiresAt
        self.lastAttempt = lastAttempt
        self.lastErrorKey = lastErrorKey
        self.signedBundleID = signedBundleID
        self.signingIdentitySHA1 = signingIdentitySHA1
        self.teamID = teamID
        self.refreshPaused = refreshPaused
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        installedAt = try c.decode(Date.self, forKey: .installedAt)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        lastAttempt = try c.decodeIfPresent(Date.self, forKey: .lastAttempt)
        lastErrorKey = try c.decodeIfPresent(String.self, forKey: .lastErrorKey)
        signedBundleID = try c.decodeIfPresent(String.self, forKey: .signedBundleID)
        signingIdentitySHA1 = try c.decodeIfPresent(String.self, forKey: .signingIdentitySHA1)
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID)
        refreshPaused = (try? c.decodeIfPresent(Bool.self, forKey: .refreshPaused)) ?? false
        pausedUntil = try? c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        appVersion = try? c.decodeIfPresent(String.self, forKey: .appVersion)
        inApp = try? c.decodeIfPresent(InAppSettings.self, forKey: .inApp)
        pausedBy = try? c.decodeIfPresent(ChangeOrigin.self, forKey: .pausedBy)
        firstInstalledAt = try? c.decodeIfPresent(Date.self, forKey: .firstInstalledAt)
        lastRefreshOutcome = try? c.decodeIfPresent(RefreshOutcome.self, forKey: .lastRefreshOutcome)
        channelSecret = try? c.decodeIfPresent(Data.self, forKey: .channelSecret)
        lastCheckIn = try? c.decodeIfPresent(Date.self, forKey: .lastCheckIn)
        lastDeviceRefreshRequest = try? c.decodeIfPresent(Date.self, forKey: .lastDeviceRefreshRequest)
        lastMacEdit = try? c.decodeIfPresent(Date.self, forKey: .lastMacEdit)
        withoutXSideFeatures = try? c.decodeIfPresent(Bool.self, forKey: .withoutXSideFeatures)
        duoCompatibility = try? c.decodeIfPresent(Bool.self, forKey: .duoCompatibility)
        duoCompatibilityMissing = try? c.decodeIfPresent(Bool.self, forKey: .duoCompatibilityMissing)
        onDuo = try? c.decodeIfPresent(Bool.self, forKey: .onDuo)
        iCloudSignedOut = try? c.decodeIfPresent(Bool.self, forKey: .iCloudSignedOut)
        iCloudSignedOutMissing = try? c.decodeIfPresent(Bool.self, forKey: .iCloudSignedOutMissing)
        iCloudSignedOutSkippedForModule = try? c.decodeIfPresent(Bool.self, forKey: .iCloudSignedOutSkippedForModule)
        duoLegacyModule = try? c.decodeIfPresent(Bool.self, forKey: .duoLegacyModule)
        withoutXSideFeaturesHere = try? c.decodeIfPresent(Bool.self, forKey: .withoutXSideFeaturesHere)
        signedChoices = try? c.decodeIfPresent(SigningChoices.self, forKey: .signedChoices)
        tweaks = try? c.decodeIfPresent([TweakUse].self, forKey: .tweaks)
        tweakResults = try? c.decodeIfPresent([String: TweakResult].self, forKey: .tweakResults)
        embeddedDependencies = try? c.decodeIfPresent([String].self, forKey: .embeddedDependencies)
        injectedTweaks = try? c.decodeIfPresent([InjectedTweak].self, forKey: .injectedTweaks)
        tweakSupportImages = try? c.decodeIfPresent([String].self, forKey: .tweakSupportImages)
    }
}

public struct AppRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public let originalBundleID: String
    /// Bundle id the next install is signed with (see `Installation.signedBundleID` for each device).
    public var signedBundleID: String
    /// Path relative to the library root.
    public var ipaPath: String
    public var options: InstallOptions
    public var installations: [Installation]
    /// Team id used at import, needed to derive `signedBundleID`.
    public var teamID: String
    /// First successful install per signed bundle id (each one is an App ID). Lets the App ID
    /// counter date an App ID even after its cached profiles were replaced. nil in state written
    /// before this was tracked.
    public var appIDFirstUse: [String: Date]?
    /// Version of the current .ipa (`CFBundleShortVersionString`). nil in older state.
    public var version: String?
    /// What the current .ipa supports for the iPhone Duo option. nil in older state.
    public var duo: DuoAppInfo?
    /// What the current .ipa uses of iCloud, for the signed-out iCloud option. nil in older state.
    public var icloud: ICloudAppInfo?
    /// The current .ipa still carries 32-bit ARM code (armv7/armv7s), removed at each signing.
    /// nil in older state (not scanned).
    public var legacy32: Bool?
    /// The app's `CFBundleExecutable`: its process name in the device's crash logs. nil in older
    /// state, until its next import or signing.
    public var executable: String?
    /// The app's tweaks, stored once under `apps/<id>/tweaks/<tweak id>/`; the list's order is
    /// the load order. Which device gets which is `Installation.tweaks`. nil in older state.
    public var tweaks: [TweakPackage]?
    /// Tweaks chosen for a device the app isn't installed on yet (by device id): they keep the
    /// tweak's files until that device's first signing, which records its own list.
    public var pendingTweakUses: [String: [TweakUse]]?

    public init(id: UUID, displayName: String, originalBundleID: String, signedBundleID: String,
                ipaPath: String, options: InstallOptions, installations: [Installation], teamID: String,
                appIDFirstUse: [String: Date]? = nil) {
        self.id = id
        self.displayName = displayName
        self.originalBundleID = originalBundleID
        self.signedBundleID = signedBundleID
        self.ipaPath = ipaPath
        self.options = options
        self.installations = installations
        self.teamID = teamID
        self.appIDFirstUse = appIDFirstUse
    }

    /// Only the identity and the archive are required; anything else missing gets a default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        originalBundleID = try c.decode(String.self, forKey: .originalBundleID)
        ipaPath = try c.decode(String.self, forKey: .ipaPath)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? originalBundleID
        let signed = try c.decodeIfPresent(String.self, forKey: .signedBundleID)
        // Imports sign as "<original>.<TEAM>": the team can be read back from that.
        let prefix = BundleIdentifier.defaultSigned(original: originalBundleID, teamID: "")
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID)
            ?? signed.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil } ?? ""
        signedBundleID = signed ?? (teamID.isEmpty ? originalBundleID
            : BundleIdentifier.defaultSigned(original: originalBundleID, teamID: teamID))
        options = try c.decodeIfPresent(InstallOptions.self, forKey: .options) ?? InstallOptions()
        installations = try c.decodeIfPresent([Installation].self, forKey: .installations) ?? []
        appIDFirstUse = try c.decodeIfPresent([String: Date].self, forKey: .appIDFirstUse)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        duo = try? c.decodeIfPresent(DuoAppInfo.self, forKey: .duo)
        icloud = try? c.decodeIfPresent(ICloudAppInfo.self, forKey: .icloud)
        legacy32 = try? c.decodeIfPresent(Bool.self, forKey: .legacy32)
        executable = try? c.decodeIfPresent(String.self, forKey: .executable)
        // One at a time: a damaged (or newer) entry doesn't cost the others.
        tweaks = (try? c.decodeIfPresent([LossyTweak].self, forKey: .tweaks))?.compactMap(\.package)
        pendingTweakUses = try? c.decodeIfPresent([String: [TweakUse]].self, forKey: .pendingTweakUses)
    }

    private struct LossyTweak: Decodable {
        let package: TweakPackage?
        init(from decoder: any Decoder) throws { package = try? TweakPackage(from: decoder) }
    }
}

/// What a signing job read of its device's choices when it started, so that `recordSigning`
/// keeps the ones the person changed while it ran.
public struct SigningSnapshot: Equatable, Sendable {
    /// The device's installation then (nil: a first install).
    public var installation: Installation?
    /// The tweaks chosen for the device before its first install (`AppRecord.pendingTweakUses`).
    public var pendingTweaks: [TweakUse]?

    public init(installation: Installation?, pendingTweaks: [TweakUse]?) {
        self.installation = installation
        self.pendingTweaks = pendingTweaks
    }
}

extension AppRecord {
    public func signingSnapshot(deviceID: String) -> SigningSnapshot {
        SigningSnapshot(installation: installations.first { $0.deviceID == deviceID },
                        pendingTweaks: pendingTweakUses?[deviceID])
    }
}

/// Name of the library folder in Application Support: the debug bundle
/// (`io.github.xside.XSide.debug`) keeps its own, so it never touches the release app's apps.
public enum LibraryLocation {
    public static func folderName(bundleID: String?) -> String {
        bundleID?.hasSuffix(".debug") == true ? "XSide-debug" : "XSide"
    }
}

/// What went wrong reading `state.json` at launch (the app may warn about it).
public enum LibraryLoadIssue: Equatable, Sendable {
    /// Some records couldn't be read and were left out. The file was kept as `state.json.corrupt-…`.
    case recordsSkipped(Int)
    /// `state.json` was unreadable (kept as `state.json.corrupt-…`); `state.json.bak` was loaded.
    case restoredFromBackup
    /// Neither `state.json` nor its backup could be read: the library starts empty.
    case unreadable
}

public actor AppLibrary {
    private static let logger = Log("library")
    public nonisolated let root: URL
    /// Set when `state.json` couldn't be fully read at init, nil otherwise.
    public nonisolated let loadIssue: LibraryLoadIssue?
    private var items: [AppRecord] = []
    /// `addTweak` calls analysing right now: a folder they store isn't in a pool yet.
    private var tweaksInFlight = 0
    /// Versions `addTweak` stored and offered as a replacement, not confirmed yet (by record).
    private var offeredTweaks: [UUID: Set<String>] = [:]
    /// Tweak ids running jobs hold (by record, with a count): never collected meanwhile.
    private var reservedTweaks: [UUID: [String: Int]] = [:]
    /// Downloads whose bytes were checked, with the size and date they had then.
    private var verifiedDownloads: [String: FileStamp] = [:]
    /// When each app (original bundle id) last checked in on each device, kept across a reinstall
    /// and the removal of its record (`connections.json`, device round 2, item 2): a new
    /// installation of an app that was connected there says so.
    private var connections: [String: Date] = [:]
    public static let connectionsFile = "connections.json"
    private var stateURL: URL { root.appendingPathComponent("state.json") }
    private var backupURL: URL { root.appendingPathComponent("state.json.bak") }

    /// `temporaryDirectory`: where XSide's own temporary folders left by a run that was killed
    /// are swept from (see `sweepLeftovers`).
    public init(root: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        (items, loadIssue) = Self.load(root: root)
        connections = Self.loadConnections(root: root, records: items)
        Self.sweepLeftovers(root: root, temporaryDirectory: temporaryDirectory)
    }

    private static func connectionKey(bundleID: String, deviceID: String) -> String { bundleID + "|" + deviceID }

    /// The file, merged with the check-ins the records hold (a library written before it).
    private static func loadConnections(root: URL, records: [AppRecord]) -> [String: Date] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out = (try? Data(contentsOf: root.appendingPathComponent(connectionsFile)))
            .flatMap { try? decoder.decode([String: Date].self, from: $0) } ?? [:]
        for r in records {
            for i in r.installations {
                guard let date = i.lastCheckIn else { continue }
                let key = connectionKey(bundleID: r.originalBundleID, deviceID: i.deviceID)
                out[key] = max(out[key] ?? date, date)
            }
        }
        return out
    }

    /// The last check-in of that app on that device, by any of its installations (nil: never).
    public func lastConnection(bundleID: String, deviceID: String) -> Date? {
        connections[Self.connectionKey(bundleID: bundleID, deviceID: deviceID)]
    }

    /// Every remembered connection, by `originalBundleID|deviceID` (for the views).
    public func connectionHistory() -> [String: Date] { connections }

    public nonisolated static func connectionKey(_ record: AppRecord, deviceID: String) -> String {
        connectionKey(bundleID: record.originalBundleID, deviceID: deviceID)
    }

    private func rememberConnection(bundleID: String, deviceID: String, at date: Date) {
        let key = Self.connectionKey(bundleID: bundleID, deviceID: deviceID)
        guard (connections[key] ?? .distantPast) < date else { return }
        connections[key] = date
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(connections).write(to: root.appendingPathComponent(Self.connectionsFile), options: .atomic)
        } catch {
            Self.logger.error("saving connections.json failed: \(String(describing: error))")
        }
    }

    /// Decodes one record at a time, so a single bad record doesn't cost the whole library.
    private struct Lossy: Decodable {
        let record: AppRecord?
        init(from decoder: any Decoder) throws { record = try? AppRecord(from: decoder) }
    }

    private static func decode(_ data: Data) -> (records: [AppRecord], skipped: Int)? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let lossy = try? decoder.decode([Lossy].self, from: data) else { return nil }
        let records = lossy.compactMap(\.record)
        return (records, lossy.count - records.count)
    }

    /// The records in `root`'s `state.json`, read only: never moves nor copies anything (the app
    /// may be writing it; `init` handles a damaged file). Nil when there's none or it can't be read.
    public static func readRecords(root: URL) -> [AppRecord]? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")) else { return nil }
        return decode(data)?.records
    }

    private static func load(root: URL) -> ([AppRecord], LibraryLoadIssue?) {
        let fm = FileManager.default
        let url = root.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url) else { return ([], nil) }
        if let decoded = decode(data) {
            let (records, skipped) = decoded
            guard skipped > 0 else { return (records, nil) }
            // The next save drops the skipped records: keep the file as it was.
            let kept = corruptURL(root: root)
            try? fm.copyItem(at: url, to: kept)
            logger.error("state.json: \(skipped) record(s) skipped, kept as \(kept.lastPathComponent)")
            return (records, .recordsSkipped(skipped))
        }
        let kept = corruptURL(root: root)
        try? fm.moveItem(at: url, to: kept)
        logger.error("state.json unreadable, moved to \(kept.lastPathComponent)")
        if let backup = try? Data(contentsOf: root.appendingPathComponent("state.json.bak")),
           let restored = decode(backup) {
            return (restored.records, .restoredFromBackup)
        }
        return ([], .unreadable)
    }

    /// `state.json.corrupt-<date>`, never an existing file (an earlier corrupt copy is kept).
    static func corruptURL(root: URL, now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "state.json.corrupt-\(formatter.string(from: now))"
        var url = root.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        return url
    }

    public func records() -> [AppRecord] {
        items.sorted {
            let c = $0.displayName.caseInsensitiveCompare($1.displayName)
            return c == .orderedSame ? $0.id.uuidString < $1.id.uuidString : c == .orderedAscending
        }
    }

    /// Throws `invalidBundleID` for a new app whose default signed identifier is invalid (too long).
    public func importIPA(_ source: URL, info: AppInfo, teamID: String) throws -> AppRecord {
        let fm = FileManager.default
        let index = items.firstIndex { $0.originalBundleID == info.bundleID }
        let signed = BundleIdentifier.defaultSigned(original: info.bundleID, teamID: teamID)
        if index == nil, !BundleIdentifier.isValid(signed) { throw XSideError.invalidBundleID(signed) }
        let id = index.map { items[$0].id } ?? UUID()
        let relative = "apps/\(id.uuidString)/original.ipa"
        let dest = root.appendingPathComponent(relative)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = dest.deletingLastPathComponent().appendingPathComponent(".incoming-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: dest)
        }

        let previous = items
        var record: AppRecord
        if let index {
            items[index].displayName = info.name
            items[index].ipaPath = relative
            items[index].version = info.version
            items[index].duo = info.duo
            items[index].icloud = info.icloud
            items[index].legacy32 = info.hasLegacy32
            items[index].executable = info.executable
            record = items[index]
        } else {
            record = AppRecord(id: id, displayName: info.name, originalBundleID: info.bundleID,
                               signedBundleID: signed, ipaPath: relative,
                               options: InstallOptions(), installations: [], teamID: teamID)
            record.version = info.version
            record.duo = info.duo
            record.icloud = info.icloud
            record.legacy32 = info.hasLegacy32
            record.executable = info.executable
            items.append(record)
        }
        do { try save() } catch { items = previous; throw error }
        return record
    }

    public func setOptions(_ options: InstallOptions, for id: UUID) throws {
        let index = try indexOf(id)
        if let custom = options.customBundleID, !custom.isEmpty, !BundleIdentifier.isValid(custom) {
            throw XSideError.invalidBundleID(custom)
        }
        let fm = FileManager.default
        var options = options
        let relativeIcon = "apps/\(id.uuidString)/icon.png"
        let iconURL = root.appendingPathComponent(relativeIcon)
        if let path = options.iconPath, !path.isEmpty {
            if path != relativeIcon {
                let source = URL(fileURLWithPath: path)
                try fm.createDirectory(at: iconURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let staging = iconURL.deletingLastPathComponent().appendingPathComponent(".incoming-\(UUID().uuidString)")
                try fm.copyItem(at: source, to: staging)
                if fm.fileExists(atPath: iconURL.path) {
                    _ = try fm.replaceItemAt(iconURL, withItemAt: staging)
                } else {
                    try fm.moveItem(at: staging, to: iconURL)
                }
                options.iconPath = relativeIcon
            }
        } else {
            options.iconPath = nil
            try? fm.removeItem(at: iconURL)
        }

        let previous = items
        let custom = options.customBundleID.flatMap { $0.isEmpty ? nil : $0 }
        // Installations from before per-device bundle ids keep refreshing the app they have.
        let current = items[index].signedBundleID
        for i in items[index].installations.indices where items[index].installations[i].signedBundleID == nil {
            items[index].installations[i].signedBundleID = current
        }
        items[index].options = options
        items[index].signedBundleID = custom
            ?? BundleIdentifier.defaultSigned(original: items[index].originalBundleID, teamID: items[index].teamID)
        do { try save() } catch { items = previous; throw error }
    }

    /// `requireExisting`: a refresh result. It throws `recordNotFound` when the installation was
    /// removed meanwhile (device removed from XSide), instead of bringing it back.
    public func upsert(_ installation: Installation, for id: UUID, requireExisting: Bool = false) throws {
        let index = try indexOf(id)
        if requireExisting, !items[index].installations.contains(where: { $0.deviceID == installation.deviceID }) {
            throw XSideError.recordNotFound
        }
        let previous = items
        let bundleID = installation.signedBundleID ?? items[index].signedBundleID
        if installation.lastErrorKey == nil, items[index].appIDFirstUse?[bundleID] == nil {
            // Nothing tracked yet (new or pre-tracking record): the earliest known installation.
            let since = items[index].appIDFirstUse == nil
                ? items[index].installations.map(\.installedAt).reduce(installation.installedAt, min)
                : installation.installedAt
            items[index].appIDFirstUse = (items[index].appIDFirstUse ?? [:])
                .merging([bundleID: since]) { old, _ in old }
        }
        if let i = items[index].installations.firstIndex(where: { $0.deviceID == installation.deviceID }) {
            items[index].installations[i] = installation
        } else {
            items[index].installations.append(installation)
        }
        do { try save() } catch { items = previous; throw error }
    }

    public func remove(_ id: UUID) throws {
        let index = try indexOf(id)
        let previous = items
        items.remove(at: index)
        do { try save() } catch { items = previous; throw error }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("apps/\(id.uuidString)"))
        collectUnusedDownloads(after: "app \(id.uuidString) removed")
    }

    /// After an app, an installation, a device or a tweak went: the kept downloads no device's
    /// list uses any more are deleted (device round 2, item 9; round 3). Never one a list has; not while a tweak is
    /// being analysed (it may be reading one), the next removal or « Tout nettoyer » does it then.
    private func collectUnusedDownloads(after event: String) {
        guard tweaksInFlight == 0 else { return }
        let freed = removeUnusedDownloads()
        if freed.count > 0 {
            Self.logger.notice("download cache: \(freed.count) no longer used deleted (\(freed.bytes) bytes) after \(event)")
        }
    }

    /// Deletes a record (and its files) only if it has no installation left. Returns true when deleted.
    @discardableResult
    public func removeIfEmpty(_ id: UUID) throws -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].installations.isEmpty else { return false }
        try remove(id)
        return true
    }

    /// Forgets one installation (uninstalled, or no longer refreshed). The record stays even
    /// with none left, with its files: the caller deletes it with `removeIfEmpty` once no job
    /// uses it. Returns false when there was no such installation.
    @discardableResult
    public func removeInstallation(recordID: UUID, deviceID: String, keepingTweaks: Set<String> = []) throws -> Bool {
        let index = try indexOf(recordID)
        guard items[index].installations.contains(where: { $0.deviceID == deviceID }) else { return false }
        let previous = items
        items[index].installations.removeAll { $0.deviceID == deviceID }
        do { try save() } catch { items = previous; throw error }
        // With none left the record goes with its files (`removeIfEmpty`), or a job is installing
        // it elsewhere with its own choice: its tweaks are left alone.
        if !items[index].installations.isEmpty {
            collectUnusedTweaks(recordID: recordID, keeping: keepingTweaks)
            collectUnusedDownloads(after: "an installation of \(recordID.uuidString) removed")
        }
        return true
    }

    /// Pauses (or resumes) XSide's refreshes of one installation, without touching the device.
    /// `by`: who did it (the Mac panel, or the phone through the channel), recorded with the
    /// installation's "automatic refresh" setting so the app learns of it. Returns false when there
    /// was no such installation, or it was already in that state.
    /// `until`: the pause ends by itself then (see `resumeEndedPauses`); nil, until resumed.
    @discardableResult
    public func setRefreshPaused(_ paused: Bool, recordID: UUID, deviceID: String,
                                 by origin: ChangeOrigin = .mac, at date: Date = Date(),
                                 until: Date? = nil) throws -> Bool {
        let index = try indexOf(recordID)
        guard let i = items[index].installations.firstIndex(where: { $0.deviceID == deviceID }),
              items[index].installations[i].refreshPaused != paused else { return false }
        let previous = items
        Self.applyPause(paused, by: origin, at: date, to: &items[index].installations[i])
        items[index].installations[i].pausedUntil = paused ? until : nil
        do { try save() } catch { items = previous; throw error }
        return true
    }

    /// Records the app's executable name (read at a signing, for records imported before it was
    /// kept). True when it changed (and was saved).
    @discardableResult
    public func setExecutable(_ name: String, recordID: UUID) throws -> Bool {
        let index = try indexOf(recordID)
        guard !name.isEmpty, items[index].executable != name else { return false }
        let previous = items
        items[index].executable = name
        do { try save() } catch { items = previous; throw error }
        return true
    }

    /// Turns iPhone Duo compatibility on or off for one installation, from its next signing on.
    /// Returns false when there's no such installation or nothing changed.
    @discardableResult
    public func setDuoCompatibility(_ on: Bool, recordID: UUID, deviceID: String) throws -> Bool {
        let index = try indexOf(recordID)
        guard let i = items[index].installations.firstIndex(where: { $0.deviceID == deviceID }),
              (items[index].installations[i].duoCompatibility == true) != on else { return false }
        let previous = items
        items[index].installations[i].duoCompatibility = on ? true : nil
        if !on { items[index].installations[i].duoCompatibilityMissing = nil } // nothing asked, nothing missing
        do { try save() } catch { items = previous; throw error }
        return true
    }

    /// XSide's features off for one installation only (`Installation.withoutXSideFeaturesHere`),
    /// from its next signing on; `false` gives it the app's choice again. Returns false when
    /// there's no such installation or nothing changed.
    @discardableResult
    public func setWithoutXSideFeaturesHere(_ without: Bool, recordID: UUID, deviceID: String) throws -> Bool {
        let index = try indexOf(recordID)
        guard let i = items[index].installations.firstIndex(where: { $0.deviceID == deviceID }),
              (items[index].installations[i].withoutXSideFeaturesHere == true) != without else { return false }
        let previous = items
        items[index].installations[i].withoutXSideFeaturesHere = without ? true : nil
        do { try save() } catch { items = previous; throw error }
        return true
    }

    /// Turns "Simulate signed-out iCloud" on or off for one installation, from its next signing on.
    /// Returns false when there's no such installation or nothing changed.
    @discardableResult
    public func setICloudSignedOut(_ on: Bool, recordID: UUID, deviceID: String) throws -> Bool {
        let index = try indexOf(recordID)
        guard let i = items[index].installations.firstIndex(where: { $0.deviceID == deviceID }),
              (items[index].installations[i].iCloudSignedOut == true) != on else { return false }
        let previous = items
        items[index].installations[i].iCloudSignedOut = on ? true : nil
        if !on {
            items[index].installations[i].iCloudSignedOutMissing = nil
            items[index].installations[i].iCloudSignedOutSkippedForModule = nil
        }
        do { try save() } catch { items = previous; throw error }
        return true
    }

    /// Resumes the apps whose pause of their own ended at `date` or before, as a resume from the
    /// Mac at that date (the app is told at its next check-in). Returns them. `skipping`: the
    /// installations XSide is working on (an uninstall in progress), left for the next check.
    public func resumeEndedPauses(at date: Date, skipping: Set<RefreshJob> = []) throws -> [RefreshJob] {
        let previous = items
        var resumed: [RefreshJob] = []
        for r in items.indices {
            for i in items[r].installations.indices {
                guard items[r].installations[i].refreshPaused,
                      let end = items[r].installations[i].pausedUntil, end <= date,
                      !skipping.contains(RefreshJob(recordID: items[r].id, deviceID: items[r].installations[i].deviceID))
                else { continue }
                Self.applyPause(false, by: .mac, at: date, to: &items[r].installations[i])
                resumed.append(RefreshJob(recordID: items[r].id, deviceID: items[r].installations[i].deviceID))
            }
        }
        guard !resumed.isEmpty else { return [] }
        do { try save() } catch { items = previous; throw error }
        return resumed
    }

    private static func applyPause(_ paused: Bool, by origin: ChangeOrigin, at date: Date,
                                   to installation: inout Installation) {
        installation.refreshPaused = paused
        installation.pausedUntil = nil
        installation.pausedBy = paused ? origin : nil
        installation.inApp = installation.inApp?.setting(\.autoRefresh, to: !paused, at: date, by: origin)
        // The phone learns of a pause made on the Mac at its next check-in, like any Mac edit.
        if origin == .mac { installation.lastMacEdit = date }
        // Resuming: no retry delay left over from before the pause, a due app goes at once.
        if !paused { installation.lastAttempt = nil }
    }

    /// Within this time of the stored check-in, one that changes nothing isn't written.
    public static let quietCheckInInterval: TimeInterval = 60

    /// Stores a check-in from the phone: the merged settings, its date and (when given) the
    /// phone's newer refresh outcome. When the merged "automatic refresh" disagrees with the pause,
    /// the pause follows it (a change made on the phone while the Mac couldn't be told). Returns
    /// the new pause state when it changed, nil otherwise.
    @discardableResult
    public func applyCheckIn(_ settings: InAppSettings, checkIn: Date, outcome: RefreshOutcome?,
                             recordID: UUID, deviceID: String) throws -> Bool? {
        let index = try indexOf(recordID)
        guard let i = items[index].installations.firstIndex(where: { $0.deviceID == deviceID }) else {
            throw XSideError.recordNotFound
        }
        let previous = items
        var installation = items[index].installations[i]
        // Merged here, with what is stored now: a signing or a pause stored since the caller's
        // snapshot keeps its newer fields.
        let merged = installation.inApp.map { InAppSettings.merge($0, settings) } ?? settings
        // The phone checks in every 15 s while the app is in front (device feedback round 2, P3):
        // one that changes nothing within a minute of the stored check-in writes nothing. Unless
        // the Mac edited the settings since: this check-in is the one that delivered the edit, and
        // its date is what confirms it (device feedback 3, E2: it stayed "pending" up to a minute).
        if merged == installation.inApp, outcome == nil,
           let last = installation.lastCheckIn, checkIn.timeIntervalSince(last) < Self.quietCheckInInterval,
           (installation.lastMacEdit ?? .distantPast) <= last,
           installation.refreshPaused != merged.autoRefresh.value {
            return nil
        }
        installation.inApp = merged
        installation.lastCheckIn = checkIn
        if let outcome { installation.lastRefreshOutcome = outcome }
        var change: Bool?
        if installation.refreshPaused == merged.autoRefresh.value {
            let paused = !merged.autoRefresh.value
            installation.refreshPaused = paused
            installation.pausedBy = paused ? merged.autoRefresh.changedBy : nil
            installation.pausedUntil = nil
            if !paused { installation.lastAttempt = nil }
            change = paused
        }
        items[index].installations[i] = installation
        do { try save() } catch { items = previous; throw error }
        rememberConnection(bundleID: items[index].originalBundleID, deviceID: deviceID, at: checkIn)
        return change
    }

    /// Changes an installation's in-app settings from the Mac (Settings > Mes apps), on the values
    /// stored now (seeded with the Mac defaults, `reminder`, for older state). `transform` stamps
    /// what it changes; "automatic refresh" is left as it was (it goes with the pause, through
    /// `setRefreshPaused`). Throws `recordNotFound` when the installation is gone.
    public func editInApp(recordID: UUID, deviceID: String, reminder: Bool, at date: Date,
                          _ transform: @Sendable (InAppSettings) -> InAppSettings) throws {
        let index = try indexOf(recordID)
        guard let i = items[index].installations.firstIndex(where: { $0.deviceID == deviceID }) else {
            throw XSideError.recordNotFound
        }
        let previous = items
        let current = items[index].installations[i].seededInApp(reminder: reminder, at: date)
        var edited = transform(current)
        edited.autoRefresh = current.autoRefresh
        guard !edited.fields(differingFrom: current).isEmpty else { return } // restamped only: no edit
        items[index].installations[i].inApp = edited
        items[index].installations[i].lastMacEdit = date
        do { try save() } catch { items = previous; throw error }
    }

    /// Records that the phone asked for a refresh XSide started (see
    /// `Installation.lastDeviceRefreshRequest`). Throws `recordNotFound` when the installation is gone.
    public func markDeviceRefreshRequest(at date: Date, recordID: UUID, deviceID: String) throws {
        let index = try indexOf(recordID)
        guard let i = items[index].installations.firstIndex(where: { $0.deviceID == deviceID }) else {
            throw XSideError.recordNotFound
        }
        let previous = items
        items[index].installations[i].lastDeviceRefreshRequest = date
        do { try save() } catch { items = previous; throw error }
    }

    /// Records a failed attempt on the installation as stored now (the attempt date, the error
    /// and the outcome), leaving everything else as it is: its secret (the app on the device still
    /// holds it) and whatever reached it through the channel during the job. Throws
    /// `recordNotFound` when the installation is gone.
    public func recordFailure(errorKey: String, at date: Date, recordID: UUID, deviceID: String) throws {
        let index = try indexOf(recordID)
        guard let i = items[index].installations.firstIndex(where: { $0.deviceID == deviceID }) else {
            throw XSideError.recordNotFound
        }
        let previous = items
        items[index].installations[i].lastAttempt = date
        items[index].installations[i].lastErrorKey = errorKey
        items[index].installations[i].lastRefreshOutcome = RefreshOutcome(at: date, succeeded: false, reasonKey: errorKey)
        do { try save() } catch { items = previous; throw error }
    }

    /// Gives every installation saved without XSide-in-app settings (older state) the Mac
    /// defaults (see `Installation.seededInApp`). Returns how many were seeded.
    @discardableResult
    public func seedInAppSettings(reminder: Bool, at date: Date) throws -> Int {
        let previous = items
        var seeded = 0
        for r in items.indices {
            for i in items[r].installations.indices where items[r].installations[i].inApp == nil {
                items[r].installations[i].inApp = items[r].installations[i].seededInApp(reminder: reminder, at: date)
                seeded += 1
            }
        }
        guard seeded > 0 else { return 0 }
        do { try save() } catch { items = previous; throw error }
        return seeded
    }

    /// The installation whose channel id (`ChannelEnvelope.installationID`) is exactly `channelID`.
    public func installation(channelID: String) -> (recordID: UUID, installation: Installation)? {
        for record in items {
            for installation in record.installations
            where ChannelEnvelope.installationID(recordID: record.id, deviceID: installation.deviceID) == channelID {
                return (record.id, installation)
            }
        }
        return nil
    }

    /// Records a successful signing, keeping what arrived through the channel meanwhile (see
    /// `Installation.keepingChannelState`). Same rules as `upsert`. Returns what was stored.
    /// `startedFrom`: what the job read when it started; a choice changed since (tweaks, Duo,
    /// signed-out iCloud) is kept as it is now, for the next signing, instead of the job's.
    /// `keepingTweaks`: tweak ids other jobs use, never collected here.
    public func recordSigning(_ installation: Installation, for id: UUID, requireExisting: Bool,
                              startedFrom: SigningSnapshot? = nil, keepingTweaks: Set<String> = []) throws -> Installation {
        let index = try indexOf(id)
        let current = items[index].installations.first { $0.deviceID == installation.deviceID }
        var stored = current.map { installation.keepingChannelState(of: $0) } ?? installation
        if let start = startedFrom {
            let pool = items[index].tweaks ?? []
            if let current {
                stored.tweaks = Self.mergedUses(job: installation.tweaks, start: start.installation?.tweaks,
                                                now: current.tweaks, pool: pool)
                Self.keepChoicesChanged(since: start.installation, now: current, in: &stored)
            } else {
                stored.tweaks = Self.mergedUses(job: installation.tweaks, start: start.pendingTweaks,
                                                now: items[index].pendingTweakUses?[installation.deviceID], pool: pool)
            }
        }
        let previous = items
        // The device's own list now says which tweaks it has: the choice made before it was installed goes.
        if items[index].pendingTweakUses?[installation.deviceID] != nil {
            items[index].pendingTweakUses?[installation.deviceID] = nil
            if items[index].pendingTweakUses?.isEmpty == true { items[index].pendingTweakUses = nil }
        }
        do { try upsert(stored, for: id, requireExisting: requireExisting) } catch { items = previous; throw error }
        collectUnusedTweaks(recordID: id, keeping: keepingTweaks)
        return stored
    }

    /// Forgets a device: drops its installations from every record and deletes the records left
    /// with none (with their files), except those in `keeping` (a job is installing them on another
    /// device right now). One atomic save. Returns the number of installations removed.
    /// Nothing is uninstalled from the device itself.
    @discardableResult
    public func removeDevice(_ deviceID: String, keeping: Set<UUID> = [], keepingTweaks: Set<String> = []) throws -> Int {
        let previous = items
        var removed = 0
        var emptied: [UUID] = []
        var touched: [UUID] = []
        for index in items.indices {
            let before = items[index].installations.count
            items[index].installations.removeAll { $0.deviceID == deviceID }
            if items[index].pendingTweakUses?.removeValue(forKey: deviceID) != nil {
                if items[index].pendingTweakUses?.isEmpty == true { items[index].pendingTweakUses = nil }
                touched.append(items[index].id)
            }
            let dropped = before - items[index].installations.count
            removed += dropped
            if dropped > 0 { touched.append(items[index].id) }
            if dropped > 0, items[index].installations.isEmpty, !keeping.contains(items[index].id) {
                emptied.append(items[index].id)
            }
        }
        guard removed > 0 || !touched.isEmpty else { return 0 }
        items.removeAll { emptied.contains($0.id) }
        do { try save() } catch { items = previous; throw error }
        for id in emptied {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("apps/\(id.uuidString)"))
        }
        for id in touched where items.first(where: { $0.id == id })?.installations.isEmpty == false {
            collectUnusedTweaks(recordID: id, keeping: keepingTweaks)
        }
        collectUnusedDownloads(after: "device removed")
        return removed
    }

    private func indexOf(_ id: UUID) throws -> Int {
        guard let i = items.firstIndex(where: { $0.id == id }) else { throw XSideError.recordNotFound }
        return i
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(items)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let temp = root.appendingPathComponent(".state-\(UUID().uuidString).tmp")
        try data.write(to: temp)
        if fm.fileExists(atPath: stateURL.path) {
            backUpState()
            _ = try fm.replaceItemAt(stateURL, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: stateURL)
        }
    }

    /// Copies the current `state.json` to `state.json.bak` (one rolling backup). Best effort.
    private func backUpState() {
        let fm = FileManager.default
        let temp = root.appendingPathComponent(".state-bak-\(UUID().uuidString).tmp")
        guard (try? fm.copyItem(at: stateURL, to: temp)) != nil else { return }
        if fm.fileExists(atPath: backupURL.path) {
            if (try? fm.replaceItemAt(backupURL, withItemAt: temp)) == nil { try? fm.removeItem(at: temp) }
        } else if (try? fm.moveItem(at: temp, to: backupURL)) == nil {
            try? fm.removeItem(at: temp)
        }
    }
}

// MARK: Tweaks

/// A tweak the install window analysed into its own folder (`TweakAnalyzer.analyze`), before the
/// app is in the library: `directory` is the package's folder there. `replacing`: the pool's
/// package it replaces (the person confirmed).
public struct StagedTweak: Sendable, Equatable {
    public var package: TweakPackage
    public var directory: URL
    public var replacing: String?

    public init(package: TweakPackage, directory: URL, replacing: String? = nil) {
        self.package = package
        self.directory = directory
        self.replacing = replacing
    }
}

extension AppLibrary {
    private static let sweptTemporaryFolders = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Inside the library: one `<UUID>` folder per install window, where it analyses the tweaks
    /// added before Install (`StagedTweak`); deleted when the window's flow ends.
    public static let stagingFolder = "staging"

    /// A leftover this old (or older) is XSide's own and no longer in use.
    static let leftoverAge: TimeInterval = 3600

    /// `apps/<recordID>/tweaks/<id>`: where the package's files are stored.
    public nonisolated func tweakDirectory(recordID: UUID, id: String) -> URL {
        tweaksFolder(recordID).appendingPathComponent(id)
    }

    nonisolated func tweaksFolder(_ recordID: UUID) -> URL {
        root.appendingPathComponent("apps/\(recordID.uuidString)/tweaks")
    }

    /// Analyses `source` and adds it to the app's pool, enabled on `deviceIDs` only (a device
    /// without an installation yet keeps the choice in `pendingTweakUses`). The same bytes again
    /// are stored once and enabled on those devices too. Another version of a package already in
    /// the pool (same package id) is stored but not applied: it comes back with `replacing`, the
    /// package it would replace, for the person to confirm (`replaceTweak`).
    public func addTweak(_ source: URL, origin: TweakOrigin = .added, recordID: UUID, deviceIDs: [String],
                         runner: CommandRunning, now: Date) async throws -> (package: TweakPackage, replacing: TweakPackage?) {
        _ = try indexOf(recordID)
        tweaksInFlight += 1
        defer { tweaksInFlight -= 1 }
        let package = try await TweakAnalyzer.analyze(source, into: tweaksFolder(recordID), origin: origin,
                                                      runner: runner, now: now)
        // Other calls may have run during the analysis.
        guard let index = items.firstIndex(where: { $0.id == recordID }) else {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("apps/\(recordID.uuidString)"))
            throw XSideError.recordNotFound
        }
        guard Self.isDirectory(tweakDirectory(recordID: recordID, id: package.id)) else {
            throw TweakError.unreadable("the stored package is missing")
        }
        let pool = items[index].tweaks ?? []
        if let existing = pool.first(where: { $0.id == package.id }) {
            let previous = items
            enable(existing.id, on: deviceIDs, at: index)
            if items != previous { do { try save() } catch { items = previous; throw error } }
            return (existing, nil)
        }
        if let old = pool.first(where: { $0.packageID == package.packageID }) {
            offeredTweaks[recordID, default: []].insert(package.id)
            return (package, old)
        }
        let previous = items
        items[index].tweaks = pool + [package]
        enable(package.id, on: deviceIDs, at: index)
        do { try save() } catch { items = previous; throw error }
        return (package, nil)
    }

    /// Puts `new` (stored by `addTweak`) in `old`'s place in the pool: same load position, and
    /// every device that listed `old` lists `new` with the same `enabled` and `force`. The old
    /// files stay until no device's last signing has them.
    public func replaceTweak(_ old: String, with new: TweakPackage, recordID: UUID, keepingTweaks: Set<String> = []) throws {
        let index = try indexOf(recordID)
        var pool = items[index].tweaks ?? []
        guard let position = pool.firstIndex(where: { $0.id == old }) else { throw XSideError.recordNotFound }
        guard Self.isDirectory(tweakDirectory(recordID: recordID, id: new.id)) else {
            throw TweakError.unreadable("the stored package is missing")
        }
        let previous = items
        pool[position] = new
        pool = pool.enumerated().filter { $0.offset == position || $0.element.id != new.id }.map(\.element)
        items[index].tweaks = pool
        func renamed(_ uses: [TweakUse]) -> [TweakUse] {
            Self.ordered(uses.map { $0.id == old ? TweakUse(id: new.id, enabled: $0.enabled, force: $0.force) : $0 }, pool: pool)
        }
        for i in items[index].installations.indices {
            if let uses = items[index].installations[i].tweaks { items[index].installations[i].tweaks = renamed(uses) }
        }
        if let pending = items[index].pendingTweakUses { items[index].pendingTweakUses = pending.mapValues(renamed) }
        do { try save() } catch { items = previous; throw error }
        offeredTweaks[recordID]?.remove(new.id)
        collectUnusedTweaks(recordID: recordID, keeping: keepingTweaks)
    }

    /// The install window's tweaks, analysed into its own staging folder (`StagedTweak`), put in
    /// the app's pool when a device's install starts, and held (`reserveTweaks`) in the same step
    /// so no collection drops them before the job holds them itself: the caller releases the
    /// returned ids when the job ends (`releaseTweaks`). No device's list changes here: the job
    /// records it when the install succeeds, so a failed or cancelled one leaves each device's
    /// list as it was. Each folder is copied (the window keeps its own until it closes); one
    /// already in the pool is not copied again. A staged tweak takes the place of `replacing`, or
    /// of any version of the same package id, on every device (like `replaceTweak`, which the
    /// person confirmed); otherwise it goes at the end of the pool. All or nothing: a staged
    /// folder that isn't a real folder named by a package id is refused and nothing changes.
    public func adoptTweaks(_ staged: [StagedTweak], recordID: UUID) throws -> [String] {
        let index = try indexOf(recordID)
        for s in staged {
            guard Self.isTweakID(s.package.id), s.package.origin != .embedded, Self.isDirectory(s.directory) else {
                throw TweakError.unreadable("a staged tweak isn't a stored package folder")
            }
        }
        let fm = FileManager.default
        let folder = tweaksFolder(recordID)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var copied: [URL] = []
        func undoCopies() { for url in copied { try? fm.removeItem(at: url) } }
        let previous = items
        var pool = items[index].tweaks ?? []
        var renames: [String: String] = [:]
        do {
            for s in staged {
                let id = s.package.id
                let destination = tweakDirectory(recordID: recordID, id: id)
                if !Self.isDirectory(destination) {
                    let temp = folder.appendingPathComponent(".incoming-\(UUID().uuidString)")
                    try fm.copyItem(at: s.directory, to: temp)
                    do { try fm.moveItem(at: temp, to: destination) } catch {
                        try? fm.removeItem(at: temp)
                        throw error
                    }
                    copied.append(destination)
                }
                guard !pool.contains(where: { $0.id == id }) else { continue }
                if let position = pool.firstIndex(where: { $0.id == s.replacing || $0.packageID == s.package.packageID }) {
                    renames[pool[position].id] = id
                    pool[position] = s.package
                } else {
                    pool.append(s.package)
                }
            }
        } catch {
            undoCopies()
            throw error
        }
        items[index].tweaks = pool
        func renamed(_ list: [TweakUse]) -> [TweakUse] {
            Self.ordered(list.map { u in renames[u.id].map { TweakUse(id: $0, enabled: u.enabled, force: u.force) } ?? u }, pool: pool)
        }
        for i in items[index].installations.indices {
            if let list = items[index].installations[i].tweaks { items[index].installations[i].tweaks = renamed(list) }
        }
        if let pending = items[index].pendingTweakUses { items[index].pendingTweakUses = pending.mapValues(renamed) }
        do { try save() } catch {
            items = previous
            undoCopies()
            throw error
        }
        let held = staged.map(\.package.id)
        reserveTweaks(held, recordID: recordID)
        if !renames.isEmpty { collectUnusedTweaks(recordID: recordID) }
        return held
    }

    /// Sets the tweaks chosen for one device, from its next signing on: ids not in the pool are
    /// left out, each id is kept once, in the pool's load order. A device without an installation
    /// keeps them in `pendingTweakUses`. Returns false when nothing changed.
    @discardableResult
    public func setTweaks(_ uses: [TweakUse], recordID: UUID, deviceID: String) throws -> Bool {
        let index = try indexOf(recordID)
        // A tweak turned back on no longer says why it was off.
        let wanted = Self.ordered(uses, pool: items[index].tweaks ?? []).map { u in
            var u = u
            if u.enabled { u.removedDependency = nil }
            return u
        }
        let previous = items
        let before: [TweakUse]
        if let i = items[index].installations.firstIndex(where: { $0.deviceID == deviceID }) {
            before = items[index].installations[i].tweaks ?? []
            guard before != wanted else { return false }
            items[index].installations[i].tweaks = wanted
        } else {
            before = items[index].pendingTweakUses?[deviceID] ?? []
            guard before != wanted else { return false }
            setPending(wanted, deviceID: deviceID, at: index)
        }
        do { try save() } catch { items = previous; throw error }
        // A tweak removed from the list: its files, and a download no one uses any more, may go
        // now (device round 3: no « Tout nettoyer » left to do it).
        if !Set(before.map(\.id)).isSubset(of: Set(wanted.map(\.id))) {
            collectUnusedTweaks(recordID: recordID)
            // Signed with it or not: a download no list has any more goes (device round 3, F3).
            collectUnusedDownloads(after: "a tweak taken off \(recordID.uuidString) on one device")
        }
        return true
    }

    /// Sets several installations' tweak lists at once (by device id), pool-ordered, in one save:
    /// all or nothing.
    func changeInstallationTweaks(_ lists: [String: [TweakUse]], recordID: UUID) throws {
        let index = try indexOf(recordID)
        let pool = items[index].tweaks ?? []
        let previous = items
        for i in items[index].installations.indices {
            if let uses = lists[items[index].installations[i].deviceID] {
                items[index].installations[i].tweaks = Self.ordered(uses, pool: pool)
            }
        }
        do { try save() } catch { items = previous; throw error }
    }

    /// Drops from the pool the tweaks no device lists, none is waiting for, and no device's last
    /// signing included (asked or injected), with their files; also deletes the other unused
    /// stored folders (a version replaced, a replacement offered before XSide was last started),
    /// except while a tweak is being added. Tweaks in `keeping` or reserved by a running job
    /// (`reserveTweaks`) count as used. Best effort.
    func collectUnusedTweaks(recordID: UUID, keeping: Set<String> = []) {
        guard let index = items.firstIndex(where: { $0.id == recordID }) else { return }
        let record = items[index]
        var used = keeping.union((reservedTweaks[recordID] ?? [:]).keys)
        for i in record.installations {
            used.formUnion((i.tweaks ?? []).map(\.id))
            used.formUnion(i.signedChoices?.tweaks ?? [])
            for (id, result) in i.tweakResults ?? [:] { if case .injected = result { used.insert(id) } }
        }
        for uses in (record.pendingTweakUses ?? [:]).values { used.formUnion(uses.map(\.id)) }
        let pool = record.tweaks ?? []
        let dropped = Set(pool.map(\.id).filter { !used.contains($0) })
        if !dropped.isEmpty {
            let previous = items
            items[index].tweaks = pool.filter { used.contains($0.id) }
            do { try save() } catch {
                items = previous
                Self.logger.error("tweaks of \(recordID.uuidString): unused ones not dropped: \(error.localizedDescription)")
                return
            }
            // A tweak gone from the app, not only the app: a download it was the last to use goes too.
            let fromDownloads = pool.contains { p in
                guard dropped.contains(p.id), case .downloaded = p.origin else { return false }
                return true
            }
            if fromDownloads { collectUnusedDownloads(after: "tweaks of \(recordID.uuidString) dropped") }
        }
        let keep = used.union((items[index].tweaks ?? []).map(\.id)).union(offeredTweaks[recordID] ?? [])
        let folder = tweaksFolder(recordID)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        // An analysis may have just stored a folder (maybe one being dropped here, added again)
        // for a pool it isn't in yet: the folders wait for the next collection.
        guard tweaksInFlight == 0 else { return }
        for name in names where Self.isTweakID(name) && !keep.contains(name) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// A job about to sign with these tweaks holds them until `releaseTweaks`: no collection
    /// deletes them meanwhile (the person may disable or replace one while the job copies it).
    public func reserveTweaks(_ ids: [String], recordID: UUID) {
        for id in ids { reservedTweaks[recordID, default: [:]][id, default: 0] += 1 }
    }

    public func releaseTweaks(_ ids: [String], recordID: UUID) {
        for id in ids {
            guard let n = reservedTweaks[recordID]?[id] else { continue }
            reservedTweaks[recordID]?[id] = n > 1 ? n - 1 : nil
        }
        if reservedTweaks[recordID]?.isEmpty == true { reservedTweaks[recordID] = nil }
    }

    /// The job's list, except for each tweak the person changed (added, removed, enabled,
    /// disabled, forced) since the job started: that one as it is now.
    static func mergedUses(job: [TweakUse]?, start: [TweakUse]?, now: [TweakUse]?, pool: [TweakPackage]) -> [TweakUse]? {
        guard job != nil || now != nil else { return nil }
        func byID(_ uses: [TweakUse]?) -> [String: TweakUse] {
            Dictionary((uses ?? []).map { ($0.id, $0) }) { first, _ in first }
        }
        let j = byID(job), s = byID(start), n = byID(now)
        var seen = Set<String>()
        let ids = ((job ?? []) + (now ?? [])).map(\.id).filter { seen.insert($0).inserted }
        return ordered(ids.compactMap { s[$0] != n[$0] ? n[$0] : j[$0] }, pool: pool)
    }

    /// Duo and signed-out iCloud turned on or off since the job started stay as they are now.
    static func keepChoicesChanged(since start: Installation?, now current: Installation, in stored: inout Installation) {
        if (current.duoCompatibility == true) != (start?.duoCompatibility == true) {
            stored.duoCompatibility = current.duoCompatibility
            if current.duoCompatibility != true { stored.duoCompatibilityMissing = nil }
        }
        if (current.iCloudSignedOut == true) != (start?.iCloudSignedOut == true) {
            stored.iCloudSignedOut = current.iCloudSignedOut
            if current.iCloudSignedOut != true {
                stored.iCloudSignedOutMissing = nil
                stored.iCloudSignedOutSkippedForModule = nil
            }
        }
    }

    private func enable(_ id: String, on deviceIDs: [String], at index: Int) {
        let pool = items[index].tweaks ?? []
        func enabling(_ uses: [TweakUse]) -> [TweakUse] {
            var uses = uses
            if let u = uses.firstIndex(where: { $0.id == id }) { uses[u].enabled = true } else { uses.append(TweakUse(id: id)) }
            return Self.ordered(uses, pool: pool)
        }
        for deviceID in Set(deviceIDs) {
            if let i = items[index].installations.firstIndex(where: { $0.deviceID == deviceID }) {
                items[index].installations[i].tweaks = enabling(items[index].installations[i].tweaks ?? [])
            } else {
                setPending(enabling(items[index].pendingTweakUses?[deviceID] ?? []), deviceID: deviceID, at: index)
            }
        }
    }

    private func setPending(_ uses: [TweakUse], deviceID: String, at index: Int) {
        var pending = items[index].pendingTweakUses ?? [:]
        pending[deviceID] = uses.isEmpty ? nil : uses
        items[index].pendingTweakUses = pending.isEmpty ? nil : pending
    }

    /// Known ids only, each once (its first use), in the pool's order.
    static func ordered(_ uses: [TweakUse], pool: [TweakPackage]) -> [TweakUse] {
        var seen = Set<String>()
        let first = uses.filter { seen.insert($0.id).inserted }
        let position = Dictionary(pool.enumerated().map { ($0.element.id, $0.offset) }) { a, _ in a }
        return first.filter { position[$0.id] != nil }.sorted { position[$0.id]! < position[$1.id]! }
    }

    /// `TweakPackage.id`'s form: 16 lowercase hex digits (never a path).
    static func isTweakID(_ name: String) -> Bool {
        name.utf8.count == 16 && name.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    static func modified(_ url: URL) -> Date? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    // MARK: Leftovers

    /// Removes what a run XSide was killed in the middle of left behind, once it is an hour old
    /// (so work in progress, of this XSide or of another one sharing the folder, is never
    /// touched): `.incoming-*` and `.stale-*` in each app's tweak storage, `.incoming-*` in the
    /// download cache, the install windows' `staging/<UUID>` folders, and, in the temporary folder, only XSide's own `deb-<UUID>`,
    /// `bzip2-<UUID>` and `tweak-src-<UUID>.deb`.
    static func sweepLeftovers(root: URL, temporaryDirectory: URL, now: Date = Date()) {
        let fm = FileManager.default
        let limit = now.addingTimeInterval(-leftoverAge)
        func sweep(_ folder: URL, _ matches: (String) -> Bool) {
            guard isDirectory(folder), let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
            for name in names where matches(name) {
                let url = folder.appendingPathComponent(name)
                guard let date = modified(url), date < limit else { continue }
                try? fm.removeItem(at: url)
            }
        }
        let staging: (String) -> Bool = { $0.hasPrefix(".incoming-") || $0.hasPrefix(".stale-") }
        let apps = root.appendingPathComponent("apps")
        let appNames = isDirectory(apps) ? (try? fm.contentsOfDirectory(atPath: apps.path)) ?? [] : []
        for app in appNames where UUID(uuidString: app) != nil && isDirectory(apps.appendingPathComponent(app)) {
            sweep(apps.appendingPathComponent(app).appendingPathComponent("tweaks"), staging)
        }
        sweep(root.appendingPathComponent("downloads")) { $0.hasPrefix(".incoming-") }
        sweep(root.appendingPathComponent(stagingFolder)) { UUID(uuidString: $0) != nil }
        // The temporary folder is shared and can be large: once per process is enough.
        guard sweptTemporaryFolders.withLock({ $0.insert(temporaryDirectory.standardizedFileURL.path).inserted }) else { return }
        sweep(temporaryDirectory) { name in
            func uuid(_ prefix: String, _ suffix: String = "") -> Bool {
                guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return false }
                return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil
            }
            return uuid("deb-") || uuid("bzip2-") || uuid("tweak-src-", ".deb")
        }
    }
}

// MARK: Download cache

struct FileStamp: Equatable, Sendable {
    var size: Int64
    var inode: UInt64
    var mtime: [Int64]
    var ctime: [Int64]
}

/// A kept download (`AppLibrary.cachedDownloadEntry`): the file and what the index says of it.
public struct CachedDownload: Equatable, Sendable {
    public let url: URL
    public let sha256: String
    public let packageID: String
    public let version: String
    /// The trusted repo's id.
    public let repo: String
    /// The `.deb`'s URL it was downloaded from.
    public let source: String
}

/// One `.deb` XSide downloaded (`downloads/index.json`).
struct DownloadCacheEntry: Codable, Equatable, Sendable {
    var sha256: String
    var packageID: String
    var version: String
    var repo: String
    var url: String
    var downloadedAt: Date
}

extension AppLibrary {
    static let maxDownloadIndexBytes = 4 * 1024 * 1024
    static let maxDownloadEntries = 4096

    private nonisolated var downloadsFolder: URL { root.appendingPathComponent("downloads") }
    private nonisolated var downloadIndexURL: URL { root.appendingPathComponent("downloads/index.json") }
    private nonisolated func downloadURL(_ sha256: String) -> URL { root.appendingPathComponent("downloads/\(sha256).deb") }

    /// Keeps a downloaded `.deb` as `downloads/<sha256>.deb`, checking its bytes against
    /// `sha256` first, and lists it in the index. Returns where it is.
    public func storeDownload(_ file: URL, sha256: String, packageID: String, version: String,
                              repo: String, url: String, now: Date = Date()) throws -> URL {
        let sha = sha256.lowercased()
        guard Self.isSHA256(sha) else { throw TweakError.unreadable("invalid SHA-256") }
        let fm = FileManager.default
        try fm.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)
        let staging = downloadsFolder.appendingPathComponent(".incoming-\(UUID().uuidString)")
        try fm.copyItem(at: file, to: staging)
        do {
            // The copy is what is checked (and kept): the source can't change in between.
            guard Self.hashFile(staging, maxBytes: DebLimits.maxDebBytes) == sha else {
                throw TweakError.unreadable("the download doesn't match its SHA-256")
            }
            let destination = downloadURL(sha)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
            var entries = readDownloadIndex().filter { $0.sha256 != sha }
            entries.append(DownloadCacheEntry(sha256: sha, packageID: packageID, version: version, repo: repo,
                                              url: url, downloadedAt: now))
            try writeDownloadIndex(Array(entries.suffix(Self.maxDownloadEntries)))
            verifiedDownloads[sha] = Self.stamp(destination)
            return destination
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// The cached `.deb` of `packageID` with the highest version that satisfies `satisfying`,
    /// nil when none. Entries whose file is gone, or whose bytes no longer hash to their name,
    /// are dropped (a damaged file is deleted).
    public func cachedDownload(packageID: String, satisfying dependency: DebDependency) -> URL? {
        cachedDownloadEntry(packageID: packageID, satisfying: dependency)?.url
    }

    /// `cachedDownload`, with where the file came from (for its origin and the confirmation).
    public func cachedDownloadEntry(packageID: String, satisfying dependency: DebDependency) -> CachedDownload? {
        let all = readDownloadIndex()
        var entries = all.filter { Self.isSHA256($0.sha256) && Self.isRegularFile(downloadURL($0.sha256)) }
        let candidates = entries.filter { $0.packageID == packageID && dependency.isSatisfied(by: $0.version) }
            .sorted { DebVersion.compare($0.version, $1.version) == .orderedDescending }
        var found: CachedDownload?
        for entry in candidates {
            let url = downloadURL(entry.sha256)
            let hit = CachedDownload(url: url, sha256: entry.sha256, packageID: entry.packageID, version: entry.version,
                                     repo: entry.repo, source: entry.url)
            // Checked before and unchanged since (same size and date): not hashed again.
            if let known = verifiedDownloads[entry.sha256], known == Self.stamp(url) { found = hit; break }
            if Self.hashFile(url, maxBytes: DebLimits.maxDebBytes) == entry.sha256 {
                verifiedDownloads[entry.sha256] = Self.stamp(url)
                found = hit
                break
            }
            verifiedDownloads[entry.sha256] = nil
            Self.logger.error("download cache: \(entry.sha256).deb is damaged, dropped")
            try? FileManager.default.removeItem(at: url)
            entries.removeAll { $0.sha256 == entry.sha256 }
        }
        if entries != all { try? writeDownloadIndex(entries) }
        return found
    }

    /// Every kept download whose file is there, with its size and the apps whose pool uses it
    /// (a package stored with its `.downloaded` origin); by package id, newest first.
    public func downloadUsage() -> [DownloadUsage] {
        var users: [String: Set<String>] = [:]
        var detail: [String: [DownloadUser]] = [:]
        var installations: [String: [DownloadInstallation]] = [:]
        for record in items {
            let pool = record.tweaks ?? []
            let lists = Self.deviceLists(record)
            for p in pool {
                guard case .downloaded(_, _, let raw) = p.origin else { continue }
                // Real use only (device round 3, F3): a device's list has it. A copy kept in the
                // pool for what an app was last signed with doesn't count.
                guard lists.values.contains(where: { $0.contains { $0.id == p.id } }) else { continue }
                let sha = raw.lowercased()
                users[sha, default: []].insert(record.displayName)
                for (deviceID, list) in lists where list.contains(where: { $0.id == p.id }) {
                    let on = Set(list.filter(\.enabled).map(\.id))
                    let names = DependencyRows.dependents(of: p, among: pool).filter { on.contains($0.id) }.map(\.name)
                    if let k = installations[sha]?.firstIndex(where: { $0.recordID == record.id && $0.deviceID == deviceID }) {
                        let had = installations[sha]![k]
                        installations[sha]![k] = DownloadInstallation(recordID: record.id, app: record.displayName, deviceID: deviceID,
                                                                      tweaks: had.tweaks + names.filter { !had.tweaks.contains($0) })
                    } else {
                        installations[sha, default: []].append(DownloadInstallation(recordID: record.id, app: record.displayName,
                                                                                    deviceID: deviceID, tweaks: names))
                    }
                }
                let tweaks = DependencyRows.dependents(of: p, among: pool).map { t in
                    DownloadUser.Tweak(name: t.name, deviceIDs: lists.filter { $0.value.contains { $0.id == t.id && $0.enabled } }
                                        .map(\.key).sorted())
                }
                if !(detail[sha] ?? []).contains(where: { $0.app == record.displayName && $0.tweaks == tweaks }) {
                    detail[sha, default: []].append(DownloadUser(app: record.displayName, tweaks: tweaks))
                }
            }
        }
        return readDownloadIndex().compactMap { e -> DownloadUsage? in
            let sha = e.sha256.lowercased()
            guard Self.isSHA256(sha), let stamp = Self.stamp(downloadURL(sha)) else { return nil }
            return DownloadUsage(sha256: sha, packageID: e.packageID, version: e.version, repo: e.repo,
                                 repoName: DependencySources.name(forRepoID: e.repo),
                                 size: stamp.size, downloadedAt: e.downloadedAt, apps: (users[sha] ?? []).sorted(),
                                 users: (detail[sha] ?? []).sorted { $0.app < $1.app },
                                 installations: (installations[sha] ?? []).sorted { ($0.deviceID, $0.app) < ($1.deviceID, $1.app) })
        }
        .sorted {
            $0.packageID != $1.packageID ? $0.packageID < $1.packageID
                : DebVersion.compare($0.version, $1.version) == .orderedDescending
        }
    }

    /// Every device's tweak list: its installation's, else the one waiting for its first install.
    static func deviceLists(_ record: AppRecord) -> [String: [TweakUse]] {
        var lists = record.pendingTweakUses ?? [:]
        for i in record.installations { if let t = i.tweaks { lists[i.deviceID] = t } }
        return lists
    }

    /// « Désinstaller… » (Settings > Tweaks, device round 3): takes the packages stored from this
    /// download off the lists of `targets` (app × device), from their next signing, and turns off
    /// there the tweaks of `disabling` (`DependencyRows.disabledByUninstalling`), saying why
    /// (`TweakUse.removedDependency` = `name`): a deliberate removal is never « À régler ». One
    /// save, all or nothing. Once no installation (nor a device waiting for its first install)
    /// lists a package from it, the file is deleted (it only feeds new copies: what an app was
    /// signed with stays in its own folder). Never while a tweak is being analysed. Returns true
    /// when the file was deleted.
    @discardableResult
    public func uninstallDownload(sha256: String, from targets: Set<DownloadInstallation.Key>,
                                  disabling: [DownloadInstallation.Key: Set<String>], name: String) throws -> Bool {
        let sha = sha256.lowercased()
        guard Self.isSHA256(sha) else { return false }
        func fromIt(_ p: TweakPackage) -> Bool {
            if case .downloaded(_, _, let s) = p.origin { s.lowercased() == sha } else { false }
        }
        let previous = items
        var touched: [UUID] = []
        for index in items.indices {
            let ids = Set((items[index].tweaks ?? []).filter(fromIt).map(\.id))
            guard !ids.isEmpty else { continue }
            let recordID = items[index].id
            func change(_ uses: [TweakUse], _ key: DownloadInstallation.Key) -> [TweakUse]? {
                guard uses.contains(where: { ids.contains($0.id) }) else { return nil }
                let off = disabling[key] ?? []
                return uses.filter { !ids.contains($0.id) }.map { u in
                    guard off.contains(u.id), u.enabled else { return u }
                    return TweakUse(id: u.id, enabled: false, force: nil, removedDependency: name)
                }
            }
            for key in targets where key.recordID == recordID {
                if let i = items[index].installations.firstIndex(where: { $0.deviceID == key.deviceID }) {
                    guard let uses = items[index].installations[i].tweaks, let changed = change(uses, key) else { continue }
                    items[index].installations[i].tweaks = changed
                } else {
                    guard let uses = items[index].pendingTweakUses?[key.deviceID], let changed = change(uses, key) else { continue }
                    setPending(changed, deviceID: key.deviceID, at: index)
                }
                if !touched.contains(recordID) { touched.append(recordID) }
            }
        }
        guard !touched.isEmpty else { return false }
        do { try save() } catch { items = previous; throw error }
        Self.logger.notice("download cache: \(sha).deb uninstalled from \(targets.count) installation(s)")
        for id in touched { collectUnusedTweaks(recordID: id) }
        let stillListed = items.contains { r in
            let ids = Set((r.tweaks ?? []).filter(fromIt).map(\.id))
            return !ids.isEmpty && Self.deviceLists(r).values.contains { $0.contains { ids.contains($0.id) } }
        }
        guard !stillListed, tweaksInFlight == 0, Self.isRegularFile(downloadURL(sha)) else { return false }
        removeDownload(sha256: sha)
        Self.logger.notice("download cache: \(sha).deb deleted, no installation uses it any more")
        return true
    }

    /// Deletes a kept download no device's list uses. False (nothing deleted) when one does, or
    /// for an id that isn't a SHA-256.
    @discardableResult
    public func removeUnusedDownload(sha256: String) -> Bool {
        let sha = sha256.lowercased()
        guard Self.isSHA256(sha) else { return false }
        // Used: a device's list (or the one waiting for its first install) has a package from it.
        // What an app was last signed with is in its own folder: the file isn't needed for it.
        let used = items.contains { r in
            let ids = Set((r.tweaks ?? []).filter {
                if case .downloaded(_, _, let s) = $0.origin { s.lowercased() == sha } else { false }
            }.map(\.id))
            return !ids.isEmpty && Self.deviceLists(r).values.contains { $0.contains { ids.contains($0.id) } }
        }
        guard !used else { return false }
        removeDownload(sha256: sha)
        return true
    }

    /// « Tout nettoyer »: every kept download no app uses. How many and how many bytes went.
    public func removeUnusedDownloads() -> (count: Int, bytes: Int64) {
        var count = 0, bytes: Int64 = 0
        for u in downloadUsage() where !u.isUsed {
            if removeUnusedDownload(sha256: u.sha256) { count += 1; bytes += u.size }
        }
        return (count, bytes)
    }

    /// Forgets a kept download: its index entry and its file.
    public func removeDownload(sha256: String) {
        let sha = sha256.lowercased()
        guard Self.isSHA256(sha) else { return }
        verifiedDownloads[sha] = nil
        let all = readDownloadIndex()
        let kept = all.filter { $0.sha256 != sha }
        if kept != all { try? writeDownloadIndex(kept) }
        try? FileManager.default.removeItem(at: downloadURL(sha))
        Self.logger.notice("download cache: \(sha).deb dropped")
    }

    private func readDownloadIndex() -> [DownloadCacheEntry] {
        var st = stat()
        guard lstat(downloadIndexURL.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              st.st_size <= Self.maxDownloadIndexBytes,
              let data = try? Data(contentsOf: downloadIndexURL) else { return [] }
        struct Lossy: Decodable {
            let entry: DownloadCacheEntry?
            init(from decoder: any Decoder) throws { entry = try? DownloadCacheEntry(from: decoder) }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = (try? decoder.decode([Lossy].self, from: data))?.compactMap(\.entry) ?? []
        return Array(entries.prefix(Self.maxDownloadEntries))
    }

    private func writeDownloadIndex(_ entries: [DownloadCacheEntry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(entries)
        let fm = FileManager.default
        try fm.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)
        let temp = downloadsFolder.appendingPathComponent(".incoming-\(UUID().uuidString)")
        try data.write(to: temp)
        do {
            if fm.fileExists(atPath: downloadIndexURL.path) {
                _ = try fm.replaceItemAt(downloadIndexURL, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: downloadIndexURL)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Size, modification and status-change times of a regular file (nil otherwise).
    static func stamp(_ url: URL) -> FileStamp? {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileStamp(size: Int64(st.st_size), inode: UInt64(st.st_ino),
                         mtime: [Int64(st.st_mtimespec.tv_sec), Int64(st.st_mtimespec.tv_nsec)],
                         ctime: [Int64(st.st_ctimespec.tv_sec), Int64(st.st_ctimespec.tv_nsec)])
    }

    static func isSHA256(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
    }

    /// Lowercase hex SHA-256 of a regular file (links not followed), nil when unreadable or
    /// larger than `maxBytes`.
    static func hashFile(_ url: URL, maxBytes: Int) -> String? {
        guard isRegularFile(url) else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var hasher = SHA256()
        var total = 0
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            total += chunk.count
            if total > maxBytes { return nil }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
