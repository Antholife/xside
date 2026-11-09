import Testing
import Foundation
@testable import XSideCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600

private func device(_ id: String, _ transport: Transport, available: Bool = true) -> Device {
    Device(id: id, udid: nil, name: id, model: "iPhone", kind: .iPhone, transport: transport,
           isPaired: true, isAvailable: available, developerModeEnabled: true)
}

private func record(_ dev: String = "D1", id: UUID = UUID()) -> AppRecord {
    AppRecord(id: id, displayName: "App", originalBundleID: "com.x", signedBundleID: "com.x.t",
              ipaPath: "a.ipa", options: InstallOptions(),
              installations: [Installation(deviceID: dev, installedAt: now.addingTimeInterval(-hour),
                                           expiresAt: now.addingTimeInterval(hour))],
              teamID: "T")
}

private func tempDir() throws -> URL {
    let d = TestTemp.root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

struct DevicePrefsTests {
    /// A friend's iPhone: XSide still refreshes its apps, without notifying about them.
    @Test func notificationsPerDevice() throws {
        var prefs = DevicePrefs()
        #expect(prefs.notifies("D1"))
        prefs.setNotifies(false, for: "D1")
        #expect(!prefs.notifies("D1"))
        #expect(prefs.notifies("D2"))
        let decoded = try JSONDecoder().decode(DevicePrefs.self, from: JSONEncoder().encode(prefs))
        #expect(!decoded.notifies("D1"))
        prefs.forget("D1")
        #expect(prefs.notifies("D1"))
    }

    /// The default only decides for devices that have no setting of their own yet.
    @Test func newDevicesFollowTheDefault() {
        var prefs = DevicePrefs()
        prefs.setNewDevicesWifi(false, keeping: [])
        #expect(!prefs.newDevicesWifi)
        #expect(!prefs.wifiRefresh(for: "NEW"))
        prefs.setWifiRefresh(true, for: "NEW")
        #expect(prefs.wifiRefresh(for: "NEW"))
    }

    @Test func changingTheDefaultKeepsKnownDevicesAsTheyAre() {
        var prefs = DevicePrefs()
        prefs.setWifiRefresh(false, for: "OFF")
        prefs.setNewDevicesWifi(false, keeping: ["KNOWN", "OFF"])
        #expect(prefs.wifiRefresh(for: "KNOWN")) // was on (the old default): stays on
        #expect(!prefs.wifiRefresh(for: "OFF"))
        #expect(!prefs.wifiRefresh(for: "NEW"))
        prefs.setNewDevicesWifi(true, keeping: ["KNOWN", "OFF", "NEW"])
        #expect(!prefs.wifiRefresh(for: "NEW")) // was off (the default then): stays off
        #expect(prefs.wifiRefresh(for: "OTHER"))
    }

    @Test func forgettingADeviceDropsItsOwnSetting() {
        var prefs = DevicePrefs()
        prefs.setNewDevicesWifi(false, keeping: [])
        prefs.setWifiRefresh(true, for: "D1")
        prefs.forget("D1")
        #expect(!prefs.wifiRefresh(for: "D1"))
    }

    @Test func theDefaultIsSavedAndOlderFilesMeanOn() throws {
        var prefs = DevicePrefs()
        prefs.setNewDevicesWifi(false, keeping: ["A"])
        let decoded = try JSONDecoder().decode(DevicePrefs.self, from: JSONEncoder().encode(prefs))
        #expect(decoded == prefs)
        let old = try JSONDecoder().decode(DevicePrefs.self, from: Data(#"{"wifiOff":["X"],"hidden":[]}"#.utf8))
        #expect(old.newDevicesWifi)
        #expect(!old.wifiRefresh(for: "X"))
    }

    @Test func wifiRefreshDefaultsToTrue() {
        let prefs = DevicePrefs()
        #expect(prefs.wifiRefresh(for: "D1"))
        let r = record()
        #expect(RefreshPlanner.dueJobs([r], devices: [device("D1", .network)], now: now, prefs: prefs).count == 1)
    }

    @Test func wifiOffBlocksWifiOnlyDevice() {
        var prefs = DevicePrefs()
        prefs.setWifiRefresh(false, for: "D1")
        let r = record()
        let wifi = device("D1", .network)
        #expect(prefs.isWifiBlocked(wifi))
        #expect(RefreshPlanner.dueJobs([r], devices: [wifi], now: now, prefs: prefs).isEmpty)
        var t = UnreachableTracker()
        #expect(t.evaluate([r], devices: [wifi], now: now).isEmpty)
        #expect(t.evaluate([r], devices: [wifi], now: now.addingTimeInterval(600)).isEmpty)
    }

    @Test func wifiOffStillRefreshesOverUSB() {
        var prefs = DevicePrefs()
        prefs.setWifiRefresh(false, for: "D1")
        let r = record()
        let usb = device("D1", .usb)
        #expect(!prefs.isWifiBlocked(usb))
        #expect(RefreshPlanner.dueJobs([r], devices: [usb], now: now, prefs: prefs)
                == [RefreshJob(recordID: r.id, deviceID: "D1")])
    }

    @Test func wifiOffDoesNotHideAbsentDevice() {
        var prefs = DevicePrefs()
        prefs.setWifiRefresh(false, for: "D1")
        let r = record()
        var t = UnreachableTracker()
        _ = t.evaluate([r], devices: [], now: now)
        #expect(t.evaluate([r], devices: [], now: now.addingTimeInterval(600)).count == 1)
    }

    @Test func prefsOnlyAffectTheirDevice() {
        var prefs = DevicePrefs()
        prefs.setWifiRefresh(false, for: "D1")
        let r = record("D2")
        #expect(RefreshPlanner.dueJobs([r], devices: [device("D2", .network)], now: now, prefs: prefs).count == 1)
    }

    @Test func storePersistsAtomicallyAndForgets() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = DevicePrefsStore(libraryRoot: tmp)
        #expect(store.load() == DevicePrefs())
        var prefs = DevicePrefs()
        prefs.setWifiRefresh(false, for: "D1")
        try store.save(prefs)
        #expect(store.load() == prefs)
        #expect(!store.load().wifiRefresh(for: "D1"))
        prefs.forget("D1")
        try store.save(prefs)
        #expect(store.load().wifiRefresh(for: "D1"))
        try Data("garbage".utf8).write(to: store.url)
        #expect(store.load() == DevicePrefs())
    }

    @Test func hiddenDevicesPersistAndOldFilesStillLoad() throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let store = DevicePrefsStore(libraryRoot: tmp)
        // Written before `hidden` existed: the Wi-Fi setting is kept.
        try Data(#"{"wifiOff":["D1"]}"#.utf8).write(to: store.url)
        var prefs = store.load()
        #expect(!prefs.wifiRefresh(for: "D1"))
        #expect(!prefs.isHidden("D1"))

        prefs.setHidden(true, "D2")
        prefs.forget("D2") // settings only: still hidden
        try store.save(prefs)
        #expect(store.load().isHidden("D2"))
        prefs.setHidden(false, "D2")
        try store.save(prefs)
        #expect(!store.load().isHidden("D2"))
    }

    @Test func blockedByWifiPrefListsOnlyDueWifiOnlyBlocked() {
        var prefs = DevicePrefs()
        prefs.setWifiRefresh(false, for: "D1")
        prefs.setWifiRefresh(false, for: "D3")
        let due = record("D1"), later = record("D3"), other = record("D2")
        let far = AppRecord(id: later.id, displayName: "App", originalBundleID: "com.x", signedBundleID: "com.x.t",
                            ipaPath: "a.ipa", options: InstallOptions(),
                            installations: [Installation(deviceID: "D3", installedAt: now,
                                                         expiresAt: now.addingTimeInterval(5 * 86_400))], teamID: "T")
        let devices = [device("D1", .network), device("D2", .network), device("D3", .network)]
        #expect(RefreshPlanner.blockedByWifiPref([due, far, other], devices: devices, now: now, prefs: prefs)
                == [RefreshJob(recordID: due.id, deviceID: "D1")])
        // On USB, absent or unavailable: not this case.
        #expect(RefreshPlanner.blockedByWifiPref([due], devices: [device("D1", .usb)], now: now, prefs: prefs).isEmpty)
        #expect(RefreshPlanner.blockedByWifiPref([due], devices: [], now: now, prefs: prefs).isEmpty)
        #expect(RefreshPlanner.blockedByWifiPref([due], devices: [device("D1", .network, available: false)],
                                                 now: now, prefs: prefs).isEmpty)
        // Debug threshold override.
        #expect(RefreshPlanner.blockedByWifiPref([far], devices: devices, now: now, threshold: 6 * 86_400, prefs: prefs).count == 1)
    }

    @Test func gatesForgetADevice() {
        let a = UUID(), b = UUID()
        var gate = NotificationGate()
        let g1 = gate.shouldNotify(recordID: a, deviceID: "D1", errorKey: "k")
        let g2 = gate.shouldNotify(recordID: b, deviceID: "D2", errorKey: "k")
        gate.forgetDevice("D1")
        let g3 = gate.shouldNotify(recordID: a, deviceID: "D1", errorKey: "k")
        let g4 = gate.shouldNotify(recordID: b, deviceID: "D2", errorKey: "k")
        #expect(g1 && g2 && g3 && !g4)

        var ok = SuccessNotificationGate()
        let d = now
        let s1 = ok.shouldNotify(recordID: a, deviceID: "D1", expiresAt: d, wasRefresh: true)
        let s2 = ok.shouldNotify(recordID: b, deviceID: "D2", expiresAt: d, wasRefresh: true)
        ok.forgetDevice("D1")
        let s3 = ok.shouldNotify(recordID: a, deviceID: "D1", expiresAt: d, wasRefresh: true)
        let s4 = ok.shouldNotify(recordID: b, deviceID: "D2", expiresAt: d, wasRefresh: true)
        #expect(s1 && s2 && s3 && !s4)
    }
}
