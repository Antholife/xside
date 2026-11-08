import Foundation

/// What a watch line tells the phone about its installation: what a check-in reply carries.
public struct ChannelWatchState: Equatable, Sendable {
    public var settings: InAppSettings
    public var lastRefresh: RefreshOutcome?
    /// The end of a pause of a while made on the Mac (review D–G, minor 7).
    public var pausedUntil: Date?

    public init(settings: InAppSettings, lastRefresh: RefreshOutcome?, pausedUntil: Date? = nil) {
        self.settings = settings
        self.lastRefresh = lastRefresh
        self.pausedUntil = pausedUntil
    }

    /// The installation as stored (its settings carry the pause, as automatic refresh), nil while
    /// it has no settings yet (never the case once a watch's check-in was stored).
    public init?(_ installation: Installation) {
        guard let settings = installation.inApp else { return nil }
        self.init(settings: settings, lastRefresh: installation.lastRefreshOutcome,
                  pausedUntil: ChannelHandler.pauseEnd(installation, settings: settings))
    }
}

/// XSide's open watches (see the wire format in Channel.swift), one per installation, without any
/// networking: each line is sealed here and handed to the watch's `send`, synchronously, in order.
/// A Mac change therefore goes out in the same turn that stores it (`update`). Owned by one actor
/// (the app's main actor); `Token` names a connection.
public final class ChannelWatches<Token: Hashable> {
    /// A keep-alive goes when nothing was written for this long; the phone gives up after 60 s.
    public static var keepAliveInterval: TimeInterval { 25 }
    /// XSide closes a watch after this long (the server's timer); the phone opens another.
    public static var lifetime: TimeInterval { 300 }

    private struct Watch {
        let token: Token
        let nonce: String
        let secret: Data
        let send: (Data) -> Void
        var seq = 0
        var state: ChannelWatchState
        var lastWrite: Date
    }

    private var watches: [String: Watch] = [:]

    public init() {}

    /// The installations watched now.
    public var installationIDs: [String] { Array(watches.keys) }

    public func isWatched(_ installationID: String) -> Bool { watches[installationID] != nil }

    /// A watch whose request (`nonce`) authenticated and was admitted: writes its first line, the
    /// check-in's `settings` reply carrying `first`, and keeps it. Returns the token of the
    /// installation's previous watch, which this one replaces (the caller closes that connection;
    /// nothing more is written to it).
    @discardableResult
    public func open(_ token: Token, installationID: String, nonce: String, secret: Data,
                     first: ChannelWatchState, now: Date, send: @escaping (Data) -> Void) throws -> Token? {
        let line = try ChannelHandler.replyLine(.settings(first.settings, lastRefresh: first.lastRefresh, pausedUntil: first.pausedUntil),
                                                installationID: installationID, requestNonce: nonce, secret: secret)
        let replaced = watches[installationID]?.token
        watches[installationID] = Watch(token: token, nonce: nonce, secret: secret, send: send, state: first, lastWrite: now)
        send(line)
        return replaced
    }

    /// The installation as stored now: when it differs from what its watch last told the phone, a
    /// `live` line goes at once. Returns whether one was written.
    @discardableResult
    public func update(_ installationID: String, to state: ChannelWatchState, now: Date) -> Bool {
        guard var watch = watches[installationID], watch.state != state else { return false }
        watch.state = state
        return write(.live(seq: watch.seq + 1, state.settings, lastRefresh: state.lastRefresh, pausedUntil: state.pausedUntil), to: &watch,
                     installationID: installationID, now: now)
    }

    /// An `alive` line on each watch that wrote nothing for `keepAliveInterval`.
    public func keepAlive(now: Date) {
        for (id, var watch) in watches where now.timeIntervalSince(watch.lastWrite) >= Self.keepAliveInterval {
            write(.alive(seq: watch.seq + 1), to: &watch, installationID: id, now: now)
        }
    }

    /// The connection ended: its watch goes (a newer watch of the same installation stays).
    /// Returns the installation it watched, nil if it was no longer the current watch.
    @discardableResult
    public func close(_ token: Token) -> String? {
        guard let id = watches.first(where: { $0.value.token == token })?.key else { return nil }
        watches[id] = nil
        return id
    }

    @discardableResult
    private func write(_ reply: ChannelReply, to watch: inout Watch, installationID: String, now: Date) -> Bool {
        guard let line = try? ChannelHandler.replyLine(reply, installationID: installationID,
                                                       requestNonce: watch.nonce, secret: watch.secret) else { return false }
        watch.seq += 1
        watch.lastWrite = now
        watches[installationID] = watch
        watch.send(line)
        return true
    }
}

/// The watches whose connection ended before they were registered (the Mac's `holdWatch` awaits
/// the server meanwhile), each remembered for `lifetime`: a replaced watch's late end lands here
/// too and must not stay forever, and a pending one is never dropped with the others (review
/// D–G, minor 5).
public struct EndedWatchTokens<Token: Hashable> {
    public static var lifetime: TimeInterval { 60 }
    private var ended: [Token: Date] = [:]

    public init() {}

    public var count: Int { ended.count }

    public mutating func insert(_ token: Token, at date: Date = Date()) {
        ended = ended.filter { date.timeIntervalSince($0.value) < Self.lifetime }
        ended[token] = date
    }

    /// True (and forgotten) when `token` had ended.
    @discardableResult
    public mutating func take(_ token: Token) -> Bool { ended.removeValue(forKey: token) != nil }
}
