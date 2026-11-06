import Foundation

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
        /// Apps whose name or bundle id contains `app` (case-insensitive), on `device` if given
        /// (name contains it, or its id).
        case refresh(app: String, device: String?)
        /// Pause automatic refreshes for `seconds`, or until resumed (nil).
        case pause(seconds: Int?)
        case resume
    }

    /// "2h", "30m", "1d", or a number of minutes; nil when it isn't a positive duration.
    public static func duration(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [Character: Int] = ["m": 60, "h": 3600, "d": 86_400]
        let unit = t.last.flatMap { units[$0] }
        guard let value = Int(unit == nil ? t : String(t.dropLast())), value > 0 else { return nil }
        return value * (unit ?? 60)
    }

    /// One request: `id` ties the answer to it.
    public struct Request: Equatable, Sendable {
        public let id: String
        public let command: Command

        public init(id: String = UUID().uuidString, command: Command) {
            self.id = id
            self.command = command
        }

        public var userInfo: [String: String] {
            switch command {
            case .refreshAll: ["id": id, "command": "refresh-all"]
            case .refresh(let app, let device):
                ["id": id, "command": "refresh", "app": app].merging(device.map { ["device": $0] } ?? [:]) { $1 }
            case .pause(let seconds):
                ["id": id, "command": "pause"].merging(seconds.map { ["seconds": String($0)] } ?? [:]) { $1 }
            case .resume: ["id": id, "command": "resume"]
            }
        }

        public init?(userInfo: [AnyHashable: Any]?) {
            guard let info = userInfo as? [String: String], let id = info["id"] else { return nil }
            switch info["command"] {
            case "refresh-all": self.init(id: id, command: .refreshAll)
            case "refresh":
                guard let app = info["app"], !app.isEmpty else { return nil }
                self.init(id: id, command: .refresh(app: app, device: info["device"]))
            case "pause": self.init(id: id, command: .pause(seconds: info["seconds"].flatMap { Int($0) }))
            case "resume": self.init(id: id, command: .resume)
            default: return nil
            }
        }
    }

    /// The app's answer: what it started, or why nothing did.
    public struct Reply: Equatable, Sendable {
        public let id: String
        public let ok: Bool
        public let message: String

        public init(id: String, ok: Bool, message: String) {
            self.id = id
            self.ok = ok
            self.message = message
        }

        public var userInfo: [String: String] { ["id": id, "ok": ok ? "1" : "0", "message": message] }

        public init?(userInfo: [AnyHashable: Any]?) {
            guard let info = userInfo as? [String: String], let id = info["id"] else { return nil }
            self.init(id: id, ok: info["ok"] == "1", message: info["message"] ?? "")
        }
    }
}
