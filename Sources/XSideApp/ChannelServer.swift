import Foundation
import Network
import XSideCore

/// The local-network end of the channel (wire format in XSideCore's Channel.swift): a TCP listener
/// published over Bonjour as `_xside._tcp`. Each connection carries one request line; the handler
/// sends its reply line(s), then the connection is closed. Deliberately thin: authentication and
/// every decision are in `ChannelHandler` (XSideCore, tested); this only frames bytes and bounds
/// what a peer can make it hold (line size, time, number of connections).
final class ChannelServer: @unchecked Sendable {
    /// Writes one line to the peer; returns once it was handed to the network (or failed).
    typealias Send = @Sendable (Data) async -> Void
    /// Called once per connection with its request line (without "\n").
    typealias Handler = @Sendable (_ line: Data, _ send: @escaping Send) async -> Void

    static let serviceType = "_xside._tcp"
    /// A request line must arrive whole within this time.
    private static let readTimeout: TimeInterval = 10
    /// Longest a connection stays open: a refresh's outcome is awaited up to 2 minutes.
    private static let connectionLifetime: TimeInterval = 150
    private static let maxConnections = 16
    private static let logger = Log("channel")

    private let handler: Handler
    /// Everything below is only touched on `queue`.
    private let queue = DispatchQueue(label: "io.github.xside.channel")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
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
            for connection in connections.values { connection.cancel() }
            connections = [:]
        }
    }

    private func listen() {
        guard running, listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(type: Self.serviceType)
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

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[id] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        let read = ReadState()
        queue.asyncAfter(deadline: .now() + Self.readTimeout) {
            if !read.gotLine { connection.cancel() }
        }
        queue.asyncAfter(deadline: .now() + Self.connectionLifetime) { connection.cancel() }
        receive(on: connection, read: read)
    }

    /// Reads until the first "\n". Malformed framing (too long, closed early) closes silently.
    private func receive(on connection: NWConnection, read: ReadState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                switch read.reader.append(data) {
                case .line(let line):
                    read.gotLine = true
                    self.dispatch(line, on: connection)
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
            self.receive(on: connection, read: read)
        }
    }

    private func dispatch(_ line: Data, on connection: NWConnection) {
        let send: Send = { data in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Called on success, failure, and when the connection is cancelled meanwhile.
                connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
            }
        }
        let handler = handler
        Task {
            await handler(line, send)
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// One connection's read progress (only touched on the server's queue).
private final class ReadState: @unchecked Sendable {
    var reader = ChannelLineReader()
    var gotLine = false
}
