import Foundation

public struct RefreshJob: Hashable, Sendable {
    public let recordID: UUID
    public let deviceID: String

    public init(recordID: UUID, deviceID: String) {
        self.recordID = recordID
        self.deviceID = deviceID
    }
}

public enum RefreshPlanner {
    /// Refresh when less than this remains before expiry.
    public static let threshold: TimeInterval = 2 * 86_400
    /// Minimum delay between two attempts on the same installation.
    public static let retryDelay: TimeInterval = 30 * 60

    /// True while `date` is less than `delay` ago. A date in the future (clock moved back, or a
    /// date written on a skewed clock) counts as elapsed, so it can't block retries for days.
    static func isRecent(_ date: Date, now: Date, within delay: TimeInterval) -> Bool {
        let elapsed = now.timeIntervalSince(date)
        return elapsed >= 0 && elapsed < delay
    }

    /// Installations to refresh now. Already-expired ones are still due.
    /// `currentIdentitySHA1`: the signing certificate in use. An installation signed with another
    /// one (certificate replaced or revoked) is due now whatever its expiry: the old signature may
    /// stop working at any time. Installations with no recorded certificate are never forced, nor
    /// those of another team (`currentTeamID`): switching teams must not refresh everything at once.
    public static func dueJobs(_ records: [AppRecord], devices: [Device], now: Date,
                               threshold: TimeInterval = RefreshPlanner.threshold,
                               prefs: DevicePrefs = DevicePrefs(),
                               currentIdentitySHA1: String? = nil, currentTeamID: String? = nil) -> [RefreshJob] {
        let available = Set(devices.filter(prefs.canRefresh).map(\.id))
        var due: [(expiresAt: Date, job: RefreshJob)] = []
        for record in records {
            for i in record.installations {
                guard available.contains(i.deviceID) else { continue }
                let certificateChanged = currentIdentitySHA1 != nil && i.signingIdentitySHA1 != nil
                    && i.signingIdentitySHA1?.uppercased() != currentIdentitySHA1?.uppercased()
                    && (i.teamID == nil || i.teamID == currentTeamID)
                if certificateChanged {
                    // Only a failed attempt delays it (a success records the new certificate).
                    if i.lastErrorKey != nil, let last = i.lastAttempt, isRecent(last, now: now, within: retryDelay) { continue }
                } else {
                    guard i.expiresAt.timeIntervalSince(now) <= threshold else { continue }
                    if let last = i.lastAttempt, isRecent(last, now: now, within: retryDelay) { continue }
                }
                due.append((i.expiresAt, RefreshJob(recordID: record.id, deviceID: i.deviceID)))
            }
        }
        due.sort {
            if $0.expiresAt != $1.expiresAt { return $0.expiresAt < $1.expiresAt }
            if $0.job.recordID != $1.job.recordID { return $0.job.recordID.uuidString < $1.job.recordID.uuidString }
            return $0.job.deviceID < $1.job.deviceID
        }
        return due.map(\.job)
    }

    /// Due installations that only the Wi-Fi preference keeps from refreshing: the device is
    /// reachable over Wi-Fi alone and its Wi-Fi refresh is off. The user must plug it in, so
    /// these are warned about (once, by the caller's gate) instead of expiring silently.
    public static func blockedByWifiPref(_ records: [AppRecord], devices: [Device], now: Date,
                                         threshold: TimeInterval = RefreshPlanner.threshold,
                                         prefs: DevicePrefs) -> [RefreshJob] {
        let blocked = Set(devices.filter(prefs.isWifiBlocked).map(\.id))
        var due: [(expiresAt: Date, job: RefreshJob)] = []
        for record in records {
            for i in record.installations
            where i.expiresAt.timeIntervalSince(now) <= threshold && blocked.contains(i.deviceID) {
                due.append((i.expiresAt, RefreshJob(recordID: record.id, deviceID: i.deviceID)))
            }
        }
        due.sort {
            if $0.expiresAt != $1.expiresAt { return $0.expiresAt < $1.expiresAt }
            if $0.job.recordID != $1.job.recordID { return $0.job.recordID.uuidString < $1.job.recordID.uuidString }
            return $0.job.deviceID < $1.job.deviceID
        }
        return due.map(\.job)
    }

    /// Threshold to use given the hidden debug setting (`debugThresholdDays`, in days):
    /// a positive value replaces the default, anything else keeps it.
    public static func threshold(debugDays: Double) -> TimeInterval {
        debugDays > 0 && debugDays.isFinite ? debugDays * 86_400 : threshold
    }

    /// Due jobs that can start now: those whose row isn't already running, in `due` order.
    public static func startable(_ due: [RefreshJob], busy: Set<RefreshJob>) -> [RefreshJob] {
        due.filter { !busy.contains($0) }
    }
}

/// Remembers, per (app, device), every failure cause already notified (and `needsUSB`), so each
/// cause is notified once until the next success calls `reset`, even when causes alternate.
public struct NotificationGate: Codable, Equatable, Sendable {
    private var notified: [String: Set<String>] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case notified }

    /// Also reads the older format, which kept only the last cause per pair (`{"k": "cause"}`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let sets = try? c.decode([String: [String]].self, forKey: .notified) {
            notified = sets.mapValues(Set.init)
        } else if let single = try? c.decode([String: String].self, forKey: .notified) {
            notified = single.mapValues { [$0] }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(notified.mapValues { $0.sorted() }, forKey: .notified)
    }

    private static func key(_ recordID: UUID, _ deviceID: String) -> String {
        "\(recordID.uuidString)|\(deviceID)"
    }

    public mutating func shouldNotify(recordID: UUID, deviceID: String, errorKey: String) -> Bool {
        notified[Self.key(recordID, deviceID), default: []].insert(errorKey).inserted
    }

    /// Forgets one cause only: its notification was refused, the next occurrence retries it.
    public mutating func forget(recordID: UUID, deviceID: String, errorKey: String) {
        let k = Self.key(recordID, deviceID)
        notified[k]?.remove(errorKey)
        if notified[k]?.isEmpty == true { notified[k] = nil }
    }

    public mutating func reset(recordID: UUID, deviceID: String) {
        notified[Self.key(recordID, deviceID)] = nil
    }

    /// Forgets every entry of a device (it was removed from XSide).
    public mutating func forgetDevice(_ deviceID: String) {
        notified = notified.filter { !$0.key.hasSuffix("|\(deviceID)") }
    }
}

/// Remembers, per (app, device), the `expiresAt` of the last success notified, so one renewal is
/// notified at most once even if two successes report the same expiry.
public struct SuccessNotificationGate: Equatable, Sendable {
    private var notified: [String: Date] = [:]

    public init() {}

    /// True (and remembered) when this success is a refresh of an existing installation and its
    /// `expiresAt` differs from the last one notified for the pair.
    public mutating func shouldNotify(recordID: UUID, deviceID: String, expiresAt: Date, wasRefresh: Bool) -> Bool {
        guard wasRefresh else { return false }
        let k = "\(recordID.uuidString)|\(deviceID)"
        if notified[k] == expiresAt { return false }
        notified[k] = expiresAt
        return true
    }

    /// Forgets a notification the system refused, so the next success can retry.
    public mutating func forget(recordID: UUID, deviceID: String) {
        notified["\(recordID.uuidString)|\(deviceID)"] = nil
    }

    /// Forgets every entry of a device (it was removed from XSide).
    public mutating func forgetDevice(_ deviceID: String) {
        notified = notified.filter { !$0.key.hasSuffix("|\(deviceID)") }
    }
}

/// Persists a `NotificationGate` as JSON (written atomically). A missing or unreadable file
/// loads as an empty gate: at worst a cause is notified once more.
public struct NotificationGateStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public init(libraryRoot: URL) {
        self.init(url: libraryRoot.appendingPathComponent("notifications.json"))
    }

    public func load() -> NotificationGate {
        guard let data = try? Data(contentsOf: url),
              let gate = try? JSONDecoder().decode(NotificationGate.self, from: data) else { return NotificationGate() }
        return gate
    }

    public func save(_ gate: NotificationGate) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(gate).write(to: url, options: .atomic)
    }
}

/// Finds due installations whose device can't be reached (missing from the list or unavailable),
/// so they are reported instead of expiring silently. A device must be seen unreachable on two
/// evaluations at least `confirmDelay` apart (avoids alerts right after wake or on a stale list),
/// and an installation is reported at most once per `RefreshPlanner.retryDelay`.
public struct UnreachableTracker: Sendable {
    public static let confirmDelay: TimeInterval = 5 * 60
    private var firstSeen: [RefreshJob: Date] = [:]

    public init() {}

    /// Installations to mark unreachable now. Call on every evaluation.
    public mutating func evaluate(_ records: [AppRecord], devices: [Device], now: Date,
                                  threshold: TimeInterval = RefreshPlanner.threshold) -> [RefreshJob] {
        // A device present and available (even Wi-Fi only with Wi-Fi refresh off, see
        // `DevicePrefs.isWifiBlocked`) isn't "unreachable": the row asks for a USB cable instead,
        // without a notification.
        let available = Set(devices.filter(\.isAvailable).map(\.id))
        var seen: [RefreshJob: Date] = [:]
        var result: [(expiresAt: Date, job: RefreshJob)] = []
        for record in records {
            for i in record.installations
            where i.expiresAt.timeIntervalSince(now) <= threshold && !available.contains(i.deviceID) {
                let job = RefreshJob(recordID: record.id, deviceID: i.deviceID)
                let first = firstSeen[job] ?? now
                seen[job] = first
                // A first sighting "in the future" (clock moved back) was an earlier evaluation: confirmed.
                guard !RefreshPlanner.isRecent(first, now: now, within: Self.confirmDelay) else { continue }
                if let last = i.lastAttempt, RefreshPlanner.isRecent(last, now: now, within: RefreshPlanner.retryDelay) { continue }
                result.append((i.expiresAt, job))
            }
        }
        // Anything not seen unreachable this time (device back, refreshed, removed) starts over.
        firstSeen = seen
        result.sort {
            if $0.expiresAt != $1.expiresAt { return $0.expiresAt < $1.expiresAt }
            if $0.job.recordID != $1.job.recordID { return $0.job.recordID.uuidString < $1.job.recordID.uuidString }
            return $0.job.deviceID < $1.job.deviceID
        }
        return result.map(\.job)
    }
}
