import Foundation
import os
import ServiceManagement
import Observation
import XSideCore
import XSideWakeProtocol

/// "Wake Mac to refresh" (off by default). Turning it on registers the privileged helper, which
/// macOS only runs once the user allows it in System Settings (and may ask again after an update,
/// since the ad-hoc signature changes). While it isn't allowed, no wake is scheduled. When allowed,
/// a single wake is kept at `RefreshPlanner.nextWake`; turning it off cancels it and unregisters.
@MainActor @Observable
final class WakeController {
    static let shared = WakeController()
    private static let enabledKey = "wakeMacEnabled"
    private static let approvedOnceKey = "wakeMacApprovedOnce"
    private let defaults = UserDefaults.standard

    /// The user's choice (the toggle).
    private(set) var isOn: Bool
    private(set) var status: SMAppService.Status
    private(set) var failed = false
    /// Was allowed before: a new approval request then comes from an update.
    private(set) var approvedOnce: Bool

    private var records: [AppRecord] = []
    private var threshold = RefreshPlanner.threshold
    /// The wake the helper holds (as far as this launch knows); nil = none / unknown.
    private var scheduled: Date?
    private var registerRetried = false

    private init() {
        isOn = defaults.bool(forKey: Self.enabledKey)
        approvedOnce = defaults.bool(forKey: Self.approvedOnceKey)
        status = WakeHelperClient.service.status
    }

    /// On, but macOS hasn't allowed the helper (yet, or again).
    var needsApproval: Bool { isOn && status != .enabled }

    func set(_ on: Bool) {
        failed = false
        if on {
            isOn = true
            defaults.set(true, forKey: Self.enabledKey)
            register()
            sync()
        } else {
            isOn = false
            defaults.set(false, forKey: Self.enabledKey)
            Task { await disable() }
        }
    }

    /// Re-reads the registration status; called by the settings (live) and the engine.
    func refreshStatus() {
        let previous = status
        status = WakeHelperClient.service.status
        // Unregistered behind our back (helper removed, app moved): register again once per launch.
        if isOn, status == .notRegistered, !registerRetried {
            registerRetried = true
            register()
        }
        if status == .enabled, !approvedOnce {
            approvedOnce = true
            defaults.set(true, forKey: Self.approvedOnceKey)
        }
        if previous != status {
            WakeHelperClient.logger.notice("helper status \(previous.rawValue) -> \(self.status.rawValue)")
            if status != .enabled { scheduled = nil } // the helper isn't reachable: nothing known
            sync()
        }
    }

    /// Called by the engine after each change of the records.
    func update(records: [AppRecord], threshold: TimeInterval) {
        self.records = records
        self.threshold = threshold
        refreshStatus()
        sync()
    }

    private func register() {
        do {
            try WakeHelperClient.service.register()
        } catch {
            // Pending approval also throws (EPERM): only a status other than that is a failure.
            let status = WakeHelperClient.service.status
            if status != .requiresApproval && status != .enabled {
                WakeHelperClient.logger.error("register failed: \(String(describing: error), privacy: .public)")
                failed = true
            }
        }
        status = WakeHelperClient.service.status
    }

    /// Keeps the helper's single wake at `nextWake`. Never schedules while the helper isn't allowed.
    private func sync() {
        guard isOn, status == .enabled else { return }
        let next = RefreshPlanner.nextWake(records, now: Date(), threshold: threshold)
        guard next != scheduled else { return }
        scheduled = next
        Task {
            do {
                if let next {
                    try await WakeHelperClient.scheduleWake(at: next)
                    WakeHelperClient.logger.notice("wake scheduled at \(next, privacy: .public)")
                } else {
                    try await WakeHelperClient.cancelWakes()
                    WakeHelperClient.logger.notice("no wake needed: cancelled")
                }
            } catch {
                WakeHelperClient.logger.error("wake sync failed: \(String(describing: error), privacy: .public)")
                if scheduled == next { scheduled = nil }
            }
        }
    }

    private func disable() async {
        if WakeHelperClient.service.status == .enabled {
            do { try await WakeHelperClient.cancelWakes() } catch {
                WakeHelperClient.logger.error("cancel failed: \(String(describing: error), privacy: .public)")
            }
        }
        scheduled = nil
        do { try await WakeHelperClient.service.unregister() } catch {
            WakeHelperClient.logger.error("unregister failed: \(String(describing: error), privacy: .public)")
        }
        status = WakeHelperClient.service.status
    }
}

/// App side of the optional scheduled wake: registers the privileged helper daemon and talks to it
/// over XPC.
enum WakeHelperClient {
    static let logger = Logger(subsystem: WakeHelper.appBundleID, category: "wake")
    static var service: SMAppService { SMAppService.daemon(plistName: WakeHelper.plistName) }

    enum Failure: Error { case connection(String), helper(String) }

    /// Calls the helper; throws on connection failure or helper-reported error.
    static func call(_ body: @escaping @Sendable (WakeHelperProtocol, @escaping @Sendable (String?) -> Void) -> Void)
        async throws {
        let connection = NSXPCConnection(machServiceName: WakeHelper.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: WakeHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let error: String? = try await withCheckedThrowingContinuation { continuation in
            let gate = OnceGate()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                if gate.claim() { continuation.resume(throwing: Failure.connection(error.localizedDescription)) }
            }
            guard let helper = proxy as? WakeHelperProtocol else {
                if gate.claim() { continuation.resume(throwing: Failure.connection("no proxy")) }
                return
            }
            body(helper) { error in
                if gate.claim() { continuation.resume(returning: error) }
            }
        }
        if let error { throw Failure.helper(error) }
    }

    static func scheduleWake(at date: Date) async throws {
        try await call { helper, reply in helper.scheduleWake(at: date, reply: reply) }
    }

    static func cancelWakes() async throws {
        try await call { helper, reply in helper.cancelWakes(reply: reply) }
    }
}

/// Resumes a continuation exactly once across the XPC reply and error handlers.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

#if DEBUG
/// Debug-only manual test: `XSide.app/Contents/MacOS/XSide --wake-test <register|status|schedule|cancel|unregister>`.
/// Compiled out of release builds.
enum WakeDebug {
    @MainActor static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--wake-test"), index + 1 < args.count else { return }
        let command = args[index + 1]
        let service = WakeHelperClient.service
        func log(_ message: String) {
            WakeHelperClient.logger.notice("wake-test: \(message, privacy: .public)")
            print("wake-test: \(message)")
        }
        Task { @MainActor in
            do {
                switch command {
                case "register":
                    do { try service.register() } catch { log("register error: \(error) / \(error as NSError)") }
                case "unregister":
                    try await service.unregister()
                case "schedule":
                    let date = Date().addingTimeInterval(10 * 60)
                    try await WakeHelperClient.scheduleWake(at: date)
                    log("scheduled \(date)")
                case "cancel":
                    try await WakeHelperClient.cancelWakes()
                    log("cancelled")
                case "controller":
                    // Full setting path: on -> wake from a synthetic record due in ~15 min -> off.
                    let threshold = RefreshPlanner.threshold
                    let expires = Date().addingTimeInterval(threshold + 25 * 60).timeIntervalSinceReferenceDate
                    let json = """
                    {"id":"\(UUID().uuidString)","displayName":"t","originalBundleID":"t","signedBundleID":"t",
                     "ipaPath":"t","teamID":"t","options":{"fileSharing":false,"iPadFullScreen":false,"proMotion":false},
                     "installations":[{"deviceID":"t","installedAt":0,"expiresAt":\(expires)}]}
                    """
                    let record = try JSONDecoder().decode(AppRecord.self, from: Data(json.utf8))
                    let wake = WakeController.shared
                    wake.set(true)
                    wake.update(records: [record], threshold: threshold)
                    log("expected wake \(RefreshPlanner.nextWake([record], now: Date(), threshold: threshold)!)")
                    try await Task.sleep(for: .seconds(3))
                    log(Self.pmsetSched())
                    wake.set(false)
                    try await Task.sleep(for: .seconds(3))
                    log("after off: " + Self.pmsetSched())
                default:
                    break
                }
            } catch {
                log("\(command) error: \(error)")
            }
            log("status = \(service.status.rawValue) (\(String(describing: service.status)))")
            exit(0)
        }
        dispatchMain() // never returns: the app itself is not started
    }

    private static func pmsetSched() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "sched"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(separator: "\n").filter { $0.contains(WakeHelper.appBundleID) }.joined(separator: "; ")
    }
}
#endif
