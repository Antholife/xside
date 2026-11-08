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
            case .editSettings(let record, let devices, let changes):
                Self.target("settings", id, record, devices).merging(["changes": changes.map(\.text).joined(separator: "\n")]) { $1 }
            case .pauseApp(let record, let devices, let seconds):
                Self.target("pause-app", id, record, devices).merging(seconds.map { ["seconds": String($0)] } ?? [:]) { $1 }
            case .resumeApp(let record, let devices): Self.target("resume-app", id, record, devices)
            case .uninstall(let record, let devices): Self.target("uninstall", id, record, devices)
            case .report: ["id": id, "command": "report"]
            }
        }

        private static func target(_ command: String, _ id: String, _ record: UUID, _ devices: [String]) -> [String: String] {
            ["id": id, "command": command, "record": record.uuidString, "devices": devices.joined(separator: "\n")]
        }

        public init?(userInfo: [AnyHashable: Any]?) {
            guard let info = userInfo as? [String: String], let id = info["id"] else { return nil }
            switch info["command"] {
            case "refresh-all": self.init(id: id, command: .refreshAll)
            case "refresh":
                guard let app = info["app"], !app.isEmpty else { return nil }
                self.init(id: id, command: .refresh(app: app, device: info["device"]))
            case "pause":
                // Present but unreadable: refused, never read as "until resumed".
                if let text = info["seconds"] {
                    guard let seconds = Int(text), seconds > 0 else { return nil }
                    self.init(id: id, command: .pause(seconds: seconds))
                } else {
                    self.init(id: id, command: .pause(seconds: nil))
                }
            case "resume": self.init(id: id, command: .resume)
            case "report": self.init(id: id, command: .report)
            case "settings", "pause-app", "resume-app", "uninstall":
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
                    self.init(id: id, command: .editSettings(recordID: record, deviceIDs: devices, changes: changes))
                case "pause-app":
                    if let text = info["seconds"] {
                        guard let seconds = Int(text), seconds > 0 else { return nil }
                        self.init(id: id, command: .pauseApp(recordID: record, deviceIDs: devices, seconds: seconds))
                    } else {
                        self.init(id: id, command: .pauseApp(recordID: record, deviceIDs: devices, seconds: nil))
                    }
                case "resume-app": self.init(id: id, command: .resumeApp(recordID: record, deviceIDs: devices))
                default: self.init(id: id, command: .uninstall(recordID: record, deviceIDs: devices))
                }
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
