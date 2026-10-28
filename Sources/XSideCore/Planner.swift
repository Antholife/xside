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

    /// Installations to refresh now. Already-expired ones are still due.
    public static func dueJobs(_ records: [AppRecord], devices: [Device], now: Date,
                               threshold: TimeInterval = RefreshPlanner.threshold) -> [RefreshJob] {
        let available = Set(devices.filter(\.isAvailable).map(\.id))
        var due: [(expiresAt: Date, job: RefreshJob)] = []
        for record in records {
            for i in record.installations {
                guard i.expiresAt.timeIntervalSince(now) <= threshold,
                      available.contains(i.deviceID) else { continue }
                if let last = i.lastAttempt, now.timeIntervalSince(last) < retryDelay { continue }
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

/// Remembers, per (app, device), the last failure cause already notified, so a
/// cause is notified once until the next success calls `reset`.
public struct NotificationGate: Codable, Equatable, Sendable {
    private var notified: [String: String] = [:]

    public init() {}

    private static func key(_ recordID: UUID, _ deviceID: String) -> String {
        "\(recordID.uuidString)|\(deviceID)"
    }

    public mutating func shouldNotify(recordID: UUID, deviceID: String, errorKey: String) -> Bool {
        let k = Self.key(recordID, deviceID)
        if notified[k] == errorKey { return false }
        notified[k] = errorKey
        return true
    }

    public mutating func reset(recordID: UUID, deviceID: String) {
        notified[Self.key(recordID, deviceID)] = nil
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
        let available = Set(devices.filter(\.isAvailable).map(\.id))
        var seen: [RefreshJob: Date] = [:]
        var result: [(expiresAt: Date, job: RefreshJob)] = []
        for record in records {
            for i in record.installations
            where i.expiresAt.timeIntervalSince(now) <= threshold && !available.contains(i.deviceID) {
                let job = RefreshJob(recordID: record.id, deviceID: i.deviceID)
                let first = firstSeen[job] ?? now
                seen[job] = first
                guard now.timeIntervalSince(first) >= Self.confirmDelay else { continue }
                if let last = i.lastAttempt, now.timeIntervalSince(last) < RefreshPlanner.retryDelay { continue }
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
