import Foundation
import os

/// XSide's log: each line goes to the unified log (Console.app) and to a file the user can export
/// (`LogStore`). Messages are redacted before they leave: e-mails, the home folder, and every value
/// registered with `LogStore.register` (team, devices) are replaced by placeholders.
public struct Log: Sendable {
    public let category: String
    private let system: Logger

    public init(_ category: String) {
        self.category = category
        system = Logger(subsystem: "io.github.xside.XSide", category: category)
    }

    public func debug(_ message: @autoclosure () -> String) { write(.debug, message()) }
    public func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    public func notice(_ message: @autoclosure () -> String) { write(.notice, message()) }
    public func error(_ message: @autoclosure () -> String) { write(.error, message()) }

    private func write(_ level: LogLevel, _ message: String) {
        let text = LogStore.shared.redact(message)
        switch level {
        case .debug: system.debug("\(text, privacy: .public)")
        case .info: system.info("\(text, privacy: .public)")
        case .notice: system.notice("\(text, privacy: .public)")
        case .error: system.error("\(text, privacy: .public)")
        }
        LogStore.shared.append(level: level, category: category, redacted: text)
    }
}

public enum LogLevel: String, Sendable {
    case debug, info, notice, error
}

/// The log files: `xside.log`, rotated to `xside.1.log`… past `maxBytes`, `keep` files at most.
/// Nothing is written until `configure(directory:)` (tests and the icon helper stay silent).
public final class LogStore: @unchecked Sendable {
    public static let shared = LogStore()

    public static let fileName = "xside.log"
    let maxBytes: UInt64
    let keep: Int

    private let lock = NSLock()
    private var directory: URL?
    private var handle: FileHandle?
    private var size: UInt64 = 0
    /// Exact values to hide -> placeholder ("<device-1>"), longest first when applied.
    private var secrets: [String: String] = [:]
    private var counters: [String: Int] = [:]
    private let home = NSHomeDirectory()

    init(maxBytes: UInt64 = 2 * 1024 * 1024, keep: Int = 4) {
        self.maxBytes = maxBytes
        self.keep = keep
    }

    /// Where the files go, e.g. `~/Library/Logs/XSide`. Created if needed.
    public func configure(directory: URL) {
        lock.withLock {
            try? handle?.close()
            handle = nil
            self.directory = directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public var logDirectory: URL? { lock.withLock { directory } }

    /// Hides `value` in every later line, as `<kind-N>` (the same value keeps its number). Short
    /// values are ignored: they would hide unrelated text.
    public func register(_ value: String?, as kind: String) {
        guard let value, value.count >= 4 else { return }
        lock.withLock {
            guard secrets[value] == nil else { return }
            counters[kind, default: 0] += 1
            secrets[value] = "<\(kind)-\(counters[kind]!)>"
        }
    }

    /// A signing identity: its SHA-1 and the person's id in "Apple Development: name (ABCDE12345)".
    public func registerIdentity(name: String, sha1: String) {
        register(sha1, as: "certificate")
        if let open = name.lastIndex(of: "("), let close = name.lastIndex(of: ")"), open < close {
            register(String(name[name.index(after: open)..<close]), as: "person")
        }
    }

    private static let email = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])

    public func redact(_ message: String) -> String {
        let secrets = lock.withLock { self.secrets }
        var text = message
        for (value, placeholder) in secrets.sorted(by: { $0.key.count > $1.key.count }) {
            text = text.replacingOccurrences(of: value, with: placeholder)
        }
        text = text.replacingOccurrences(of: home, with: "~")
        let range = NSRange(text.startIndex..., in: text)
        return Self.email.stringByReplacingMatches(in: text, range: range, withTemplate: "<email>")
    }

    private static let timestamp: Date.ISO8601FormatStyle = .iso8601
        .year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)

    func append(level: LogLevel, category: String, redacted text: String) {
        let line = "\(Date().formatted(Self.timestamp)) \(level.rawValue.uppercased().padding(toLength: 6, withPad: " ", startingAt: 0)) [\(category)] \(text)\n"
        let data = Data(line.utf8)
        lock.withLock {
            guard let directory else { return }
            if handle == nil { open(in: directory) }
            if size + UInt64(data.count) > maxBytes { rotate(in: directory) }
            guard let handle else { return }
            do {
                try handle.write(contentsOf: data)
                size += UInt64(data.count)
            } catch {
                try? handle.close()
                self.handle = nil
            }
        }
    }

    /// Caller holds the lock.
    private func open(in directory: URL) {
        let url = directory.appendingPathComponent(Self.fileName)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    /// Caller holds the lock.
    private func rotate(in directory: URL) {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        func file(_ index: Int) -> URL {
            directory.appendingPathComponent(index == 0 ? Self.fileName : "xside.\(index).log")
        }
        try? fm.removeItem(at: file(keep - 1))
        for index in stride(from: keep - 2, through: 0, by: -1) {
            try? fm.moveItem(at: file(index), to: file(index + 1))
        }
        open(in: directory)
    }

    /// The log files, newest first.
    public func files() -> [URL] {
        guard let directory = logDirectory else { return [] }
        return (0..<keep)
            .map { directory.appendingPathComponent($0 == 0 ? Self.fileName : "xside.\($0).log") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
