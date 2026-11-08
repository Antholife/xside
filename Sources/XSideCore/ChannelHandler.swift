import Foundation

/// What a request asks XSide to change on the installation it came from (applied by the caller,
/// which owns the library and the refresh queue).
public enum InstallationUpdate: Equatable, Sendable {
    case none
    /// Store the merged settings, the check-in date and, when newer than the stored one, the
    /// phone's last refresh outcome (nil: keep the stored one).
    case merged(InAppSettings, checkIn: Date, outcome: RefreshOutcome?)
    /// Pause (`true`) or resume refreshes, recording who did it.
    case paused(Bool, by: ChangeOrigin)
    /// Run a manual refresh of this installation; its outcome is sent as a second reply line.
    case refreshRequested
}

/// What became of one received request line (see the wire format in Channel.swift).
public enum ChannelReceived: Equatable, Sendable {
    /// Not an envelope at all: the connection is closed without a reply.
    case malformed
    /// A well-formed envelope that didn't authenticate (unknown installation, wrong MAC, outside
    /// the time window, replayed nonce, unreadable body): answered with the unsigned
    /// `ChannelHandler.rejectedLine`, then closed. Nothing is signed for such a request.
    case rejected
    /// Authenticated: `installationID` matched exactly and its secret verified the MAC.
    case request(installationID: String, nonce: String, ChannelRequest)
}

/// XSide's side of the channel, without any networking: authenticates a line, decides the reply
/// and what to change on the installation. The only things a request can reach are that one
/// installation's settings, pause state and refresh.
public enum ChannelHandler {
    /// Longest accepted request line (a check-in is well under 2 KB).
    public static let maxLineLength = 64 * 1024

    /// Opens `line` (without its "\n") with the secret `secret(installationID)` returns, nil for an
    /// installation XSide doesn't know (or has no secret for). The nonce is recorded only for an
    /// authenticated request.
    public static func receive(line: Data, now: Date, nonces: inout ChannelNonces,
                               secret: (String) -> Data?) -> ChannelReceived {
        guard line.count <= maxLineLength, let envelope = try? ChannelEnvelope.decode(line: line) else {
            return .malformed
        }
        // The lookup comes first: no cache is ever created for an id XSide doesn't know.
        guard let key = secret(envelope.installationID) else { return .rejected }
        let opened = nonces.withCache(for: envelope.installationID) { envelope.open(secret: key, now: now, seen: &$0) }
        guard let request = opened else { return .rejected }
        return .request(installationID: envelope.installationID, nonce: envelope.nonce, request)
    }

    /// Shortest time between two refreshes asked from the phone for one installation (counted
    /// from its last attempt, whatever started it): sooner, the request is answered `busy`.
    public static let refreshInterval: TimeInterval = 10 * 60

    /// The reply to an authenticated request and the change it asks for. A `refresh` is answered
    /// `accepted` here; the caller replaces that with `busy` or `deviceUnreachable` when the job
    /// can't start, and sends the outcome (`refreshed` / `failed`) as a second line once it ends.
    /// `reminder`: the Mac's global "Reminder on the device" setting, to seed an installation saved
    /// without settings.
    public static func handle(_ request: ChannelRequest, installation: Installation, now: Date,
                              reminder: Bool) -> (reply: ChannelReply, update: InstallationUpdate) {
        switch request {
        case let .checkIn(settings, lastRefresh, _):
            let remote = clamped(settings, now: now)
            let merged = installation.inApp.map { InAppSettings.merge($0, remote) } ?? remote
            let reported = lastRefresh.map { outcome -> RefreshOutcome in
                var o = outcome
                if o.at > now.addingTimeInterval(ChannelEnvelope.window) { o.at = now }
                return o
            }
            let newer = reported.flatMap { r in
                (installation.lastRefreshOutcome.map { r.at > $0.at } ?? true) ? r : nil
            }
            return (.settings(merged), .merged(merged, checkIn: now, outcome: newer))
        case .refresh:
            // Paused before XSide recorded who did it: only the Mac could pause then.
            if installation.refreshPaused { return (.paused(by: installation.pausedBy ?? .mac), .none) }
            if let last = installation.lastAttempt, now.timeIntervalSince(last) < refreshInterval { return (.busy, .none) }
            return (.accepted, .refreshRequested)
        case let .setAutoRefresh(on):
            let current = installation.seededInApp(reminder: reminder, at: now)
            let updated = current.setting(\.autoRefresh, to: on, at: now, by: .device)
            return (.settings(updated), .paused(!on, by: .device))
        }
    }

    /// Dates from the phone later than the accepted clock difference are brought back to `now`, so
    /// a phone whose clock runs ahead can't make its values win every later merge.
    static func clamped(_ s: InAppSettings, now: Date) -> InAppSettings {
        let limit = now.addingTimeInterval(ChannelEnvelope.window)
        func c<V>(_ f: Field<V>) -> Field<V> {
            f.changedAt > limit ? Field(value: f.value, changedAt: now, changedBy: f.changedBy) : f
        }
        return InAppSettings(level: c(s.level), showValidity: c(s.showValidity), alertLate: c(s.alertLate),
                             refreshCard: c(s.refreshCard), reminder: c(s.reminder), language: c(s.language),
                             autoRefresh: c(s.autoRefresh))
    }

    /// The signed reply line for an authenticated request.
    public static func replyLine(_ reply: ChannelReply, installationID: String, requestNonce: String,
                                 secret: Data) throws -> Data {
        try ChannelReplyEnvelope.seal(reply, installationID: installationID, requestNonce: requestNonce,
                                      secret: secret).encodedLine()
    }

    /// `{"type":"rejected"}` + "\n": the bare, unsigned refusal (see `ChannelReceived.rejected`).
    public static let rejectedLine: Data = Data(#"{"type":"rejected"}"#.utf8) + Data([0x0A])
}

/// The replay caches, one per installation, so one installation filling its own can't lock the
/// others out. A cache is created only for an installation XSide knows (see `receive`).
public struct ChannelNonces: Sendable {
    private var caches: [String: NonceCache] = [:]
    private let capacity: Int

    public init(capacityPerInstallation: Int = 512) { capacity = capacityPerInstallation }

    public func count(for installationID: String) -> Int { caches[installationID]?.count ?? 0 }

    mutating func withCache<T>(for installationID: String, _ body: (inout NonceCache) -> T) -> T {
        var cache = caches[installationID] ?? NonceCache(capacity: capacity)
        defer { caches[installationID] = cache }
        return body(&cache)
    }
}

/// Accumulates bytes until the first "\n" (the request line), refusing more than `maxLength`
/// bytes before it. Anything after the first line is ignored (one request per connection).
public struct ChannelLineReader: Sendable {
    public enum Result: Equatable, Sendable { case needMore, line(Data), tooLong }
    private var buffer = Data()
    private let maxLength: Int

    public init(maxLength: Int = ChannelHandler.maxLineLength) { self.maxLength = maxLength }

    public mutating func append(_ chunk: Data) -> Result {
        buffer.append(chunk)
        if let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            return line.count <= maxLength ? .line(Data(line)) : .tooLong
        }
        return buffer.count > maxLength ? .tooLong : .needMore
    }
}

// MARK: - Installation state

extension Installation {
    /// The installation's settings, or (older state) the Mac defaults: the global reminder
    /// setting, automatic refresh following the current pause.
    public func seededInApp(reminder: Bool, at date: Date) -> InAppSettings {
        if let inApp { return inApp }
        let seeded = InAppSettings.defaults(reminder: reminder, at: date)
        return refreshPaused ? seeded.setting(\.autoRefresh, to: false, at: date, by: .mac) : seeded
    }

    /// This signing result, keeping what reached `current` (the stored installation) through the
    /// channel while the app was being signed: newer settings (merged field by field), the latest
    /// check-in and refresh outcome. The pause then follows the merged automatic-refresh setting.
    public func keepingChannelState(of current: Installation) -> Installation {
        var result = self
        if let mine = inApp, let theirs = current.inApp { result.inApp = InAppSettings.merge(mine, theirs) }
        if let checkIn = current.lastCheckIn, checkIn > (lastCheckIn ?? .distantPast) { result.lastCheckIn = checkIn }
        if let outcome = current.lastRefreshOutcome, outcome.at > (lastRefreshOutcome?.at ?? .distantPast) {
            result.lastRefreshOutcome = outcome
        }
        if let auto = result.inApp?.autoRefresh {
            result.refreshPaused = !auto.value
            result.pausedBy = auto.value ? nil : auto.changedBy
        }
        return result
    }
}

/// What the pipeline knows of the installation being signed, for what XSide writes into the app
/// (`XSideWelcome` payload, Settings section). The secret here is the one stored on success.
public struct InstallationFacts: Sendable, Equatable {
    public var installationID: String
    public var channelSecret: Data
    public var inApp: InAppSettings
    public var firstInstalledAt: Date
    public var appVersion: String?
    /// This signing's own outcome (the app carrying it is only on the device if it succeeds).
    public var lastRefreshOutcome: RefreshOutcome?
    public var lastCheckIn: Date?

    public init(installationID: String, channelSecret: Data, inApp: InAppSettings, firstInstalledAt: Date,
                appVersion: String?, lastRefreshOutcome: RefreshOutcome?, lastCheckIn: Date?) {
        self.installationID = installationID
        self.channelSecret = channelSecret
        self.inApp = inApp
        self.firstInstalledAt = firstInstalledAt
        self.appVersion = appVersion
        self.lastRefreshOutcome = lastRefreshOutcome
        self.lastCheckIn = lastCheckIn
    }
}
