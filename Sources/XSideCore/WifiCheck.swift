import Foundation

/// Decides, from successive snapshots of one device, how the Wi-Fi reachability check after a
/// first USB install is going. Pure: the caller polls the devices and feeds `observe`.
///
/// The user must unplug the cable first. The 60 s window starts when the device stops being
/// reported over USB; if it is not unplugged within 60 s, a gentle nudge is shown (the wait goes on).
public struct WifiCheck: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case waitingForUnplug
        case checking
        case ok
        case failed
    }

    public static let window: TimeInterval = 60

    public let startedAt: Date
    public private(set) var status: Status = .waitingForUnplug
    public private(set) var unpluggedAt: Date?
    private(set) var lastObserved: Date

    public init(startedAt: Date) {
        self.startedAt = startedAt
        lastObserved = startedAt
    }

    /// True while waiting for the cable to come out for longer than the window.
    public var needsNudge: Bool {
        status == .waitingForUnplug && lastObserved.timeIntervalSince(startedAt) >= Self.window
    }

    /// `device` is the checked device in the latest listing (nil when it isn't listed).
    @discardableResult
    public mutating func observe(_ device: Device?, at now: Date) -> Status {
        lastObserved = now
        switch status {
        case .ok, .failed:
            return status
        case .waitingForUnplug, .checking:
            break
        }
        if let device, device.isAvailable, device.transport == .network {
            status = .ok
            return status
        }
        if status == .waitingForUnplug, device?.transport != .usb {
            status = .checking
            unpluggedAt = now
        }
        if status == .checking, let unpluggedAt, now.timeIntervalSince(unpluggedAt) >= Self.window {
            status = .failed
        }
        return status
    }
}
