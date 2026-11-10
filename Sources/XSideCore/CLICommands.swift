import Foundation

/// A misuse of the `xside` command line: what to print.
public struct CLIUsageError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// One in-app setting set from the command line (`xside settings <app> field=value`).
public enum CLISettingChange: Equatable, Sendable {
    case showValidity(Bool), alertLate(Bool), refreshCard(Bool), reminder(Bool)
    case language(MessageLanguage)
    /// Goes through the pause, as "Rafraîchissement automatique" does in the UI.
    case autoRefresh(Bool)
    /// Sets the four switches, as the "Messages XSide" menu does ("custom" is only ever derived).
    case level(MessageLevel)

    /// The fields `xside settings` knows, as typed.
    public static let fieldNames = ["showValidity", "alertLate", "refreshCard", "reminder", "language", "autoRefresh", "level"]

    /// "reminder=off", "language=auto", "level=essentials". Field names are case-insensitive.
    public static func parse(_ text: String) -> Result<CLISettingChange, CLIUsageError> {
        let parts = text.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else {
            return .failure(CLIUsageError("\(text): expected field=value (fields: \(fieldNames.joined(separator: ", ")))"))
        }
        let field = parts[0].lowercased(), value = parts[1].lowercased()
        func bool(_ make: (Bool) -> CLISettingChange) -> Result<CLISettingChange, CLIUsageError> {
            switch value {
            case "on", "true", "yes", "1": return .success(make(true))
            case "off", "false", "no", "0": return .success(make(false))
            default: return .failure(CLIUsageError("\(parts[0])=\(parts[1]): \(parts[1]) isn't on or off"))
            }
        }
        switch field {
        case "showvalidity": return bool(CLISettingChange.showValidity)
        case "alertlate": return bool(CLISettingChange.alertLate)
        case "refreshcard": return bool(CLISettingChange.refreshCard)
        case "reminder": return bool(CLISettingChange.reminder)
        case "autorefresh": return bool(CLISettingChange.autoRefresh)
        case "language":
            switch value {
            case "auto", "automatic": return .success(.language(.automatic))
            case "fr": return .success(.language(.fr))
            case "en": return .success(.language(.en))
            default: return .failure(CLIUsageError("language=\(parts[1]): \(parts[1]) isn't auto, fr or en"))
            }
        case "level":
            switch value {
            case "all": return .success(.level(.all))
            case "essentials": return .success(.level(.essentials))
            case "none": return .success(.level(.none))
            default: return .failure(CLIUsageError("level=\(parts[1]): \(parts[1]) isn't all, essentials or none"))
            }
        default:
            return .failure(CLIUsageError("\(parts[0]): no such setting (fields: \(fieldNames.joined(separator: ", ")))"))
        }
    }

    /// The bridge's text form ("reminder=off"), read back by `parse`.
    public var text: String {
        func onOff(_ b: Bool) -> String { b ? "on" : "off" }
        switch self {
        case .showValidity(let b): return "showValidity=\(onOff(b))"
        case .alertLate(let b): return "alertLate=\(onOff(b))"
        case .refreshCard(let b): return "refreshCard=\(onOff(b))"
        case .reminder(let b): return "reminder=\(onOff(b))"
        case .autoRefresh(let b): return "autoRefresh=\(onOff(b))"
        case .language(let l): return "language=\(l == .automatic ? "auto" : l.rawValue)"
        case .level(let l): return "level=\(l.rawValue)"
        }
    }
}

extension InAppSettings {
    /// `changes` applied in order as the Mac's UI does, stamped by the Mac at `date`. "Automatic
    /// refresh" is left alone: it goes with the pause (`AppLibrary.setRefreshPaused`).
    public func applying(_ changes: [CLISettingChange], at date: Date) -> InAppSettings {
        changes.reduce(self) { s, change in
            switch change {
            case .showValidity(let b): s.setting(\.showValidity, to: b, at: date, by: .mac)
            case .alertLate(let b): s.setting(\.alertLate, to: b, at: date, by: .mac)
            case .refreshCard(let b): s.setting(\.refreshCard, to: b, at: date, by: .mac)
            case .reminder(let b): s.setting(\.reminder, to: b, at: date, by: .mac)
            case .language(let l): s.setting(\.language, to: l, at: date, by: .mac)
            case .level(let l): s.applying(level: l, at: date, by: .mac)
            case .autoRefresh: s
            }
        }
    }
}

/// What `xside` was asked to do (device feedback 3, E7 adds apps, devices, settings, a pause of
/// one app, uninstall, logs and report).
public enum CLIInvocation: Equatable, Sendable {
    case help
    case status(json: Bool)
    case apps(json: Bool)
    case devices(json: Bool)
    case showSettings(app: String, device: String?, json: Bool)
    case setSettings(app: String, device: String?, changes: [CLISettingChange])
    case refreshAll
    case refresh(app: String, device: String?)
    /// Every automatic refresh (`xside pause [duration]`); nil seconds: until resumed.
    case pauseAll(seconds: Int?)
    case resumeAll
    case pauseApp(app: String, device: String?, seconds: Int?)
    case resumeApp(app: String, device: String?)
    case uninstall(app: String, device: String?, yes: Bool)
    case logs(follow: Bool)
    case report
    /// Why the app crashed lately (its newest crash log on the device, explained).
    case crash(app: String, device: String?, json: Bool)
    case install(path: String)
    case open

    /// The arguments after `xside` (without `--debug` / `--version`, read by the tool itself).
    public static func parse(_ arguments: [String]) -> Result<CLIInvocation, CLIUsageError> {
        var args = arguments.filter { !$0.isEmpty }
        func flag(_ names: String...) -> Bool {
            guard let i = args.firstIndex(where: { names.contains($0) }) else { return false }
            args.remove(at: i)
            return true
        }
        func option(_ name: String) -> Result<String?, CLIUsageError> {
            guard let i = args.firstIndex(of: name) else { return .success(nil) }
            guard i + 1 < args.count else { return .failure(CLIUsageError("\(name) needs a value")) }
            let value = args[i + 1]
            args.removeSubrange(i...i + 1)
            return .success(value)
        }
        /// Nothing left over, or an error naming it.
        func done(_ invocation: CLIInvocation) -> Result<CLIInvocation, CLIUsageError> {
            args.isEmpty ? .success(invocation) : .failure(CLIUsageError("unexpected \(args.joined(separator: " "))"))
        }
        guard !args.isEmpty else { return .success(.help) }
        let command = args.removeFirst()
        switch command {
        case "help", "-h", "--help": return .success(.help)
        case "status": return done(.status(json: flag("--json")))
        case "apps": return done(.apps(json: flag("--json")))
        case "devices": return done(.devices(json: flag("--json")))
        case "logs": return done(.logs(follow: flag("-f", "--follow")))
        case "report": return done(.report)
        case "open": return done(.open)
        case "install":
            guard args.count == 1 else { return .failure(CLIUsageError("which .ipa? (xside install <file.ipa>)")) }
            return .success(.install(path: args[0]))
        case "refresh":
            if flag("--all") { return done(.refreshAll) }
            guard case .success(let device) = option("--device") else { return .failure(CLIUsageError("--device needs a value")) }
            guard !args.isEmpty else { return .failure(CLIUsageError("which app? (xside refresh <app>, or --all)")) }
            let app = args.removeFirst()
            return done(.refresh(app: app, device: device))
        case "settings":
            let json = flag("--json")
            guard case .success(let device) = option("--device") else { return .failure(CLIUsageError("--device needs a value")) }
            guard !args.isEmpty else { return .failure(CLIUsageError("which app? (xside settings <app> [field=value…])")) }
            let app = args.removeFirst()
            if args.isEmpty { return .success(.showSettings(app: app, device: device, json: json)) }
            // Changing prints a sentence, not JSON: say so rather than drop the flag (review D–G m3).
            if json { return .failure(CLIUsageError("--json only shows settings; leave it out to change them")) }
            var changes: [CLISettingChange] = []
            for text in args {
                switch CLISettingChange.parse(text) {
                case .success(let change): changes.append(change)
                case .failure(let error): return .failure(error)
                }
            }
            return .success(.setSettings(app: app, device: device, changes: changes))
        case "pause":
            guard case .success(let device) = option("--device") else { return .failure(CLIUsageError("--device needs a value")) }
            // `pause` and `pause 2h`: every refresh, as before. Otherwise the first word is the app.
            if args.isEmpty, device == nil { return .success(.pauseAll(seconds: nil)) }
            if args.count == 1, device == nil, let seconds = CLIBridge.duration(args[0]) { return .success(.pauseAll(seconds: seconds)) }
            guard !args.isEmpty else { return .failure(CLIUsageError("which app? (xside pause <app> [2h|30m|1d])")) }
            let app = args.removeFirst()
            var seconds: Int?
            if !args.isEmpty {
                let text = args.removeFirst()
                guard let s = CLIBridge.duration(text) else { return .failure(CLIUsageError("\(text) isn't a duration (e.g. 2h, 30m, 1d)")) }
                seconds = s
            }
            return done(.pauseApp(app: app, device: device, seconds: seconds))
        case "resume":
            guard case .success(let device) = option("--device") else { return .failure(CLIUsageError("--device needs a value")) }
            if args.isEmpty, device == nil { return .success(.resumeAll) }
            guard !args.isEmpty else { return .failure(CLIUsageError("which app? (xside resume <app>)")) }
            let app = args.removeFirst()
            return done(.resumeApp(app: app, device: device))
        case "uninstall":
            let yes = flag("--yes", "-y")
            guard case .success(let device) = option("--device") else { return .failure(CLIUsageError("--device needs a value")) }
            guard !args.isEmpty else { return .failure(CLIUsageError("which app? (xside uninstall <app> [--device <name>])")) }
            let app = args.removeFirst()
            return done(.uninstall(app: app, device: device, yes: yes))
        case "crash":
            let json = flag("--json")
            guard case .success(let device) = option("--device") else { return .failure(CLIUsageError("--device needs a value")) }
            guard !args.isEmpty else { return .failure(CLIUsageError("which app? (xside crash <app> [--device <name>])")) }
            let app = args.removeFirst()
            return done(.crash(app: app, device: device, json: json))
        default:
            return .failure(CLIUsageError("unknown command \(command)"))
        }
    }
}

/// Finds the installations an `xside` command names: apps by name or bundle id, devices by name
/// or id, case-insensitive. An exact match wins over a partial one; several different apps (or
/// devices) is an error that lists them, never a guess.
public enum CLIMatch {
    public struct Candidate: Equatable, Sendable {
        public let recordID: UUID
        public let deviceID: String
        public let app: String
        public let bundleID: String
        public let device: String

        public init(recordID: UUID, deviceID: String, app: String, bundleID: String, device: String) {
            self.recordID = recordID
            self.deviceID = deviceID
            self.app = app
            self.bundleID = bundleID
            self.device = device
        }
    }

    /// Every installation of `records`, named with `deviceNames` (id when unknown).
    public static func candidates(_ records: [AppRecord], deviceNames: [String: String]) -> [Candidate] {
        records.flatMap { r in
            r.installations.map { i in
                Candidate(recordID: r.id, deviceID: i.deviceID, app: r.options.displayName ?? r.displayName,
                          bundleID: r.originalBundleID,
                          device: (deviceNames[i.deviceID] ?? i.deviceID).trimmingCharacters(in: .whitespaces))
            }
        }
    }

    public static func find(app: String, device: String?, in all: [Candidate]) -> Result<[Candidate], CLIUsageError> {
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        var matches = all.filter { same($0.app, app) || same($0.bundleID, app) }
        if matches.isEmpty {
            matches = all.filter { $0.app.localizedCaseInsensitiveContains(app) || $0.bundleID.localizedCaseInsensitiveContains(app) }
        }
        guard !matches.isEmpty else { return .failure(CLIUsageError("no app matches \"\(app)\" (see xside apps)")) }
        var seen = Set<UUID>()
        let apps = matches.filter { seen.insert($0.recordID).inserted }
        if apps.count > 1 {
            return .failure(CLIUsageError("\"\(app)\" matches several apps: "
                + apps.map { "\($0.app) (\($0.bundleID))" }.joined(separator: ", ") + ". Be more precise."))
        }
        guard let device else { return .success(matches) }
        var onDevice = matches.filter { same($0.device, device) || $0.deviceID == device }
        if onDevice.isEmpty { onDevice = matches.filter { $0.device.localizedCaseInsensitiveContains(device) } }
        guard !onDevice.isEmpty else {
            return .failure(CLIUsageError("\(apps[0].app) isn't on a device matching \"\(device)\" (it is on "
                + matches.map(\.device).joined(separator: ", ") + ")"))
        }
        if onDevice.count > 1 {
            return .failure(CLIUsageError("\"\(device)\" matches several devices: "
                + onDevice.map { deviceLabel(name: $0.device, id: $0.deviceID) }.joined(separator: ", ")
                + ". Be more precise, or give its id (--device <id>)."))
        }
        return .success(onDevice)
    }

    /// "iPhone (00008110-…)": a device's name with its id, which tells apart two of the same name
    /// (mega review C11); the id alone when it has no other name.
    public static func deviceLabel(name: String, id: String) -> String {
        name == id ? id : "\(name) (\(id))"
    }
}

/// `--debug` and `--version`, read by the tool itself, only before the command word (mega review
/// C10): after it, they are the command's own words, e.g. a `--device` value.
public struct CLIGlobalFlags: Equatable, Sendable {
    public var debug: Bool
    public var version: Bool
    /// The command and its arguments, for `CLIInvocation.parse`.
    public var rest: [String]

    public init(debug: Bool, version: Bool, rest: [String]) {
        self.debug = debug
        self.version = version
        self.rest = rest
    }

    public init(_ arguments: [String]) {
        var rest = arguments[...]
        var debug = false, version = false
        while let first = rest.first, first == "--debug" || first == "--version" {
            if first == "--debug" { debug = true } else { version = true }
            rest = rest.dropFirst()
        }
        self.init(debug: debug, version: version, rest: Array(rest))
    }
}

/// `xside status`'s wording.
public enum CLIStatus {
    /// What follows an app's days left: its own pause (with its end, mega review C9), every
    /// refresh paused, or its next refresh.
    public static func refreshNote(paused: Bool, pausedUntil: Date?, allPaused: Bool, nextRefresh: Date, now: Date,
                                   format: Date.FormatStyle) -> String {
        if paused { return pausedUntil.map { " · paused until \($0.formatted(format))" } ?? " · paused" }
        if allPaused { return " · refreshes paused" }
        return " · next refresh \(max(nextRefresh, now).formatted(format))"
    }
}

/// What `xside … --json` prints on stdout: one JSON document, even on failure (progress and
/// notes go to stderr), so a script can always parse it.
public enum CLIJSONOutput {
    /// `{"error": …, "ok": false}`.
    public static func error(_ message: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message], options: [.prettyPrinted, .sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? #"{"ok": false}"#
    }

    /// XSide's answer when it's JSON already, else that answer as an error document.
    public static func document(fromReply message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])) != nil,
           trimmed.first == "[" || trimmed.first == "{" {
            return message
        }
        return error(trimmed.isEmpty ? "XSide gave no answer" : message)
    }

    /// The document for how a request to XSide ended.
    public static func document(for outcome: CLIBridge.Wait.Outcome) -> String {
        if case .finished(let reply) = outcome { return document(fromReply: reply.message) }
        return error(message(for: outcome) ?? "no answer from XSide")
    }

    /// Why a request ended without XSide's answer (nil when it answered).
    public static func message(for outcome: CLIBridge.Wait.Outcome) -> String? {
        switch outcome {
        case .finished: nil
        case .noAnswer, .waiting: "no answer from XSide (is it running and up to date?)"
        case .stoppedAnswering: "XSide stopped answering while working on it; the outcome is unknown: check its panel or xside apps"
        case .stillWorking: "XSide is still working on it; check its panel or xside apps"
        case .restarted: "XSide restarted while working on it; the outcome is unknown: check its panel or xside apps"
        }
    }
}
