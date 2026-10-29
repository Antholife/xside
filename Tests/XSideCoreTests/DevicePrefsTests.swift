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
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

struct DevicePrefsTests {
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
