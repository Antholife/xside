import Foundation
import Security

/// How the `xside` command line tool asks the running app to do something, and gets its answer:
/// distributed notifications named after the app's bundle id (the debug app has its own). The
/// tool never signs or installs itself, so it can't race the app.
public enum CLIBridge {
    public static func requestName(bundleID: String) -> Notification.Name {
        Notification.Name("\(bundleID).cli.request")
    }

    public static func replyName(bundleID: String) -> Notification.Name {
        Notification.Name("\(bundleID).cli.reply")
    }

    public enum Command: Equatable, Sendable {
        /// Every app that can be refreshed now.
        case refreshAll
        /// Those installations, found by the tool (`CLIMatch`, mega review C5: an exact name wins,
        /// several devices is an error, as for the other commands).
        case refreshApp(recordID: UUID, deviceIDs: [String])
        /// Pause automatic refreshes for `seconds`, or until resumed (nil).
        case pause(seconds: Int?)
        case resume
        // Device feedback 3, E7: aimed at installations the tool found in the library
        // (`CLIMatch`), by record and device ids.
        /// Settings changed as from Settings > Mes apps, stamped by the Mac.
        case editSettings(recordID: UUID, deviceIDs: [String], changes: [CLISettingChange])
        /// One app's refreshes paused for `seconds`, or until resumed (nil).
        case pauseApp(recordID: UUID, deviceIDs: [String], seconds: Int?)
        case resumeApp(recordID: UUID, deviceIDs: [String])
        /// Removed from the devices, as from the panel (the tool asked for confirmation).
        case uninstall(recordID: UUID, deviceIDs: [String])
        /// The logs archive written like "Report a problem" does; the answer is its path.
        case report
        /// The newest crash of the app on those devices, explained (`json`: the answer is JSON).
        case crash(recordID: UUID, deviceIDs: [String], json: Bool)
    }

    /// The longest pause a duration may ask for: "until resumed" is the way past it.
    public static let maxPause = 365 * 86_400

    /// "2h", "30m", "1d", or a number of minutes; nil when it isn't a positive duration of at
    /// most `maxPause` (never an overflow).
    public static func duration(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [Character: Int] = ["m": 60, "h": 3600, "d": 86_400]
        let unit = t.last.flatMap { units[$0] }
        guard let value = Int(unit == nil ? t : String(t.dropLast())), value > 0 else { return nil }
        let (seconds, overflow) = value.multipliedReportingOverflow(by: unit ?? 60)
        return overflow || seconds > maxPause ? nil : seconds
    }

    /// The answer to `xside pause <app>`: the installations paused now (`when`: "until …"), and
    /// those already paused, whose pause is left as it was (review D–G, minor 1).
    public static func pauseAppSummary(paused: [String], already: [String], when: String) -> String {
        var lines: [String] = []
        if !paused.isEmpty { lines.append("Paused \(when): " + paused.joined(separator: ", ")) }
        if !already.isEmpty {
            lines.append("Already paused, left as it was: " + already.joined(separator: ", ")
                         + ". To change it: xside resume <app>, then pause again.")
        }
        return lines.joined(separator: "\n")
    }

    /// The key XSide writes at each launch next to its library, readable by the user only
    /// (0600), and that every request must carry: distributed notifications are heard and posted
    /// by any program of the session, and the bridge now uninstalls and changes settings
    /// (review D–G, minor 9). The tool reads it before each send, so a fresh launch's key is
    /// picked up while it retries.
    public enum Key {
        public static let fileName = "cli-key"

        /// A new random key, written (atomically, 0600) to `folder`; returned.
        public static func create(in folder: URL) throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw CocoaError(.fileWriteUnknown)
            }
            let key = bytes.map { String(format: "%02x", $0) }.joined()
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(fileName)
            let temporary = folder.appendingPathComponent(".\(fileName)-\(UUID().uuidString)")
            guard fm.createFile(atPath: temporary.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if rename(temporary.path, file.path) != 0 {
                try? fm.removeItem(at: temporary)
                throw CocoaError(.fileWriteUnknown)
            }
            return key
        }

        public static func read(in folder: URL) -> String? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
            let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        }
    }

    /// One request: `id` ties the answer to it; `key`: XSide's current `Key`.
    public struct Request: Equatable, Sendable {
        public let id: String
        public let command: Command
        public let key: String?

        public init(id: String = UUID().uuidString, command: Command, key: String? = nil) {
            self.id = id
            self.command = command
            self.key = key
        }

        /// The request, only when it carries `key`.
        public init?(userInfo: [AnyHashable: Any]?, requiringKey key: String) {
            guard let info = userInfo as? [String: String], info["key"] == key else { return nil }
            self.init(userInfo: info)
        }

        public var userInfo: [String: String] {
            commandInfo.merging(key.map { ["key": $0] } ?? [:]) { $1 }
        }

        private var commandInfo: [String: String] {
            switch command {
            case .refreshAll: ["id": id, "command": "refresh-all"]
            case .refreshApp(let record, let devices): Self.target("refresh-app", id, record, devices)
            case .pause(let seconds):
                ["id": id, "command": "pause"].merging(seconds.map { ["seconds": String($0)] } ?? [:]) { $1 }
            case .resume: ["id": id, "command": "resume"]
            case .editSettings(let record, let devices, let changes):
                Self.target("settings", id, record, devices).merging(["changes": changes.map(\.text).joined(separator: "\n")]) { $1 }
            case .pauseApp(let record, let devices, let seconds):
                Self.target("pause-app", id, record, devices).merging(seconds.map { ["seconds": String($0)] } ?? [:]) { $1 }
            case .resumeApp(let record, let devices): Self.target("resume-app", id, record, devices)
            case .uninstall(let record, let devices): Self.target("uninstall", id, record, devices)
            case .report: ["id": id, "command": "report"]
            case .crash(let record, let devices, let json):
                Self.target("crash", id, record, devices).merging(json ? ["json": "1"] : [:]) { $1 }
            }
        }

        private init(id: String, key: String?, command: Command) { self.init(id: id, command: command, key: key) }

        private static func target(_ command: String, _ id: String, _ record: UUID, _ devices: [String]) -> [String: String] {
            ["id": id, "command": command, "record": record.uuidString, "devices": devices.joined(separator: "\n")]
        }

        /// A pause's length as sent: 1 s to `maxPause` (mega review C3: longer, its end would be
        /// past the dates the channel can carry).
        private static func pauseSeconds(_ text: String) -> Int? {
            guard let seconds = Int(text), (1...CLIBridge.maxPause).contains(seconds) else { return nil }
            return seconds
        }

        public init?(userInfo: [AnyHashable: Any]?) {
            guard let info = userInfo as? [String: String], let id = info["id"] else { return nil }
            switch info["command"] {
            case "refresh-all": self.init(id: id, key: info["key"], command: .refreshAll)
            case "pause":
                // Present but unreadable: refused, never read as "until resumed".
                if let text = info["seconds"] {
                    guard let seconds = Self.pauseSeconds(text) else { return nil }
                    self.init(id: id, key: info["key"], command: .pause(seconds: seconds))
                } else {
                    self.init(id: id, key: info["key"], command: .pause(seconds: nil))
                }
            case "resume": self.init(id: id, key: info["key"], command: .resume)
            case "report": self.init(id: id, key: info["key"], command: .report)
            case "settings", "pause-app", "resume-app", "uninstall", "crash", "refresh-app":
                guard let record = info["record"].flatMap(UUID.init(uuidString:)),
                      let devices = info["devices"]?.split(separator: "\n").map(String.init), !devices.isEmpty else { return nil }
                switch info["command"] {
                case "settings":
                    var changes: [CLISettingChange] = []
                    for text in (info["changes"] ?? "").split(separator: "\n") {
                        guard case .success(let change) = CLISettingChange.parse(String(text)) else { return nil }
                        changes.append(change)
                    }
                    guard !changes.isEmpty else { return nil }
                    self.init(id: id, key: info["key"], command: .editSettings(recordID: record, deviceIDs: devices, changes: changes))
                case "pause-app":
                    if let text = info["seconds"] {
                        guard let seconds = Self.pauseSeconds(text) else { return nil }
                        self.init(id: id, key: info["key"], command: .pauseApp(recordID: record, deviceIDs: devices, seconds: seconds))
                    } else {
                        self.init(id: id, key: info["key"], command: .pauseApp(recordID: record, deviceIDs: devices, seconds: nil))
                    }
                case "resume-app": self.init(id: id, key: info["key"], command: .resumeApp(recordID: record, deviceIDs: devices))
                case "refresh-app": self.init(id: id, key: info["key"], command: .refreshApp(recordID: record, deviceIDs: devices))
                case "crash": self.init(id: id, key: info["key"], command: .crash(recordID: record, deviceIDs: devices, json: info["json"] == "1"))
                default: self.init(id: id, key: info["key"], command: .uninstall(recordID: record, deviceIDs: devices))
                }
            default: return nil
            }
        }
    }

    /// The app's answer: what it started, or why nothing did. `working`: not the answer yet, the
    /// request is being done (an uninstall, the report archive); the final answer follows.
    public struct Reply: Equatable, Sendable {
        public let id: String
        public let ok: Bool
        public let working: Bool
        public let message: String
        /// The answer itself is in the request's `ReplyFile` (`message` only says so).
        public let inFile: Bool

        public init(id: String, ok: Bool, message: String, inFile: Bool = false) {
            self.id = id
            self.ok = ok
            self.working = false
            self.message = message
            self.inFile = inFile
        }

        /// The interim answer: XSide has the request and is at it.
        public init(id: String, working: Bool, message: String) {
            self.id = id
            self.ok = true
            self.working = working
            self.message = message
            self.inFile = false
        }

        public var userInfo: [String: String] {
            ["id": id, "ok": ok ? "1" : "0", "message": message]
                .merging(working ? ["working": "1"] : [:]) { $1 }
                .merging(inFile ? ["file": "1"] : [:]) { $1 }
        }

        public init?(userInfo: [AnyHashable: Any]?) {
            guard let info = userInfo as? [String: String], let id = info["id"] else { return nil }
            if info["working"] == "1" {
                self.init(id: id, working: true, message: info["message"] ?? "")
            } else {
                self.init(id: id, ok: info["ok"] == "1", message: info["message"] ?? "", inFile: info["file"] == "1")
            }
        }
    }

    /// Where the answers that say more than "done" go (mega review C6): a crash diagnosis (the
    /// app, its library, the device) and the report archive's path. A distributed notification is
    /// heard by any program of the session, sandboxed ones included; this file, in the library
    /// next to the key, only by the user (0600, in a 0700 folder). Named after the request id (a
    /// UUID, nothing else); the tool reads it and deletes it; one nobody read goes after `lifetime`.
    public enum ReplyFile {
        public static let folderName = "cli-replies"
        public static let lifetime: TimeInterval = 10 * 60
        /// What the notification says instead (the tool prints the file's answer).
        public static let notice = "XSide's answer is in a file only you can read (xside prints it)."

        /// The commands whose final answer goes to a file.
        public static func isFor(_ command: Command) -> Bool {
            switch command {
            case .crash, .report: true
            default: false
            }
        }

        /// The request's file in `library`, nil when `id` isn't a UUID.
        public static func url(id: String, in library: URL) -> URL? {
            guard let uuid = UUID(uuidString: id) else { return nil }
            return library.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(uuid.uuidString)
        }

        /// Writes `reply` (atomically, 0600) and returns what the notification carries instead.
        /// Unread files older than `lifetime` go first.
        public static func write(_ reply: Reply, in library: URL, now: Date) throws -> Reply {
            guard let file = url(id: reply.id, in: library) else { throw CocoaError(.fileWriteInvalidFileName) }
            let fm = FileManager.default
            let folder = file.deletingLastPathComponent()
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            prune(folder, now: now)
            let body = try JSONSerialization.data(withJSONObject: ["ok": reply.ok, "message": reply.message])
            let temporary = folder.appendingPathComponent(".\(UUID().uuidString)")
            guard fm.createFile(atPath: temporary.path, contents: body, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if rename(temporary.path, file.path) != 0 {
                try? fm.removeItem(at: temporary)
                throw CocoaError(.fileWriteUnknown)
            }
            return Reply(id: reply.id, ok: reply.ok, message: notice, inFile: true)
        }

        /// The answer `reply` stands for: read from its file (then deleted) when it is in one.
        public static func take(_ reply: Reply, in library: URL) -> Reply {
            guard reply.inFile else { return reply }
            guard let file = url(id: reply.id, in: library), let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = object["message"] as? String else {
                return Reply(id: reply.id, ok: false, message: "XSide's answer couldn't be read (\(folderName) in its library)")
            }
            try? FileManager.default.removeItem(at: file)
            return Reply(id: reply.id, ok: (object["ok"] as? Bool) ?? false, message: message)
        }

        private static func prune(_ folder: URL, now: Date) {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
            for name in names {
                let path = folder.appendingPathComponent(name).path
                guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) > lifetime else { continue }
                try? fm.removeItem(atPath: path)
            }
        }
    }

    /// The app's memory of the requests it took (mega review C7): the tool sends its request
    /// every second until answered, and each copy gets the stored answer rather than running it
    /// again. Bounded: an entry not asked for `lifetime` goes, and beyond `capacity` finished
    /// answers the least recently asked go; one still being worked on is never dropped for room.
    public struct ReplyCache: Sendable {
        public static let capacity = 32
        public static let lifetime: TimeInterval = 10 * 60
        private var entries: [String: (reply: Reply, asked: Date)] = [:]

        public init() {}

        public var count: Int { entries.count }

        /// The stored answer to `id` (the request was taken), nil if new. Asking keeps it.
        public mutating func reply(for id: String, at now: Date) -> Reply? {
            expire(now)
            guard let entry = entries[id] else { return nil }
            entries[id] = (entry.reply, now)
            return entry.reply
        }

        public mutating func store(_ reply: Reply, at now: Date) {
            expire(now)
            entries[reply.id] = (reply, now)
            let finished = entries.filter { !$0.value.reply.working }
            if finished.count > Self.capacity {
                for (id, _) in finished.sorted(by: { $0.value.asked < $1.value.asked }).prefix(finished.count - Self.capacity) {
                    entries[id] = nil
                }
            }
        }

        private mutating func expire(_ now: Date) {
            entries = entries.filter { now.timeIntervalSince($0.value.asked) <= Self.lifetime }
        }
    }

    /// How long the tool waits for an answer (review D–G, Important 1). Before XSide answers at
    /// all: `firstAnswer` (it may be launching). Once it said it's working: as long as it keeps
    /// answering the repeated request (`silence` at most between two answers), up to `longest`.
    /// An outcome the tool can't know is never reported as a failure.
    public struct Wait: Sendable {
        public static let firstAnswer: TimeInterval = 30
        public static let silence: TimeInterval = 30
        public static let longest: TimeInterval = 30 * 60

        public enum Outcome: Equatable, Sendable {
            case waiting
            case finished(Reply)
            /// XSide never answered: not running, or too old to know the request.
            case noAnswer
            /// XSide said it was working, then went quiet (quit or hung): the outcome is unknown.
            case stoppedAnswering
            /// Still working after `longest`: the outcome is unknown yet.
            case stillWorking
            /// XSide restarted after it took the request (its key changed, mega review C7): the
            /// outcome is unknown, and the request isn't sent to the new XSide, which would do it again.
            case restarted

            /// 0 done, 1 failed or never started, 2 outcome unknown (see the panel or `xside apps`).
            public var exitCode: Int32 {
                switch self {
                case .finished(let reply): reply.ok ? 0 : 1
                case .waiting, .noAnswer: 1
                case .stoppedAnswering, .stillWorking, .restarted: 2
                }
            }
        }

        private let start: Date
        private var lastAnswer: Date?
        private var final: Reply?
        /// The key the request was last sent with, and the one it was sent with when XSide answered.
        private var sentKey: String?
        private var answeredKey: String?
        private var restarted = false

        public init(start: Date) { self.start = start }

        /// The request is about to be sent with `key` (XSide's key read just now): false, and the
        /// wait ends `.restarted`, when XSide answered with another key and hasn't finished.
        /// An unreadable key (nil) changes nothing.
        public mutating func sending(key: String?) -> Bool {
            if let key, final == nil, let answeredKey, key != answeredKey { restarted = true }
            if let key { sentKey = key }
            return !restarted
        }

        /// True once XSide answered anything about this request.
        public var acknowledged: Bool { lastAnswer != nil }

        /// An answer heard; one for another request (`requestID` given) is ignored.
        public mutating func received(_ reply: Reply, at date: Date, requestID: String? = nil) {
            if let requestID, reply.id != requestID { return }
            lastAnswer = date
            if answeredKey == nil { answeredKey = sentKey }
            if !reply.working { final = reply }
        }

        public func outcome(at now: Date) -> Outcome {
            if let final { return .finished(final) }
            if restarted { return .restarted }
            guard let lastAnswer else {
                return now.timeIntervalSince(start) > Self.firstAnswer ? .noAnswer : .waiting
            }
            if now.timeIntervalSince(start) > Self.longest { return .stillWorking }
            if now.timeIntervalSince(lastAnswer) > Self.silence { return .stoppedAnswering }
            return .waiting
        }
    }
}
