import AppKit
import Foundation
import XSideCore

/// `xside`: XSide from the Terminal. `status` reads the library itself (read only); `refresh`
/// and `install` ask XSide, started in the background if needed, which does the work (it alone
/// signs and installs: two programs never sign at once).

setvbuf(stdout, nil, _IOLBF, 0) // line by line, even through a pipe

let usage = """
    Usage: xside <command> [options]

      status [--json]                  Apps, devices and days left
      refresh <app> [--device <name>]  Refresh an app now (name or bundle id, partial is fine)
      refresh --all                    Refresh every app that can be now
      pause [<duration>]               Pause automatic refreshes: 2h, 30m, 1d… (none: until resumed)
      resume                           Resume automatic refreshes
      install <file.ipa>               Open the .ipa in XSide's install window
      open                             Open XSide

      --debug     Talk to XSide-debug instead of XSide
      --version   Print the version
    """

var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func takeFlag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}
@MainActor func takeOption(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("xside: \(message)\n".utf8))
    exit(1)
}

let debug = takeFlag("--debug")
let bundleID = debug ? "io.github.xside.XSide.debug" : "io.github.xside.XSide"
let libraryRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
    let names = UserDefaults(suiteName: bundleID)?.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
    let now = Date()
    struct Row: Encodable {
        let app: String, bundleID: String, device: String, deviceID: String
        let expires: Date, daysLeft: Int, nextRefresh: Date, paused: Bool, lastError: String?
    }
    let rows: [Row] = records.flatMap { record in
        record.installations.map { i in
            Row(app: record.options.displayName ?? record.displayName, bundleID: record.originalBundleID,
                device: names[i.deviceID] ?? i.deviceID, deviceID: i.deviceID, expires: i.expiresAt,
                daysLeft: max(0, Int((i.expiresAt.timeIntervalSince(now) / 86_400).rounded(.up))),
                nextRefresh: i.expiresAt.addingTimeInterval(-RefreshPlanner.threshold),
                paused: i.refreshPaused, lastError: i.lastErrorKey)
        }
    }
    if json {
        struct Status: Encodable { let running: Bool; let apps: [Row] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: (try? encoder.encode(Status(running: isAppRunning, apps: rows))) ?? Data(), as: UTF8.self))
        return
    }
    if !isAppRunning { print("⚠️  XSide isn't running: nothing gets refreshed until it is (xside open).\n") }
    let paused = UserDefaults(suiteName: bundleID)?.double(forKey: "refreshPausedUntil") ?? 0
    if paused > 0, Date(timeIntervalSince1970: paused) > now {
        let until = Date(timeIntervalSince1970: paused)
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
                line += row.paused ? " · paused" : " · next refresh \(max(row.nextRefresh, now).formatted(date))"
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
/// sent again every second until the app, maybe still launching, answers (30 s at most).
@MainActor func ask(_ command: CLIBridge.Command) -> Never {
    launchInBackground()
    guard isAppRunning || NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
        fail("XSide isn't installed")
    }
    let request = CLIBridge.Request(command: command)
    let center = DistributedNotificationCenter.default()
    nonisolated(unsafe) var reply: CLIBridge.Reply?
    let observer = center.addObserver(forName: CLIBridge.replyName(bundleID: bundleID), object: nil, queue: .main) { note in
        if let answer = CLIBridge.Reply(userInfo: note.userInfo), answer.id == request.id { reply = answer }
    }
    let deadline = Date().addingTimeInterval(30)
    var lastSent = Date.distantPast
    while reply == nil, Date() < deadline {
        if Date().timeIntervalSince(lastSent) >= 1 {
            center.postNotificationName(CLIBridge.requestName(bundleID: bundleID), object: nil,
                                        userInfo: request.userInfo, deliverImmediately: true)
            lastSent = Date()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    center.removeObserver(observer)
    guard let reply else { fail("no answer from XSide (is it up to date?)") }
    if reply.ok { print(reply.message); exit(0) }
    fail(reply.message)
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

// MARK: - main

guard let command = arguments.first else { print(usage); exit(0) }
arguments.removeFirst()

switch command {
case "status":
    status(json: takeFlag("--json"))
case "refresh":
    if takeFlag("--all") { ask(.refreshAll) }
    let device = takeOption("--device")
    guard let app = arguments.first else { fail("which app? (xside refresh <app>, or --all)") }
    ask(.refresh(app: app, device: device))
case "pause":
    if let text = arguments.first {
        guard let seconds = CLIBridge.duration(text) else { fail("\(text) isn't a duration (e.g. 2h, 30m, 1d)") }
        ask(.pause(seconds: seconds))
    }
    ask(.pause(seconds: nil))
case "resume":
    ask(.resume)
case "install":
    guard let path = arguments.first else { fail("which .ipa? (xside install <file.ipa>)") }
    let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    guard file.pathExtension.lowercased() == "ipa" else { fail("\(file.lastPathComponent) isn't an .ipa") }
    guard FileManager.default.fileExists(atPath: file.path) else { fail("no such file: \(path)") }
    openApp(with: file)
case "open":
    openApp()
case "help", "-h", "--help":
    print(usage)
default:
    fail("unknown command \(command)\n\(usage)")
}
