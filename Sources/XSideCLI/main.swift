import AppKit
import Foundation
import XSideCore

/// `xside`: XSide from the Terminal. `status` reads the library itself (read only); `refresh`
/// and `install` ask XSide, started in the background if needed, which does the work (it alone
/// signs and installs: two programs never sign at once).

setvbuf(stdout, nil, _IOLBF, 0) // line by line, even through a pipe

let usage = """
    Usage: xside <command> [options]

      status [--json]                      Apps, devices and days left
      apps [--json]                        The apps XSide installed, with their devices
      devices [--json]                     The devices and how many apps each has
      settings <app> [--device <name>] [--json]
                                           Show the XSide module's settings of an app
      settings <app> [--device <name>] <field>=<value>…
                                           Change them, as in Settings > My apps. Fields:
                                           showValidity, alertLate, refreshCard, reminder (on|off),
                                           language (auto|fr|en), autoRefresh (on|off),
                                           level (all|essentials|none)
      refresh <app> [--device <name>]      Refresh an app now
      refresh --all                        Refresh every app that can be now
      pause [<duration>]                   Pause every automatic refresh: 2h, 30m, 1d… (none: until resumed)
      resume                               Resume every automatic refresh
      pause <app> [<duration>] [--device <name>]
                                           Pause one app's refreshes (none: until resumed)
      resume <app> [--device <name>]       Resume one app's refreshes
      uninstall <app> [--device <name>] [--yes]
                                           Remove an app from its devices (asks first unless --yes)
      install <file.ipa>                   Open the .ipa in XSide's install window
      logs [-f]                            Print XSide's log (-f: follow it)
      report                               Write the logs archive for a bug report, print its path
      open                                 Open XSide

      <app> is a name or a bundle id, any case; part of it is fine when only one app matches.
      Exit status: 0 done, 1 failed, 2 not known yet (XSide still working: see its panel).
      --debug     Talk to XSide-debug instead of XSide
      --version   Print the version
    """

var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func takeFlag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("xside: \(message)\n".utf8))
    exit(1)
}

let debug = takeFlag("--debug")
#if DEBUG
/// Debug builds only: talk to a stand-in (a test responder) instead of XSide; nothing is launched.
let testBundleID = ProcessInfo.processInfo.environment["XSIDE_CLI_TEST_BUNDLE_ID"]
#else
let testBundleID: String? = nil
#endif
let bundleID = testBundleID ?? (debug ? "io.github.xside.XSide.debug" : "io.github.xside.XSide")
let libraryRoot = testBundleID != nil
    // The stand-in's own folder (its key), never XSide's library.
    ? URL(fileURLWithPath: ProcessInfo.processInfo.environment["XSIDE_CLI_TEST_LIBRARY"] ?? "/nonexistent", isDirectory: true)
    : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(LibraryLocation.folderName(bundleID: bundleID), isDirectory: true)

if takeFlag("--version") {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    print("xside \(version ?? CLIVersion.bundled ?? "dev")")
    exit(0)
}

enum CLIVersion {
    /// The enclosing app's version, when the tool runs from inside XSide.app.
    static var bundled: String? {
        let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

var isAppRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

// MARK: - status

@MainActor func status(json: Bool) {
    guard let records = AppLibrary.readRecords(root: libraryRoot) else {
        if json { print("{\"running\":\(isAppRunning),\"apps\":[]}") } else { print("No app installed with XSide yet.") }
        return
    }
    let defaults = UserDefaults(suiteName: bundleID)
    let names = defaults?.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
    let now = Date()
    // XSide's own settings: how long before expiry it refreshes, and whether that's paused.
    let threshold = RefreshPlanner.threshold(daysBefore: defaults?.integer(forKey: "refreshDaysBefore") ?? 0,
                                             debugDays: defaults?.double(forKey: "debugThresholdDays") ?? 0)
    let pausedStored = defaults?.double(forKey: "refreshPausedUntil") ?? 0
    let pausedUntil = pausedStored > 0 && Date(timeIntervalSince1970: pausedStored) > now ? Date(timeIntervalSince1970: pausedStored) : nil
    struct Row: Encodable {
        let app: String, bundleID: String, device: String, deviceID: String
        let expires: Date, daysLeft: Int, nextRefresh: Date, paused: Bool, lastError: String?
    }
    let rows: [Row] = records.flatMap { record in
        record.installations.map { i in
            Row(app: record.options.displayName ?? record.displayName, bundleID: record.originalBundleID,
                device: names[i.deviceID] ?? i.deviceID, deviceID: i.deviceID, expires: i.expiresAt,
                daysLeft: max(0, Int((i.expiresAt.timeIntervalSince(now) / 86_400).rounded(.up))),
                nextRefresh: i.expiresAt.addingTimeInterval(-threshold),
                paused: i.refreshPaused, lastError: i.lastErrorKey)
        }
    }
    if json {
        /// `pausedUntil`: automatic refreshes paused until then (absent: not paused; far future: until resumed).
        struct Status: Encodable { let running: Bool; let pausedUntil: Date?; let apps: [Row] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: (try? encoder.encode(Status(running: isAppRunning, pausedUntil: pausedUntil, apps: rows))) ?? Data(), as: UTF8.self))
        return
    }
    if !isAppRunning { print("⚠️  XSide isn't running: nothing gets refreshed until it is (xside open).\n") }
    if let until = pausedUntil {
        print(until == .distantFuture ? "⏸  Automatic refreshes paused until resumed (xside resume).\n"
                                     : "⏸  Automatic refreshes paused until \(until.formatted(date: .abbreviated, time: .shortened)) (xside resume).\n")
    }
    if rows.isEmpty { print("No app installed with XSide yet."); return }
    let date = Date.FormatStyle(date: .abbreviated, time: .shortened)
    for device in Dictionary(grouping: rows, by: \.device).keys.sorted() {
        print(device)
        for row in rows.filter({ $0.device == device }).sorted(by: { $0.expires < $1.expires }) {
            var line = "  \(row.app.padding(toLength: 24, withPad: " ", startingAt: 0)) "
            if row.expires <= now {
                line += "expired"
            } else {
                line += "\(row.daysLeft) day\(row.daysLeft == 1 ? "" : "s") left"
                line += row.paused ? " · paused"
                    : pausedUntil != nil ? " · refreshes paused"
                    : " · next refresh \(max(row.nextRefresh, now).formatted(date))"
            }
            if let error = row.lastError, !row.paused { line += " · last refresh failed (\(error))" }
            print(line)
        }
    }
}

// MARK: - requests to the app

/// Starts XSide in the background (no window, not brought forward) when it isn't running.
@MainActor func launchInBackground() {
    guard !isAppRunning, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
    print("Starting XSide…")
    fflush(stdout) // before an error printed on stderr
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in done.signal() }
    done.wait()
}

/// Sends `command` to XSide (started first if needed) and prints its answer. The request is
/// sent again every second: until the app, maybe still launching, answers (30 s at most), then
/// as long as it answers "working" (an uninstall, the report archive), up to `CLIBridge.Wait`'s
/// longest wait. Exit 0 done, 1 failed or never answered, 2 outcome unknown (review D–G, I1).
@MainActor func ask(_ command: CLIBridge.Command) -> Never {
    if testBundleID == nil {
        launchInBackground()
        guard isAppRunning || NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            fail("XSide isn't installed")
        }
    }
    let id = UUID().uuidString
    /// Read before each send: XSide writes a new key when it starts (`CLIBridge.Key`).
    var request: CLIBridge.Request { CLIBridge.Request(id: id, command: command, key: CLIBridge.Key.read(in: libraryRoot)) }
    let center = DistributedNotificationCenter.default()
    nonisolated(unsafe) var wait = CLIBridge.Wait(start: Date())
    nonisolated(unsafe) var workingMessage: String?
    let observer = center.addObserver(forName: CLIBridge.replyName(bundleID: bundleID), object: nil, queue: .main) { note in
        guard let answer = CLIBridge.Reply(userInfo: note.userInfo) else { return }
        wait.received(answer, at: Date(), requestID: id)
        if answer.id == id, answer.working { workingMessage = answer.message }
    }
    var lastSent = Date.distantPast
    let askedAt = Date()
    var shownWorking = false, lastProgress = Date()
    var outcome = wait.outcome(at: Date())
    while outcome == .waiting {
        let now = Date()
        if now.timeIntervalSince(lastSent) >= 1 {
            center.postNotificationName(CLIBridge.requestName(bundleID: bundleID), object: nil,
                                        userInfo: request.userInfo, deliverImmediately: true)
            lastSent = now
        }
        // Progress, so a long wait never looks stuck: the app's own words once (after 2 s, so a
        // quick answer prints alone), then a line a minute.
        if let message = workingMessage, !shownWorking, now.timeIntervalSince(askedAt) >= 2 {
            print(message)
            shownWorking = true
            lastProgress = now
        } else if shownWorking, now.timeIntervalSince(lastProgress) >= 60 {
            print("Still working…")
            lastProgress = now
        }
        RunLoop.main.run(until: now.addingTimeInterval(0.1))
        outcome = wait.outcome(at: Date())
    }
    center.removeObserver(observer)
    switch outcome {
    case .finished(let reply) where reply.ok:
        print(reply.message)
    case .finished(let reply):
        FileHandle.standardError.write(Data("xside: \(reply.message)\n".utf8))
    case .noAnswer:
        FileHandle.standardError.write(Data("xside: no answer from XSide (is it running and up to date?)\n".utf8))
    case .stoppedAnswering:
        FileHandle.standardError.write(Data("xside: XSide stopped answering while working on it; the outcome is unknown: check its panel or xside apps\n".utf8))
    case .stillWorking, .waiting:
        FileHandle.standardError.write(Data("xside: XSide is still working on it; check its panel or xside apps\n".utf8))
    }
    exit(outcome.exitCode)
}

@MainActor func openApp(with file: URL? = nil) -> Never {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        fail("XSide isn't installed")
    }
    let done = DispatchSemaphore(value: 0)
    let configuration = NSWorkspace.OpenConfiguration()
    nonisolated(unsafe) var failure: (any Error)?
    let completion: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { _, error in
        failure = error
        done.signal()
    }
    if let file {
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration, completionHandler: completion)
    } else {
        NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: completion)
    }
    done.wait()
    if let failure { fail(failure.localizedDescription) }
    if let file { print("Opened \(file.lastPathComponent) in XSide's install window.") }
    exit(0)
}

// MARK: - apps, devices, settings (device feedback 3, E7)

/// The library, read only, and the devices' names as XSide last saw them.
@MainActor func library() -> (records: [AppRecord], names: [String: String]) {
    let names = UserDefaults(suiteName: bundleID)?.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
    return (AppLibrary.readRecords(root: libraryRoot) ?? [], names)
}

@MainActor func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self))
}

/// The installations `app` (and `device`) name, or the error printed.
@MainActor func resolve(_ app: String, _ device: String?) -> [CLIMatch.Candidate] {
    let (records, names) = library()
    switch CLIMatch.find(app: app, device: device, in: CLIMatch.candidates(records, deviceNames: names)) {
    case .success(let found): return found
    case .failure(let error): fail(error.message)
    }
}

@MainActor func apps(json: Bool) {
    let (records, names) = library()
    struct App: Encodable { let app: String; let bundleID: String; let version: String?; let devices: [String] }
    let rows = records.filter { !$0.installations.isEmpty }.map { r in
        App(app: r.options.displayName ?? r.displayName, bundleID: r.originalBundleID, version: r.version,
            devices: r.installations.map { names[$0.deviceID] ?? $0.deviceID })
    }
    if json { printJSON(rows); return }
    if rows.isEmpty { print("No app installed with XSide yet."); return }
    for row in rows {
        print("\(row.app.padding(toLength: 24, withPad: " ", startingAt: 0)) \(row.bundleID) · \(row.devices.joined(separator: ", "))")
    }
}

@MainActor func devices(json: Bool) {
    let (records, names) = library()
    struct Device: Encodable { let name: String; let id: String; let apps: [String] }
    var ids = Array(names.keys)
    for id in records.flatMap({ $0.installations.map(\.deviceID) }) where !ids.contains(id) { ids.append(id) }
    let rows = ids.map { id in
        Device(name: names[id] ?? id, id: id,
               apps: records.filter { $0.installations.contains { $0.deviceID == id } }.map { $0.options.displayName ?? $0.displayName })
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    if json { printJSON(rows); return }
    if rows.isEmpty { print("No device known to XSide yet."); return }
    for row in rows {
        let count = row.apps.count == 1 ? "1 app" : "\(row.apps.count) apps"
        print("\(row.name) · \(count)\(row.apps.isEmpty ? "" : ": " + row.apps.joined(separator: ", "))")
    }
}

@MainActor func showSettings(app: String, device: String?, json: Bool) {
    let found = resolve(app, device)
    let records = library().records
    struct Value: Encodable { let value: String; let changedBy: String; let changedAt: Date }
    struct Shown: Encodable {
        let app: String, bundleID: String, device: String, deviceID: String
        let xsideFeatures: Bool, level: String, settings: [String: Value]
    }
    let reminder = UserDefaults(suiteName: bundleID)?.object(forKey: "deviceReminder") as? Bool ?? true
    let rows: [Shown] = found.compactMap { c in
        guard let record = records.first(where: { $0.id == c.recordID }),
              let i = record.installations.first(where: { $0.deviceID == c.deviceID }) else { return nil }
        let s = i.seededInApp(reminder: reminder, at: i.installedAt)
        func v<V>(_ f: Field<V>, _ text: String) -> Value { Value(value: text, changedBy: f.changedBy.rawValue, changedAt: f.changedAt) }
        func onOff(_ b: Bool) -> String { b ? "on" : "off" }
        return Shown(app: c.app, bundleID: c.bundleID, device: c.device, deviceID: c.deviceID,
                     xsideFeatures: i.withoutXSideFeatures != true, level: s.derivedLevel.rawValue,
                     settings: ["showValidity": v(s.showValidity, onOff(s.showValidity.value)),
                                "alertLate": v(s.alertLate, onOff(s.alertLate.value)),
                                "refreshCard": v(s.refreshCard, onOff(s.refreshCard.value)),
                                "reminder": v(s.reminder, onOff(s.reminder.value)),
                                "language": v(s.language, s.language.value == .automatic ? "auto" : s.language.value.rawValue),
                                "autoRefresh": v(s.autoRefresh, onOff(s.autoRefresh.value))])
    }
    if json { printJSON(rows); return }
    let date = Date.FormatStyle(date: .abbreviated, time: .shortened)
    for (n, row) in rows.enumerated() {
        if n > 0 { print("") }
        print("\(row.app) on \(row.device)\(row.xsideFeatures ? "" : " (installed without XSide features)")")
        print("  level         \(row.level)")
        for field in CLISettingChange.fieldNames where field != "level" {
            guard let value = row.settings[field] else { continue }
            let who = value.changedBy == "mac" ? "Mac" : "device"
            print("  \(field.padding(toLength: 13, withPad: " ", startingAt: 0)) \(value.value.padding(toLength: 5, withPad: " ", startingAt: 0)) (\(who), \(value.changedAt.formatted(date)))")
        }
    }
}

/// `xside logs [-f]`: the current log file, or followed as it grows.
@MainActor func logs(follow: Bool) -> Never {
    let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/\(debug ? "XSide-debug" : "XSide")", isDirectory: true)
    let file = folder.appendingPathComponent(LogStore.fileName)
    guard FileManager.default.fileExists(atPath: file.path) else { fail("no log yet (\(file.path))") }
    let tail = Process()
    tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    tail.arguments = follow ? ["-n", "50", "-F", file.path] : ["-n", "200", file.path]
    do { try tail.run() } catch { fail(error.localizedDescription) }
    tail.waitUntilExit()
    exit(tail.terminationStatus)
}

/// "Uninstall YouTube from iPhone Duo? [y/N]"; read from the terminal.
func confirmed(_ question: String) -> Bool {
    print("\(question) [y/N] ", terminator: "")
    fflush(stdout)
    guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
    return answer == "y" || answer == "yes" || answer == "o" || answer == "oui"
}

// MARK: - main

switch CLIInvocation.parse(arguments) {
case .failure(let error):
    fail("\(error.message) (xside help for the commands)")
case .success(let invocation):
    switch invocation {
    case .help: print(usage)
    case .status(let json): status(json: json)
    case .apps(let json): apps(json: json)
    case .devices(let json): devices(json: json)
    case .showSettings(let app, let device, let json): showSettings(app: app, device: device, json: json)
    case .setSettings(let app, let device, let changes):
        let found = resolve(app, device)
        ask(.editSettings(recordID: found[0].recordID, deviceIDs: found.map(\.deviceID), changes: changes))
    case .refreshAll: ask(.refreshAll)
    case .refresh(let app, let device): ask(.refresh(app: app, device: device))
    case .pauseAll(let seconds): ask(.pause(seconds: seconds))
    case .resumeAll: ask(.resume)
    case .pauseApp(let app, let device, let seconds):
        let found = resolve(app, device)
        ask(.pauseApp(recordID: found[0].recordID, deviceIDs: found.map(\.deviceID), seconds: seconds))
    case .resumeApp(let app, let device):
        let found = resolve(app, device)
        ask(.resumeApp(recordID: found[0].recordID, deviceIDs: found.map(\.deviceID)))
    case .uninstall(let app, let device, let yes):
        let found = resolve(app, device)
        let what = "\(found[0].app) from \(found.map(\.device).joined(separator: ", "))"
        if !yes {
            guard isatty(STDIN_FILENO) != 0 else { fail("uninstall \(what): add --yes to confirm without a terminal") }
            guard confirmed("Uninstall \(what)? Its data on the device is lost.") else { print("Nothing uninstalled."); exit(0) }
        }
        ask(.uninstall(recordID: found[0].recordID, deviceIDs: found.map(\.deviceID)))
    case .logs(let follow): logs(follow: follow)
    case .report: ask(.report)
    case .install(let path):
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard file.pathExtension.lowercased() == "ipa" else { fail("\(file.lastPathComponent) isn't an .ipa") }
        guard FileManager.default.fileExists(atPath: file.path) else { fail("no such file: \(path)") }
        openApp(with: file)
    case .open: openApp()
    }
}
