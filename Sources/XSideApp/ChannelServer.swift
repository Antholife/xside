import Foundation
import Network
import XSideCore

/// The local-network end of the channel (wire format in XSideCore's Channel.swift): a TCP listener
/// published over Bonjour as `_xside._tcp`. Each connection carries one request line; the handler
/// sends its reply line(s), then the connection is closed, unless the handler held it as a watch
/// (only after its `watch` request authenticated). Deliberately thin: authentication and every
/// decision are in `ChannelHandler` / `ChannelWatches` (XSideCore, tested); this only frames bytes
/// and bounds what a peer can make it hold (line size, time, number of connections and watches).
final class ChannelServer: @unchecked Sendable {
    /// Writes one line to the peer; returns once it was handed to the network (or failed).
    typealias Send = @Sendable (Data) async -> Void
    /// Writes one line to a held watch at once, without waiting; lines go out in call order.
    typealias Push = @Sendable (Data) -> Void
    /// Keeps this connection open as the watch of `installationID`: to be called only once its
    /// `watch` request authenticated (`ChannelHandler.watchRequested`). Returns how to write on it,
    /// or nil when refused (no watch slot left, or the connection is gone): the handler then
    /// answers as to a check-in and the connection closes as usual. `ended` runs once, on the
    /// server's queue, when a held watch closes (either side, lifetime, or replaced by a newer one),
    /// with how: by XSide, or by the phone with the line it wrote first (its `bye`), if any.
    typealias Hold = @Sendable (_ installationID: String, _ ended: @escaping @Sendable (WatchClose) -> Void) async -> Push?
    /// Called once per connection with its request line (without "\n").
    typealias Handler = @Sendable (_ line: Data, _ send: @escaping Send, _ hold: @escaping Hold) async -> Void

    static let serviceType = "_xside._tcp"
    /// A request line must arrive whole within this time.
    private static let readTimeout: TimeInterval = 10
    /// Longest a connection stays open: a refresh's outcome is awaited up to 2 minutes.
    private static let connectionLifetime: TimeInterval = 150
    /// Longest a held watch stays open (counted from when it was held); the phone opens another.
    private static let watchLifetime: TimeInterval = ChannelWatches<Int>.lifetime
    private static let logger = Log("channel")

    private let handler: Handler
    /// Everything below is only touched on `queue`.
    private let queue = DispatchQueue(label: "io.github.xside.channel")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Entry] = [:]
    /// Who gets a slot: per-peer limits, and idle connections make room (ChannelAdmission).
    private var admission = ChannelAdmission<ObjectIdentifier>()
    private var running = false

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() {
        queue.async { [self] in
            running = true
            listen()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            listener?.cancel()
            listener = nil
            for (id, entry) in connections {
                connections[id]?.closedByMac = true
                entry.connection.cancel()
            }
        }
    }

    private func listen() {
        guard running, listener == nil else { return }
        do {
            // A watch must end within seconds when its phone is gone without closing it (Wi-Fi
            // lost, phone locked hard): TCP probes an idle connection after 10 s, and a line (such
            // as a keep-alive) the phone doesn't acknowledge within 20 s drops the connection.
            let tcp = NWProtocolTCP.Options()
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 2
            tcp.connectionDropTime = 20
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.includePeerToPeer = false
            let listener = try NWListener(using: parameters)
            // A plain name rather than the Mac's own (the default): the service is seen on every
            // network the Mac joins, a café's included (final review minor 8). Phones look for the
            // type only; Bonjour renames it ("XSide (2)") if several Macs run XSide.
            listener.service = NWListener.Service(name: "XSide", type: Self.serviceType)
            listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            Self.logger.error("channel listener not created: \(error)")
            retryLater()
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            Self.logger.notice("channel published as \(Self.serviceType) on port \(listener?.port?.rawValue ?? 0)")
        case .failed(let error):
            // E.g. the network went away: publish again a bit later.
            Self.logger.error("channel listener failed: \(error)")
            listener?.cancel()
            listener = nil
            retryLater()
        default:
            break
        }
    }

    private func retryLater() {
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.listen() }
    }

    /// The peer's address (without the port): the unit of the per-peer limits.
    private static func remote(of connection: NWConnection) -> String {
        if case let .hostPort(host, _) = connection.endpoint { return "\(host)" }
        return "\(connection.endpoint)"
    }

    private func accept(_ connection: NWConnection) {
        let remote = Self.remote(of: connection)
        let id = ObjectIdentifier(connection)
        switch admission.admit(id, remote: remote, now: Date()) {
        case .drop:
            connection.cancel() // dropped silently
            return
        case .acceptEvicting(let idle):
            // Ends through its state handler (`ended`).
            connections[idle]?.connection.cancel()
        case .accept:
            break
        }
        let read = ReadState()
        // Weak: a timer never keeps a connection that ended alive; both are cancelled when it ends.
        let readTimer = DispatchWorkItem { [weak connection] in
            if !read.gotLine { connection?.cancel() }
        }
        let lifeTimer = DispatchWorkItem { [weak connection] in connection?.cancel() }
        connections[id] = Entry(connection: connection, remote: remote, read: read, timers: [readTimer, lifeTimer])
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.ended(id)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.readTimeout, execute: readTimer)
        queue.asyncAfter(deadline: .now() + Self.connectionLifetime, execute: lifeTimer)
        receive(on: connection, read: read, id: id)
    }

    private func ended(_ id: ObjectIdentifier) {
        guard let entry = connections.removeValue(forKey: id) else { return }
        for timer in entry.timers { timer.cancel() }
        admission.ended(id)
        entry.watchEnded?(entry.closedByMac ? .byMac : .byPhone(farewell: entry.farewell))
    }

    /// `Hold`, on the queue: the connection becomes the installation's watch if a slot is left
    /// (`ChannelAdmission.watch`). Its 150 s lifetime becomes the watch's own, and it is read again,
    /// only to notice the phone closing it: the phone writes at most one line more (its `bye`,
    /// kept for `ended`), and the first line, anything over 4 KB, the end or an error closes it.
    private func hold(_ id: ObjectIdentifier, installationID: String,
                      ended: @escaping @Sendable (WatchClose) -> Void) -> Push? {
        guard var entry = connections[id], entry.read.gotLine, entry.watchEnded == nil else { return nil }
        switch admission.watch(id, installationID: installationID) {
        case .refuse:
            Self.logger.notice("channel: watch refused (no watch slot left): answered as a check-in")
            return nil
        case .watch(let replaced):
            if let replaced { // a newer watch replaces it
                connections[replaced]?.closedByMac = true
                connections[replaced]?.connection.cancel()
            }
        }
        let connection = entry.connection
        for timer in entry.timers { timer.cancel() }
        let lifeTimer = DispatchWorkItem { [weak self, weak connection] in
            self?.connections[id]?.closedByMac = true // its lifetime: XSide closes it
            connection?.cancel()
        }
        entry.timers = [lifeTimer]
        entry.watchEnded = ended
        connections[id] = entry
        queue.asyncAfter(deadline: .now() + Self.watchLifetime, execute: lifeTimer)
        watchForClose(connection, id: id, reader: ChannelLineReader(maxLength: ChannelHandler.maxFarewellLength))
        return { data in connection.send(content: data, completion: .contentProcessed { _ in }) }
    }

    /// A held watch: closed when the phone closes it, fails, writes a line (kept as its farewell,
    /// its `bye`) or more than 4 KB without one.
    private func watchForClose(_ connection: NWConnection, id: ObjectIdentifier, reader: ChannelLineReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var reader = reader
            if let data, !data.isEmpty {
                switch reader.append(data) {
                case .line(let line):
                    self.connections[id]?.farewell = line
                    connection.cancel()
                    return
                case .tooLong:
                    connection.cancel()
                    return
                case .needMore:
                    break
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.watchForClose(connection, id: id, reader: reader)
        }
    }

    /// Reads until the first "\n". Malformed framing (too long, closed early) closes silently.
    private func receive(on connection: NWConnection, read: ReadState, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                switch read.reader.append(data) {
                case .line(let line):
                    read.gotLine = true
                    self.admission.gotLine(id)
                    self.dispatch(line, on: connection, id: id)
                    return
                case .tooLong:
                    connection.cancel()
                    return
                case .needMore:
                    break
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, read: read, id: id)
        }
    }

    private func dispatch(_ line: Data, on connection: NWConnection, id: ObjectIdentifier) {
        let send: Send = { data in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Called on success, failure, and when the connection is cancelled meanwhile.
                connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
            }
        }
        let hold: Hold = { [weak self] installationID, ended in
            guard let self else { return nil }
            return await withCheckedContinuation { (continuation: CheckedContinuation<Push?, Never>) in
                self.queue.async { continuation.resume(returning: self.hold(id, installationID: installationID, ended: ended)) }
            }
        }
        let handler = handler
        let queue = queue
        Task { [weak self] in
            await handler(line, send, hold)
            queue.async { [weak self] in
                // A held watch stays open; everything else is closed after its last line.
                if self?.connections[id]?.watchEnded != nil { return }
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

/// An open connection, its peer and its timers (only touched on the server's queue).
private struct Entry {
    let connection: NWConnection
    let remote: String
    let read: ReadState
    var timers: [DispatchWorkItem]
    /// Set once the connection is held as a watch: told when it ends.
    var watchEnded: (@Sendable (WatchClose) -> Void)?
    /// XSide closed it (lifetime, replaced, stopping): not the phone's doing.
    var closedByMac = false
    /// The line the phone wrote on its watch before closing it (its `bye`).
    var farewell: Data?
}

/// One connection's read progress (only touched on the server's queue).
private final class ReadState: @unchecked Sendable {
    var reader = ChannelLineReader()
    var gotLine = false
}
