import Foundation

/// When XSide lists each connected device's crash reports (the quiet look of `CrashWatch`), so a
/// crash is seen within minutes even for an app without the XSide module, or one that stops
/// before its module can say anything:
/// - every `interval` (2 minutes);
/// - every `boostedInterval` (15 s) for `boostDuration` (3 minutes) after XSide installed or
///   opened an app on the device, or heard from one of its apps (a check-in): when a crash is
///   most likely;
/// - never while a job (install, refresh, uninstall) runs on the device, nor while a look runs;
/// - after a look that failed (device locked, out of reach, devicectl busy), the wait doubles at
///   each failure in a row, up to `maxBackoff`; a look that works, or a sign of life (boost),
///   ends it.
/// Only the listing runs this often: files are copied only when a new one of an XSide app shows.
/// Kept in memory (a restart just looks again).
public struct CrashScanSchedule: Sendable, Equatable {
    public static let interval: TimeInterval = 120
    public static let boostedInterval: TimeInterval = 15
    public static let boostDuration: TimeInterval = 180
    public static let maxBackoff: TimeInterval = 30 * 60

    private struct Device: Sendable, Equatable {
        var lastStart: Date?
        var failures = 0
        var boostedUntil: Date?
        var running = false
    }

    private var devices: [String: Device] = [:]

    public init() {}

    /// The wait between two looks at the device now: boosted or not, then backed off.
    public func interval(deviceID: String, now: Date) -> TimeInterval {
        let d = devices[deviceID] ?? Device()
        let boosted = d.boostedUntil.map { now < $0 } ?? false
        let base = boosted ? Self.boostedInterval : Self.interval
        guard d.failures > 0 else { return base }
        // 2^failures, capped well before it could overflow.
        let factor = pow(2, Double(min(d.failures, 16)))
        return min(base * factor, Self.maxBackoff)
    }

    /// A look at the device is due: none running, no job on it (`busy`), and the wait since the
    /// last one is over (or the clock went back).
    public func isDue(deviceID: String, now: Date, busy: Bool) -> Bool {
        guard !busy else { return false }
        let d = devices[deviceID] ?? Device()
        guard !d.running else { return false }
        guard let last = d.lastStart, last <= now else { return true }
        // A second of slack: the engine ticks every 15 s and must not miss a boosted look by jitter.
        return now.timeIntervalSince(last) >= interval(deviceID: deviceID, now: now) - 1
    }

    public mutating func started(deviceID: String, now: Date) {
        devices[deviceID, default: Device()].lastStart = now
        devices[deviceID, default: Device()].running = true
    }

    /// The look ended: `succeeded` (the list was read) ends the back-off, a failure lengthens it.
    public mutating func finished(deviceID: String, succeeded: Bool) {
        guard var d = devices[deviceID] else { return }
        d.running = false
        d.failures = succeeded ? 0 : d.failures + 1
        devices[deviceID] = d
    }

    /// XSide installed or opened an app on the device, or one of its apps checked in: looks every
    /// `boostedInterval` for `boostDuration`, starting with the next tick. The device answers, so
    /// a back-off ends.
    public mutating func boost(deviceID: String, now: Date) {
        var d = devices[deviceID] ?? Device()
        d.boostedUntil = max(d.boostedUntil ?? now, now.addingTimeInterval(Self.boostDuration))
        d.failures = 0
        devices[deviceID] = d
    }

    public func isBoosted(deviceID: String, now: Date) -> Bool {
        devices[deviceID]?.boostedUntil.map { now < $0 } ?? false
    }

    public func failures(deviceID: String) -> Int { devices[deviceID]?.failures ?? 0 }

    /// The device is gone from XSide.
    public mutating func forget(deviceID: String) { devices[deviceID] = nil }
}

/// How a held watch ended, as the server saw it.
public enum WatchClose: Sendable, Equatable {
    /// XSide closed it: its lifetime, a newer watch of the same app, XSide stopping.
    case byMac
    /// The phone closed it, or the connection failed; `farewell`: the one line it wrote on the watch
    /// before (without its "\n"), if any.
    case byPhone(farewell: Data?)
}

extension ChannelHandler {
    /// Longest line read on a held watch (a `bye` request is a few hundred bytes).
    public static let maxFarewellLength = 4 * 1024

    /// A watch that ended abruptly: the app vanished while in front (a crash, or killed while in
    /// use), so the device's crash logs are worth a look at once. Only for a phone that said it
    /// says goodbye (`saysBye`, older dylibs don't), never for a watch XSide closed itself, and not
    /// when the phone wrote a `bye` that authenticates for the same installation (its nonce is
    /// recorded like any request's: a replayed `bye` doesn't count).
    public static func watchEndedAbruptly(_ close: WatchClose, saysBye: Bool, installationID: String, now: Date,
                                          nonces: inout ChannelNonces, secret: Data) -> Bool {
        guard saysBye, case let .byPhone(farewell) = close else { return false }
        guard let farewell else { return true }
        let received = receive(line: farewell, now: now, nonces: &nonces) { $0 == installationID ? secret : nil }
        if case let .request(id, _, .bye) = received, id == installationID { return false }
        return true
    }
}
