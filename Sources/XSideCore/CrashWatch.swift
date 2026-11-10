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
    /// The app stopped while in use (its module said so at the next launch, or its live connection
    /// dropped without a goodbye): the app running again doesn't end this notice; the next run
    /// that ends cleanly does (or Ignore, or a reinstall followed by a check finding nothing newer).
    /// Optional: older crash-watch.json files have none (nil is false).
    public var duringUse: Bool?

    public init(fileName: String, diagnosis: CrashDiagnosis, raisedAt: Date, supersededAt: Date? = nil,
                duringUse: Bool? = nil) {
        self.fileName = fileName
        self.diagnosis = diagnosis
        self.raisedAt = raisedAt
        self.supersededAt = supersededAt
        self.duringUse = duringUse
    }

    /// When the app crashed (the file's date when the log has none).
    public var crashDate: Date { diagnosis.date ?? raisedAt }
}

/// What a crash the app can fix itself suggests, as a button next to the diagnosis.
public enum CrashAction: String, Codable, Sendable, CaseIterable {
    /// The crash is in XSide's module: install the app again without XSide's features.
    case reinstallWithoutXSide
    /// The iPhone Duo option's SDK raise makes iOS ask for scenes the app doesn't have, or the
    /// crash is in the option's compatibility module: install again without the option.
    case turnOffDuo
    /// A signature problem: signing it again is the fix.
    case refresh
    /// The app stopped in CloudKit: "Simulate signed-out iCloud" makes it believe no account is signed in.
    case turnOnICloudSignedOut
    /// The crash is in "Simulate signed-out iCloud"'s library: install again without the option.
    case turnOffICloudSignedOut
    /// The crash is in a tweak XSide injected: disable it (it stays in the app's pool) and sign again.
    case disableTweak
    /// The crash is in what XSide added for converted tweaks (ElleKit, the support library, an
    /// embedded dependency): disable every converted tweak and sign again.
    case disableConvertedTweaks

    /// The action the diagnosis suggests, if XSide can do it. A library the .ipa came with
    /// (`bundledLibrary`) isn't XSide's to remove: no button.
    public static func suggested(for d: CrashDiagnosis) -> CrashAction? {
        switch d.cause {
        case .xsideModule: return .reinstallWithoutXSide
        case .noSceneSupport: return d.duoCompatibilityOn ? .turnOffDuo : nil
        // Only the Duo option adds that module: going without it is the fix.
        case .duoLegacyModule, .duoAppLaunch: return .turnOffDuo
        case .codeSignature: return .refresh
        // Only that option adds the library: going without it is the fix.
        case .iCloudShim: return .turnOffICloudSignedOut
        case .iCloud: return d.iCloudSignedOutOn == true ? nil : .turnOnICloudSignedOut
        // `.tweak` is only a tweak XSide injected (`CrashContext.tweakNames`).
        case .tweak, .tweakCFunctionHook: return .disableTweak
        case .tweakSupport: return .disableConvertedTweaks
        default: return nil
        }
    }
}

/// Which crashes XSide is telling the person about, by installation, and the bookkeeping of the
/// quiet look at each device's crash logs: when it last ran (how often: `CrashScanSchedule`) and
/// which crash files it already read (each one is read, and announced, once).
///
/// A flag is set when the check after an install, or the quiet look, finds a crash of the
/// installation newer than its install, newer than the last time the app was seen running, and
/// not dismissed. It goes when the person dismisses it, when the app is seen running after the
/// crash (a check-in from XSide's module, or still up after XSide opened it), or when an install
/// or refresh succeeded and the next check found no newer crash. A crash while the app was in use
/// (`CrashFlag.duringUse`: reported by the module at the next launch, or the live connection
/// dropped) stays through the next launch and goes when a later run ends cleanly.
public struct CrashWatch: Codable, Equatable, Sendable {
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
    /// The last run each installation's module reported as crashed (its `since`): looked at once.
    /// Optional: older files have none.
    private var reportedRuns: [String: Date]?
    /// Crash files a crash fix answered, by installation: never raised again (the look that
    /// checks the fix reaches back a minute and read it again). Optional: older files have none.
    private var answered: [String: Set<String>]?
    /// Crash files already announced (notified), by installation, and when: one raised again
    /// (cleared by a launch, then read again by the look that launch asks for) comes back without
    /// a second notification (mega review K2). Optional: older files have none.
    private var announced: [String: [String: Date]]?

    public init() {}

    public static func key(recordID: UUID, deviceID: String) -> String { "\(recordID.uuidString)|\(deviceID)" }

    public func flag(recordID: UUID, deviceID: String) -> CrashFlag? {
        flags[Self.key(recordID: recordID, deviceID: deviceID)]
    }

    // MARK: The quiet look

    /// The date a look at the device's crash logs starting now reads files from: the start of the
    /// last complete look, or `firstLookback` ago for the first one. Read only (mega review K1): a
    /// look that fails moves nothing, so the next one reads what it missed.
    public func scanSince(deviceID: String, now: Date) -> Date {
        lastScan[deviceID].map { min($0, now) } ?? now.addingTimeInterval(-Self.firstLookback)
    }

    /// A look started at `startedAt` listed the device's logs. `complete`: it read everything new
    /// it found (the per-look cap left none, and every file it picked was read); only then does the
    /// next look start from `startedAt`. Otherwise it starts where this one did, and the files read
    /// are skipped (`seen`), so the older ones still come.
    public mutating func scanSucceeded(deviceID: String, startedAt: Date, complete: Bool) {
        guard complete else { return }
        lastScan[deviceID] = max(lastScan[deviceID] ?? startedAt, startedAt)
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
    ///
    /// `inUseSince`: the crash ended a run in use that began then (the module reported it at the
    /// next launch, or the live connection opened then dropped): the crash must be of that run
    /// (not before it, give or take `runSlack`) instead of after the last time the app was seen
    /// running (which the next launch's check-in already moved past it), and the flag is
    /// `duringUse`.
    @discardableResult
    public mutating func raise(recordID: UUID, deviceID: String, fileName: String, diagnosis: CrashDiagnosis,
                               installedAt: Date, now: Date, inUseSince: Date? = nil) -> Bool {
        markSeen(fileName: fileName, deviceID: deviceID, at: now)
        let key = Self.key(recordID: recordID, deviceID: deviceID)
        let date = diagnosis.date ?? now
        guard dismissed[key]?.contains(fileName) != true, answered?[key]?.contains(fileName) != true,
              date >= installedAt.addingTimeInterval(-Self.installSlack) else { return false }
        if let inUseSince {
            guard date >= inUseSince.addingTimeInterval(-Self.runSlack) else { return false }
        } else {
            guard lastLaunch[key].map({ date > $0 }) ?? true else { return false }
        }
        if let current = flags[key], current.fileName == fileName || current.crashDate > date { return false }
        flags[key] = CrashFlag(fileName: fileName, diagnosis: diagnosis, raisedAt: now,
                               duringUse: inUseSince == nil ? nil : true)
        if announced?[key]?[fileName] != nil { return false }
        announced = announced ?? [:]
        announced?[key, default: [:]][fileName] = now
        return true
    }

    /// A crash a little before the run's start is still the run's (clocks, file dates).
    public static let runSlack: TimeInterval = 60

    /// What a check-in's `previousRun` asks of the Mac.
    public enum RunReport: Equatable, Sendable {
        /// Nothing to do (already looked at for that run, or nothing to clear).
        case nothing
        /// The previous run stopped while in use: look at the device's crash logs now, for a crash
        /// since `since` (raise it with `inUseSince: since`).
        case lookForCrash(since: Date)
        /// A run that began after the crash ended cleanly: the in-use crash notice went.
        case cleared
    }

    /// The module reported how the installation's previous run ended. "crashed": looked at once
    /// per run (the phone sends it until acknowledged; a lost reply repeats it). "clean": a crash
    /// notice `duringUse` older than that run's start goes.
    public mutating func previousRunReported(recordID: UUID, deviceID: String, run: PreviousRun) -> RunReport {
        let key = Self.key(recordID: recordID, deviceID: deviceID)
        switch run.ended {
        case .crashed:
            if reportedRuns?[key] == run.since { return .nothing }
            reportedRuns = (reportedRuns ?? [:]).merging([key: run.since]) { $1 }
            return .lookForCrash(since: run.since)
        case .clean:
            guard let flag = flags[key], flag.duringUse == true, flag.crashDate < run.since else { return .nothing }
            flags[key] = nil
            return .cleared
        }
    }

    /// "Ignore": the flag goes, and that crash file never flags the installation again.
    public mutating func dismiss(recordID: UUID, deviceID: String) {
        let key = Self.key(recordID: recordID, deviceID: deviceID)
        guard let flag = flags.removeValue(forKey: key) else { return }
        dismissed[key, default: []].insert(flag.fileName)
    }

    /// A crash fix starts for the installation's flagged crash and for the crash it was diagnosed
    /// from (`fileName`, which may not be flagged: mega review K6): those files are answered.
    public mutating func fixStarted(recordID: UUID, deviceID: String, fileName: String? = nil) {
        let key = Self.key(recordID: recordID, deviceID: deviceID)
        let files = [flags[key]?.fileName, fileName].compactMap { $0 }
        guard !files.isEmpty else { return }
        answered = answered ?? [:]
        answered?[key, default: []].formUnion(files)
    }

    /// The person dealt with that crash file (dismissed it, or a fix answered it): never raised again.
    public func isSettled(recordID: UUID, deviceID: String, fileName: String) -> Bool {
        let key = Self.key(recordID: recordID, deviceID: deviceID)
        return dismissed[key]?.contains(fileName) == true || answered?[key]?.contains(fileName) == true
    }

    /// The app was seen running at `date` (a check-in, or still up after XSide opened it): a flag
    /// for an earlier crash goes, unless it stopped while in use (`duringUse`: running again is
    /// expected then). True when a flag went.
    @discardableResult
    public mutating func launchSeen(recordID: UUID, deviceID: String, at date: Date) -> Bool {
        let key = Self.key(recordID: recordID, deviceID: deviceID)
        lastLaunch[key] = max(lastLaunch[key] ?? date, date)
        guard let flag = flags[key], flag.duringUse != true, flag.crashDate < date else { return false }
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
        reportedRuns?[key] = nil
        answered?[key] = nil
        announced?[key] = nil
    }

    /// The device is gone from XSide.
    public mutating func forgetDevice(_ deviceID: String) {
        let suffix = "|\(deviceID)"
        for key in flags.keys where key.hasSuffix(suffix) { flags[key] = nil }
        for key in dismissed.keys where key.hasSuffix(suffix) { dismissed[key] = nil }
        for key in lastLaunch.keys where key.hasSuffix(suffix) { lastLaunch[key] = nil }
        reportedRuns = reportedRuns?.filter { !$0.key.hasSuffix(suffix) }
        answered = answered?.filter { !$0.key.hasSuffix(suffix) }
        announced = announced?.filter { !$0.key.hasSuffix(suffix) }
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
        if let runs = reportedRuns { reportedRuns = runs.filter { keys.contains($0.key) } }
        if let a = answered { answered = a.filter { keys.contains($0.key) } }
        if let a = announced {
            announced = a.filter { keys.contains($0.key) }
                .mapValues { $0.filter { now.timeIntervalSince($0.value) < Self.seenKeep } }
                .filter { !$0.value.isEmpty }
        }
    }
}

extension CrashLogListing {
    /// The quiet look's picks: crash logs (not JetsamEvents) of one of `executables` (the XSide
    /// apps on the device), dated since `since`, not read before, newest first, `limit` at most.
    public static func newCrashFiles(_ entries: [CrashLogEntry], executables: Set<String>, since: Date,
                                     seen: Set<String>, limit: Int = CrashWatch.maxFilesPerScan) -> [CrashLogEntry] {
        pickNewCrashFiles(entries, executables: executables, since: since, seen: seen, limit: limit).files
    }

    /// `newCrashFiles`, and whether they are all of them (`complete`: the cap left none unread).
    /// Each app's newest file comes first, then the newest of the rest (mega review K1: one app's
    /// crash loop doesn't hide another's crash); the picks are newest first.
    public static func pickNewCrashFiles(_ entries: [CrashLogEntry], executables: Set<String>, since: Date,
                                         seen: Set<String>, limit: Int = CrashWatch.maxFilesPerScan)
        -> (files: [CrashLogEntry], complete: Bool) {
        // A name that keeps nothing once normalized names no process (mega review K7).
        let names = Set(executables.map(normalized)).subtracting([""])
        let candidates = entries.filter { entry in
            guard !entry.relativePath.hasPrefix("ProxiedDevice-"),
                  let size = entry.size, size >= 0, size <= CrashLogParser.maxBytes,
                  let modified = entry.modified, modified >= since.addingTimeInterval(-slack),
                  let part = entry.processPart, part != "JetsamEvent", names.contains(normalized(part)) else { return false }
            return !seen.contains((entry.relativePath as NSString).lastPathComponent)
        }.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        let cap = max(0, limit)
        var picked: [CrashLogEntry] = []
        var apps = Set<String>()
        for entry in candidates where picked.count < cap {
            if apps.insert(normalized(entry.processPart ?? "")).inserted { picked.append(entry) }
        }
        for entry in candidates where picked.count < cap && !picked.contains(entry) { picked.append(entry) }
        let files = picked.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return (files, files.count == candidates.count)
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
