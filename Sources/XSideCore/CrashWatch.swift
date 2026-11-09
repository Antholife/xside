import Foundation

/// A crash XSide tells the person about on the app's row (and once in a notification): found by
/// the check after an install, or by the quiet look at the device's crash logs later.
public struct CrashFlag: Codable, Equatable, Sendable {
    /// The crash file (its name on the device): one file is announced once.
    public let fileName: String
    public let diagnosis: CrashDiagnosis
    public let raisedAt: Date
    /// An install or refresh succeeded after this crash: the next check that finds no newer crash
    /// clears the flag.
    public var supersededAt: Date?

    public init(fileName: String, diagnosis: CrashDiagnosis, raisedAt: Date, supersededAt: Date? = nil) {
        self.fileName = fileName
        self.diagnosis = diagnosis
        self.raisedAt = raisedAt
        self.supersededAt = supersededAt
    }

    /// When the app crashed (the file's date when the log has none).
    public var crashDate: Date { diagnosis.date ?? raisedAt }
}

/// What a crash the app can fix itself suggests, as a button next to the diagnosis.
public enum CrashAction: String, Codable, Sendable, CaseIterable {
    /// The crash is in XSide's module: install the app again without XSide's features.
    case reinstallWithoutXSide
    /// The iPhone Duo option's SDK raise makes iOS ask for scenes the app doesn't have.
    case turnOffDuo
    /// A signature problem: signing it again is the fix.
    case refresh

    /// The action the diagnosis suggests, if XSide can do it. A tweak XSide added would be
    /// removed here; XSide doesn't add tweaks yet, so a tweak crash has no button.
    public static func suggested(for d: CrashDiagnosis) -> CrashAction? {
        switch d.cause {
        case .xsideModule: return .reinstallWithoutXSide
        case .noSceneSupport: return d.duoCompatibilityOn ? .turnOffDuo : nil
        case .codeSignature: return .refresh
        default: return nil
        }
    }
}

/// Which crashes XSide is telling the person about, by installation, and the bookkeeping of the
/// quiet look at each device's crash logs: when it last ran (at most once an hour per device)
/// and which crash files it already read (each one is read, and announced, once).
///
/// A flag is set when the check after an install, or the quiet look, finds a crash of the
/// installation newer than its install, newer than the last time the app was seen running, and
/// not dismissed. It goes when the person dismisses it, when the app is seen running after the
/// crash (a check-in from XSide's module, or still up after XSide opened it), or when an install
/// or refresh succeeded and the next check found no newer crash.
public struct CrashWatch: Codable, Equatable, Sendable {
    /// The quiet look runs at most this often per device.
    public static let scanInterval: TimeInterval = 3600
    /// Crash files copied per look at most: the device keeps the others for the next one.
    public static let maxFilesPerScan = 3
    /// A device never looked at: how far back the first look goes.
    public static let firstLookback: TimeInterval = 24 * 3600
    /// Read files are remembered this long (the device removes old logs by itself).
    public static let seenKeep: TimeInterval = 14 * 86_400
    /// A crash a little before the install's date is still the install's (clocks, file dates).
    public static let installSlack: TimeInterval = 120

    public private(set) var flags: [String: CrashFlag] = [:]
    /// Crash files already read, by device (file name → when).
    private var seen: [String: [String: Date]] = [:]
    /// Crash files whose flag the person dismissed, by installation.
    private var dismissed: [String: Set<String>] = [:]
    /// When each device's crash logs were last looked at.
    private var lastScan: [String: Date] = [:]
    /// When each installation's app was last seen running.
    private var lastLaunch: [String: Date] = [:]

    public init() {}

    public static func key(recordID: UUID, deviceID: String) -> String { "\(recordID.uuidString)|\(deviceID)" }

    public func flag(recordID: UUID, deviceID: String) -> CrashFlag? {
        flags[Self.key(recordID: recordID, deviceID: deviceID)]
    }

    // MARK: The quiet look

    /// The device's crash logs are due for a look (never looked at, or over `scanInterval` ago).
    public func shouldScan(deviceID: String, now: Date) -> Bool {
        lastScan[deviceID].map { now.timeIntervalSince($0) >= Self.scanInterval || $0 > now } ?? true
    }

    /// Starts a look at the device's crash logs: returns the date files must be newer than (the
    /// last look, or `firstLookback` ago for the first one). Counted even if it fails, so a device
    /// that can't answer isn't asked again before the interval.
    public mutating func scanStarted(deviceID: String, now: Date) -> Date {
        let since = lastScan[deviceID].map { min($0, now) } ?? now.addingTimeInterval(-Self.firstLookback)
        lastScan[deviceID] = now
        return since
    }

    /// The crash file was read (by any look): never read nor announced again.
    public func isSeen(fileName: String, deviceID: String) -> Bool { seen[deviceID]?[fileName] != nil }

    public mutating func markSeen(fileName: String, deviceID: String, at date: Date) {
        seen[deviceID, default: [:]][fileName] = date
    }

    /// The crash files already read on the device.
    public func seenFiles(deviceID: String) -> Set<String> { Set((seen[deviceID] ?? [:]).keys) }

    // MARK: Flags

    /// A crash of the installation was found: flags it unless it predates the install (`installedAt`)
    /// or the last time the app was seen running, was dismissed, or is already flagged (or older
    /// than the flag). True when the flag is new: worth a notification.
    @discardableResult
    public mutating func raise(recordID: UUID, deviceID: String, fileName: String, diagnosis: CrashDiagnosis,
                               installedAt: Date, now: Date) -> Bool {
        markSeen(fileName: fileName, deviceID: deviceID, at: now)
        let key = Self.key(recordID: recordID, deviceID: deviceID)
        let date = diagnosis.date ?? now
        guard dismissed[key]?.contains(fileName) != true,
              date >= installedAt.addingTimeInterval(-Self.installSlack),
              lastLaunch[key].map({ date > $0 }) ?? true else { return false }
        if let current = flags[key], current.fileName == fileName || current.crashDate > date { return false }
        flags[key] = CrashFlag(fileName: fileName, diagnosis: diagnosis, raisedAt: now)
        return true
    }

    /// "Ignore": the flag goes, and that crash file never flags the installation again.
    public mutating func dismiss(recordID: UUID, deviceID: String) {
        let key = Self.key(recordID: recordID, deviceID: deviceID)
        guard let flag = flags.removeValue(forKey: key) else { return }
        dismissed[key, default: []].insert(flag.fileName)
    }

    /// The app was seen running at `date` (a check-in, or still up after XSide opened it): a flag
    /// for an earlier crash goes. True when a flag went.
    @discardableResult
    public mutating func launchSeen(recordID: UUID, deviceID: String, at date: Date) -> Bool {
        let key = Self.key(recordID: recordID, deviceID: deviceID)
        lastLaunch[key] = max(lastLaunch[key] ?? date, date)
        guard let flag = flags[key], flag.crashDate < date else { return false }
        flags[key] = nil
        return true
    }

    /// An install or refresh of the installation succeeded at `date`: its flag waits for the next
    /// check, which clears it unless it finds a newer crash.
    public mutating func installed(recordID: UUID, deviceID: String, at date: Date) {
        let key = Self.key(recordID: recordID, deviceID: deviceID)
        guard flags[key] != nil, flags[key]!.crashDate < date else { return }
        flags[key]?.supersededAt = date
    }

    /// A check made at `checkedAt` found no crash of the installation newer than its last install:
    /// a flag an install or refresh before then superseded goes. True when a flag went.
    @discardableResult
    public mutating func noNewCrash(recordID: UUID, deviceID: String, checkedAt: Date) -> Bool {
        let key = Self.key(recordID: recordID, deviceID: deviceID)
        guard let superseded = flags[key]?.supersededAt, superseded <= checkedAt else { return false }
        flags[key] = nil
        return true
    }

    /// The installation is gone (uninstalled, forgotten): nothing kept about it.
    public mutating func forget(recordID: UUID, deviceID: String) {
        let key = Self.key(recordID: recordID, deviceID: deviceID)
        flags[key] = nil
        dismissed[key] = nil
        lastLaunch[key] = nil
    }

    /// The device is gone from XSide.
    public mutating func forgetDevice(_ deviceID: String) {
        let suffix = "|\(deviceID)"
        for key in flags.keys where key.hasSuffix(suffix) { flags[key] = nil }
        for key in dismissed.keys where key.hasSuffix(suffix) { dismissed[key] = nil }
        for key in lastLaunch.keys where key.hasSuffix(suffix) { lastLaunch[key] = nil }
        seen[deviceID] = nil
        lastScan[deviceID] = nil
    }

    /// Drops read files older than `seenKeep`, and flags and dismissals of installations no longer
    /// in `keys` (`key(recordID:deviceID:)`).
    public mutating func prune(keeping keys: Set<String>, now: Date) {
        for device in seen.keys {
            seen[device] = seen[device]?.filter { now.timeIntervalSince($0.value) < Self.seenKeep }
            if seen[device]?.isEmpty == true { seen[device] = nil }
        }
        flags = flags.filter { keys.contains($0.key) }
        dismissed = dismissed.filter { keys.contains($0.key) }
        lastLaunch = lastLaunch.filter { keys.contains($0.key) }
    }
}

extension CrashLogListing {
    /// The quiet look's picks: crash logs (not JetsamEvents) of one of `executables` (the XSide
    /// apps on the device), dated since `since`, not read before, newest first, `limit` at most.
    public static func newCrashFiles(_ entries: [CrashLogEntry], executables: Set<String>, since: Date,
                                     seen: Set<String>, limit: Int = CrashWatch.maxFilesPerScan) -> [CrashLogEntry] {
        let names = Set(executables.map(normalized))
        let picked = entries.filter { entry in
            guard !entry.relativePath.hasPrefix("ProxiedDevice-"),
                  let size = entry.size, size >= 0, size <= CrashLogParser.maxBytes,
                  let modified = entry.modified, modified >= since.addingTimeInterval(-slack),
                  let part = entry.processPart, part != "JetsamEvent", names.contains(normalized(part)) else { return false }
            return !seen.contains((entry.relativePath as NSString).lastPathComponent)
        }
        return Array(picked.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }.prefix(limit))
    }
}

/// Keeps `CrashWatch` in the library folder (`crash-watch.json`): a flag outlives a restart.
public struct CrashWatchStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public init(libraryRoot: URL) {
        self.init(url: libraryRoot.appendingPathComponent("crash-watch.json"))
    }

    /// An empty watch when there's none or it can't be read.
    public func load() -> CrashWatch {
        guard let data = try? Data(contentsOf: url), let watch = try? JSONDecoder().decode(CrashWatch.self, from: data) else { return CrashWatch() }
        return watch
    }

    public func save(_ watch: CrashWatch) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(watch).write(to: url, options: .atomic)
    }
}
