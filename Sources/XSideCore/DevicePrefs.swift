import Foundation

/// Per-device settings, stored next to the library (`devices.json`).
public struct DevicePrefs: Codable, Equatable, Sendable {
    /// Only devices whose Wi-Fi refresh was turned off are stored: the default is on.
    private var wifiOff: Set<String> = []

    public init() {}

    public func wifiRefresh(for deviceID: String) -> Bool { !wifiOff.contains(deviceID) }

    public mutating func setWifiRefresh(_ on: Bool, for deviceID: String) {
        if on { wifiOff.remove(deviceID) } else { wifiOff.insert(deviceID) }
    }

    /// Drops everything stored for a device.
    public mutating func forget(_ deviceID: String) { wifiOff.remove(deviceID) }

    /// Reachable now but only over Wi-Fi while Wi-Fi refresh is off: it can't be refreshed until
    /// plugged in over USB.
    public func isWifiBlocked(_ device: Device) -> Bool {
        device.isAvailable && device.transport != .usb && !wifiRefresh(for: device.id)
    }

    /// Whether the background refresh may use this device now.
    public func canRefresh(_ device: Device) -> Bool {
        device.isAvailable && (wifiRefresh(for: device.id) || device.transport == .usb)
    }
}

/// Persists `DevicePrefs` as JSON, written atomically. A missing or unreadable file loads as the
/// defaults (Wi-Fi refresh on everywhere).
public struct DevicePrefsStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public init(libraryRoot: URL) {
        self.init(url: libraryRoot.appendingPathComponent("devices.json"))
    }

    public func load() -> DevicePrefs {
        guard let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(DevicePrefs.self, from: data) else { return DevicePrefs() }
        return prefs
    }

    public func save(_ prefs: DevicePrefs) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(prefs).write(to: url, options: .atomic)
    }
}
