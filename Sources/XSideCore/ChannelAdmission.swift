import Foundation

/// Who gets one of the channel server's connection slots (ChannelServer in the app; here to be
/// tested). Per peer address: a few connections at once and a few new ones a minute. When every
/// slot is taken, the oldest connection still waiting for its first line makes room for the new
/// one: peers that connect and send nothing could otherwise keep phones out for their whole read
/// timeout (final review minor 8). A connection that sent its line is never evicted: an invalid
/// request is answered and closed at once, so only a phone's request can hold its slot long.
public struct ChannelAdmission<ID: Hashable & Sendable>: Sendable {
    public enum Decision: Equatable, Sendable {
        case accept
        /// Accept, after closing that connection (the oldest one still waiting for its line).
        case acceptEvicting(ID)
        case drop
    }

    public var maxConnections = 16
    public var maxConnectionsPerRemote = 4
    public var maxAcceptsPerRemotePerMinute = 20
    /// Watches (connections kept open while an app is in front, see Channel.swift) are slots like
    /// any other, counted in the limits above, and are never evicted (they sent their line). These
    /// caps keep at least half the slots, and 2 of each address's 4, for short requests.
    public var maxWatches = 8
    public var maxWatchesPerRemote = 2

    /// Whether a connection whose `watch` request authenticated may stay open as that watch.
    public enum WatchDecision: Equatable, Sendable {
        /// Keep it open; close `replacing` first (the same installation's older watch), if any.
        case watch(replacing: ID?)
        /// Answer it like a check-in and close it (no watch slot left, or not a connection that
        /// sent its line).
        case refuse
    }

    private struct Slot: Sendable {
        let remote: String
        let openedAt: Date
        var gotLine = false
        /// The installation it watches, once its authenticated `watch` request was admitted.
        var watching: String?
    }

    private var slots: [ID: Slot] = [:]
    private var recentAccepts: [String: [Date]] = [:]

    public init() {}

    public var openCount: Int { slots.count }

    public mutating func admit(_ id: ID, remote: String, now: Date) -> Decision {
        // Every peer's old entries go, not only this one's (no growth from peers that never return).
        recentAccepts = recentAccepts.compactMapValues { dates in
            let recent = dates.filter { now.timeIntervalSince($0) < 60 }
            return recent.isEmpty ? nil : recent
        }
        let open = slots.values.filter { $0.remote == remote }.count
        guard open < maxConnectionsPerRemote,
              recentAccepts[remote, default: []].count < maxAcceptsPerRemotePerMinute else { return .drop }
        var decision = Decision.accept
        if slots.count >= maxConnections {
            guard let idle = slots.filter({ !$0.value.gotLine }).min(by: { $0.value.openedAt < $1.value.openedAt })
            else { return .drop }
            slots[idle.key] = nil
            decision = .acceptEvicting(idle.key)
        }
        slots[id] = Slot(remote: remote, openedAt: now)
        recentAccepts[remote, default: []].append(now)
        return decision
    }

    /// The connection sent its request line.
    public mutating func gotLine(_ id: ID) {
        slots[id]?.gotLine = true
    }

    /// Asked by the server only once the connection's `watch` request authenticated (see
    /// `ChannelHandler.watchRequested`): a peer without the installation's secret never holds a
    /// watch. One watch per installation: a newer one replaces the older (which the caller closes).
    public mutating func watch(_ id: ID, installationID: String) -> WatchDecision {
        guard let slot = slots[id], slot.gotLine, slot.watching == nil else { return .refuse }
        let replaced = slots.first { $0.key != id && $0.value.watching == installationID }?.key
        let others = slots.filter { $0.key != id && $0.key != replaced && $0.value.watching != nil }
        guard others.count < maxWatches,
              others.values.filter({ $0.remote == slot.remote }).count < maxWatchesPerRemote else { return .refuse }
        if let replaced { slots[replaced]?.watching = nil } // closing: no longer counts as the watch
        slots[id]?.watching = installationID
        return .watch(replacing: replaced)
    }

    /// The installation this connection watches, if it is a watch.
    public func watching(_ id: ID) -> String? { slots[id]?.watching }

    /// The connection ended (closed, failed or evicted).
    public mutating func ended(_ id: ID) {
        slots[id] = nil
    }
}
