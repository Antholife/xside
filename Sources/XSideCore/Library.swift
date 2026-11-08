import Foundation
import os

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

    public init(deviceID: String, installedAt: Date, expiresAt: Date,
                lastAttempt: Date? = nil, lastErrorKey: String? = nil, signedBundleID: String? = nil,
                signingIdentitySHA1: String? = nil, teamID: String? = nil, refreshPaused: Bool = false,
                appVersion: String? = nil, inApp: InAppSettings? = nil, pausedBy: ChangeOrigin? = nil,
                firstInstalledAt: Date? = nil, lastRefreshOutcome: RefreshOutcome? = nil,
                channelSecret: Data? = nil, lastCheckIn: Date? = nil) {
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
        appVersion = try? c.decodeIfPresent(String.self, forKey: .appVersion)
        inApp = try? c.decodeIfPresent(InAppSettings.self, forKey: .inApp)
        pausedBy = try? c.decodeIfPresent(ChangeOrigin.self, forKey: .pausedBy)
        firstInstalledAt = try? c.decodeIfPresent(Date.self, forKey: .firstInstalledAt)
        lastRefreshOutcome = try? c.decodeIfPresent(RefreshOutcome.self, forKey: .lastRefreshOutcome)
        channelSecret = try? c.decodeIfPresent(Data.self, forKey: .channelSecret)
        lastCheckIn = try? c.decodeIfPresent(Date.self, forKey: .lastCheckIn)
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
    private var stateURL: URL { root.appendingPathComponent("state.json") }
    private var backupURL: URL { root.appendingPathComponent("state.json.bak") }

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        (items, loadIssue) = Self.load(root: root)
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
            record = items[index]
        } else {
            record = AppRecord(id: id, displayName: info.name, originalBundleID: info.bundleID,
                               signedBundleID: signed, ipaPath: relative,
                               options: InstallOptions(), installations: [], teamID: teamID)
            record.version = info.version
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
    public func removeInstallation(recordID: UUID, deviceID: String) throws -> Bool {
        let index = try indexOf(recordID)
        guard items[index].installations.contains(where: { $0.deviceID == deviceID }) else { return false }
        let previous = items
        items[index].installations.removeAll { $0.deviceID == deviceID }
        do { try save() } catch { items = previous; throw error }
        return true
    }

    /// Pauses (or resumes) XSide's refreshes of one installation, without touching the device.
    /// `by`: who did it (the Mac panel, or the phone through the channel), recorded with the
    /// installation's "automatic refresh" setting so the app learns of it. Returns false when there
    /// was no such installation, or it was already in that state.
    @discardableResult
    public func setRefreshPaused(_ paused: Bool, recordID: UUID, deviceID: String,
                                 by origin: ChangeOrigin = .mac, at date: Date = Date()) throws -> Bool {
        let index = try indexOf(recordID)
        guard let i = items[index].installations.firstIndex(where: { $0.deviceID == deviceID }),
              items[index].installations[i].refreshPaused != paused else { return false }
        let previous = items
        Self.applyPause(paused, by: origin, at: date, to: &items[index].installations[i])
        do { try save() } catch { items = previous; throw error }
        return true
    }

    private static func applyPause(_ paused: Bool, by origin: ChangeOrigin, at date: Date,
                                   to installation: inout Installation) {
        installation.refreshPaused = paused
        installation.pausedBy = paused ? origin : nil
        installation.inApp = installation.inApp?.setting(\.autoRefresh, to: !paused, at: date, by: origin)
        // Resuming: no retry delay left over from before the pause, a due app goes at once.
        if !paused { installation.lastAttempt = nil }
    }

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
        installation.inApp = settings
        installation.lastCheckIn = checkIn
        if let outcome { installation.lastRefreshOutcome = outcome }
        var change: Bool?
        if installation.refreshPaused == settings.autoRefresh.value {
            let paused = !settings.autoRefresh.value
            installation.refreshPaused = paused
            installation.pausedBy = paused ? settings.autoRefresh.changedBy : nil
            if !paused { installation.lastAttempt = nil }
            change = paused
        }
        items[index].installations[i] = installation
        do { try save() } catch { items = previous; throw error }
        return change
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
    public func recordSigning(_ installation: Installation, for id: UUID, requireExisting: Bool) throws -> Installation {
        let index = try indexOf(id)
        let current = items[index].installations.first { $0.deviceID == installation.deviceID }
        let stored = current.map { installation.keepingChannelState(of: $0) } ?? installation
        try upsert(stored, for: id, requireExisting: requireExisting)
        return stored
    }

    /// Forgets a device: drops its installations from every record and deletes the records left
    /// with none (with their files), except those in `keeping` (a job is installing them on another
    /// device right now). One atomic save. Returns the number of installations removed.
    /// Nothing is uninstalled from the device itself.
    @discardableResult
    public func removeDevice(_ deviceID: String, keeping: Set<UUID> = []) throws -> Int {
        let previous = items
        var removed = 0
        var emptied: [UUID] = []
        for index in items.indices {
            let before = items[index].installations.count
            items[index].installations.removeAll { $0.deviceID == deviceID }
            let dropped = before - items[index].installations.count
            removed += dropped
            if dropped > 0, items[index].installations.isEmpty, !keeping.contains(items[index].id) {
                emptied.append(items[index].id)
            }
        }
        guard removed > 0 else { return 0 }
        items.removeAll { emptied.contains($0.id) }
        do { try save() } catch { items = previous; throw error }
        for id in emptied {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("apps/\(id.uuidString)"))
        }
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
