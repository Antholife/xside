import Foundation
import IOKit.pwr_mgt
import os
import Security
import XSideWakeProtocol

// Privileged (root) launchd daemon, registered by the app through `SMAppService.daemon`.
// It only schedules/cancels XSide's own wake events, and only for the XSide app that embeds it.

private let logger = Logger(subsystem: WakeHelper.appBundleID, category: "wake")

enum Power {
    /// Owner tag of our power events (shown by `pmset -g sched`), so we never touch other apps' events.
    private static var owner: CFString { WakeHelper.appBundleID as CFString }
    private static var wakeType: CFString { kIOPMAutoWake as CFString }
    /// Sanity bound: refreshes are at most a week away.
    private static let maxLead: TimeInterval = 8 * 24 * 3600

    /// Our scheduled wake dates.
    static func ourWakes() -> [Date] {
        guard let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return events.compactMap { event in
            guard event[kIOPMPowerEventAppNameKey] as? String == WakeHelper.appBundleID,
                  event[kIOPMPowerEventTypeKey] as? String == kIOPMAutoWake else { return nil }
            return event[kIOPMPowerEventTimeKey] as? Date
        }
    }

    static func cancelAll() -> String? {
        for date in ourWakes() {
            let result = IOPMCancelScheduledPowerEvent(date as CFDate, owner, wakeType)
            if result != kIOReturnSuccess { return "cancel failed (\(result))" }
        }
        return nil
    }

    static func schedule(_ date: Date) -> String? {
        let lead = date.timeIntervalSinceNow
        guard lead > 0, lead < maxLead else { return "date out of range" }
        if let error = cancelAll() { return error }
        let result = IOPMSchedulePowerEvent(date as CFDate, owner, wakeType)
        return result == kIOReturnSuccess ? nil : "schedule failed (\(result))"
    }
}

final class WakeService: NSObject, WakeHelperProtocol {
    func scheduleWake(at date: Date, reply: @escaping @Sendable (String?) -> Void) {
        let error = Power.schedule(date)
        logger.notice("scheduleWake(\(date, privacy: .public)) -> \(error ?? "ok", privacy: .public)")
        reply(error)
    }

    func cancelWakes(reply: @escaping @Sendable (String?) -> Void) {
        let error = Power.cancelAll()
        logger.notice("cancelWakes -> \(error ?? "ok", privacy: .public)")
        reply(error)
    }
}

/// Client check: the peer must be the XSide app of the bundle this helper lives in, exactly as
/// signed on disk (identifier + cdhash, and the team when the bundle is team-signed).
enum ClientCheck {
    /// `XSide.app`, from `XSide.app/Contents/MacOS/XSideWakeHelper`.
    static var appURL: URL? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    /// Code requirement pinning the on-disk app, or nil if the bundle is not a valid XSide app.
    static func requirement(for appURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              info[kSecCodeInfoIdentifier as String] as? String == WakeHelper.appBundleID,
              let cdhash = info[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        let hex = cdhash.map { String(format: "%02x", $0) }.joined()
        var requirement = "identifier \"\(WakeHelper.appBundleID)\" and cdhash H\"\(hex)\""
        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
           team.allSatisfy({ $0.isLetter || $0.isNumber }) {
            requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and " + requirement
        }
        return requirement
    }

    /// Path of the running peer (by pid; the requirement set on the connection is what binds it to
    /// the audit token for every message).
    static func path(ofPid pid: pid_t) -> URL? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        var staticCode: SecStaticCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return nil }
        return (url as URL).resolvingSymlinksInPath()
    }
}

/// Exits when idle; launchd relaunches the daemon on the next message.
final class IdleExit: @unchecked Sendable {
    private let queue = DispatchQueue(label: "idle")
    private var active = 0
    private var generation = 0

    func opened() { queue.async { self.active += 1; self.generation += 1 } }

    func closed() {
        queue.async {
            self.active -= 1
            self.armIfIdle()
        }
    }

    /// Arms the idle timer at launch (no connection yet).
    func closedAtLaunch() { queue.async { self.armIfIdle() } }

    private func armIfIdle() {
        guard active <= 0 else { return }
        generation += 1
        let armed = generation
        queue.asyncAfter(deadline: .now() + 20) {
            if self.active <= 0, self.generation == armed { exit(0) }
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let idle = IdleExit()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let appURL = ClientCheck.appURL,
              let requirement = ClientCheck.requirement(for: appURL),
              ClientCheck.path(ofPid: connection.processIdentifier) == appURL.resolvingSymlinksInPath()
        else {
            logger.error("rejected client pid \(connection.processIdentifier)")
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: WakeHelperProtocol.self)
        connection.exportedObject = WakeService()
        let idle = self.idle
        idle.opened()
        connection.invalidationHandler = { idle.closed() }
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: WakeHelper.label)
listener.delegate = delegate
listener.resume()
delegate.idle.closedAtLaunch()
logger.notice("wake helper started")
dispatchMain()
