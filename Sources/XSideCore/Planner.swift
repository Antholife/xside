import Foundation

public struct RefreshJob: Equatable, Sendable {
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
    /// The Mac wakes this long before an installation crosses the threshold.
    static let wakeLead: TimeInterval = 10 * 60

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

    /// Earliest future wake time (10 min before an installation crosses the
    /// threshold). Installations already under it are handled by `dueJobs`.
    public static func nextWake(_ records: [AppRecord], now: Date,
                                threshold: TimeInterval = RefreshPlanner.threshold) -> Date? {
        records.flatMap(\.installations)
            .map { $0.expiresAt.addingTimeInterval(-threshold - wakeLead) }
            .filter { $0 > now }
            .min()
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
