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

    private struct Slot: Sendable {
        let remote: String
        let openedAt: Date
        var gotLine = false
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

    /// The connection ended (closed, failed or evicted).
    public mutating func ended(_ id: ID) {
        slots[id] = nil
    }
}
