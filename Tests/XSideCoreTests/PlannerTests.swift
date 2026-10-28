import Testing
import Foundation
@testable import XSideCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600

private func device(_ id: String, available: Bool = true) -> Device {
    Device(id: id, udid: nil, name: id, model: "iPhone", kind: .iPhone, transport: .usb,
           isPaired: true, isAvailable: available, developerModeEnabled: true)
}

private func record(_ installs: [Installation], id: UUID = UUID()) -> AppRecord {
    AppRecord(id: id, displayName: "App", originalBundleID: "com.x", signedBundleID: "com.x.t",
              ipaPath: "a.ipa", options: InstallOptions(), installations: installs, teamID: "T")
}

private func inst(_ dev: String = "D1", expiresIn: TimeInterval, lastAttempt: Date? = nil) -> Installation {
    Installation(deviceID: dev, installedAt: now.addingTimeInterval(-hour),
                 expiresAt: now.addingTimeInterval(expiresIn), lastAttempt: lastAttempt)
}

struct PlannerTests {
    @Test func dueWithinTwoDays() {
        let r1 = record([inst(expiresIn: 47 * hour)])
        let r2 = record([inst(expiresIn: 49 * hour)])
        #expect(RefreshPlanner.dueJobs([r1], devices: [device("D1")], now: now)
                == [RefreshJob(recordID: r1.id, deviceID: "D1")])
        #expect(RefreshPlanner.dueJobs([r2], devices: [device("D1")], now: now).isEmpty)
    }

    @Test func requiresAvailableDevice() {
        let r = record([inst(expiresIn: hour)])
        #expect(RefreshPlanner.dueJobs([r], devices: [device("D1", available: false)], now: now).isEmpty)
        #expect(RefreshPlanner.dueJobs([r], devices: [device("other")], now: now).isEmpty)
    }

    @Test func waitsThirtyMinutesBetweenAttempts() {
        let recent = record([inst(expiresIn: hour, lastAttempt: now.addingTimeInterval(-29 * 60))])
        let old = record([inst(expiresIn: hour, lastAttempt: now.addingTimeInterval(-31 * 60))])
        #expect(RefreshPlanner.dueJobs([recent], devices: [device("D1")], now: now).isEmpty)
        #expect(RefreshPlanner.dueJobs([old], devices: [device("D1")], now: now).count == 1)
    }

    @Test func expiredInstallIsStillDue() {
        let r = record([inst(expiresIn: -3 * 86_400)])
        #expect(RefreshPlanner.dueJobs([r], devices: [device("D1")], now: now).count == 1)
    }

    @Test func customThresholdAndOrdering() {
        let a = record([inst(expiresIn: 10 * hour)])
        let b = record([inst(expiresIn: 5 * hour)])
        let jobs = RefreshPlanner.dueJobs([a, b], devices: [device("D1")], now: now)
        #expect(jobs.map(\.recordID) == [b.id, a.id])
        #expect(RefreshPlanner.dueJobs([a], devices: [device("D1")], now: now, threshold: hour).isEmpty)
    }

    @Test func gateNotifiesOncePerCause() throws {
        var gate = NotificationGate()
        let id = UUID()
        let first = gate.shouldNotify(recordID: id, deviceID: "D1", errorKey: "a")
        let same = gate.shouldNotify(recordID: id, deviceID: "D1", errorKey: "a")
        let other = gate.shouldNotify(recordID: id, deviceID: "D1", errorKey: "b")
        #expect(first)
        #expect(!same)
        #expect(other)
        let copy = try JSONDecoder().decode(NotificationGate.self, from: JSONEncoder().encode(gate))
        #expect(copy == gate)
        gate.reset(recordID: id, deviceID: "D1")
        let afterReset = gate.shouldNotify(recordID: id, deviceID: "D1", errorKey: "b")
        #expect(afterReset)
    }

    @Test func debugThresholdOverride() {
        #expect(RefreshPlanner.threshold(debugDays: 0) == RefreshPlanner.threshold)
        #expect(RefreshPlanner.threshold(debugDays: -3) == RefreshPlanner.threshold)
        #expect(RefreshPlanner.threshold(debugDays: 7) == 7 * 86_400)
        // A 7-day override makes a fresh 7-day install due right away.
        let r = record([inst(expiresIn: 7 * 86_400 - hour)])
        #expect(RefreshPlanner.dueJobs([r], devices: [device("D1")], now: now).isEmpty)
        #expect(RefreshPlanner.dueJobs([r], devices: [device("D1")], now: now,
                                       threshold: RefreshPlanner.threshold(debugDays: 7)).count == 1)
    }

    @Test func startableSkipsBusyRows() {
        let a = RefreshJob(recordID: UUID(), deviceID: "D1")
        let b = RefreshJob(recordID: UUID(), deviceID: "D1")
        let c = RefreshJob(recordID: UUID(), deviceID: "D2")
        #expect(RefreshPlanner.startable([a, b, c], busy: [b]) == [a, c])
        #expect(RefreshPlanner.startable([a], busy: []) == [a])
    }

    @Test func gateStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xside-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotificationGateStore(libraryRoot: dir)
        #expect(store.url.lastPathComponent == "notifications.json")
        #expect(store.load() == NotificationGate()) // missing file

        var gate = NotificationGate()
        let id = UUID()
        _ = gate.shouldNotify(recordID: id, deviceID: "D1", errorKey: "deviceUnavailable")
        try store.save(gate)
        var loaded = store.load()
        #expect(loaded == gate)
        let again = loaded.shouldNotify(recordID: id, deviceID: "D1", errorKey: "deviceUnavailable")
        #expect(!again) // survives a relaunch: no second notification

        loaded.reset(recordID: id, deviceID: "D1")
        try store.save(loaded)
        #expect(store.load() == NotificationGate())
    }

    @Test func gateStoreCorruptFileLoadsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xside-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = NotificationGateStore(libraryRoot: dir)
        try Data("not json".utf8).write(to: store.url)
        #expect(store.load() == NotificationGate())
    }

    // MARK: UnreachableTracker

    private let min: TimeInterval = 60

    @Test func unreachableNeedsTwoSightingsFiveMinutesApart() {
        var t = UnreachableTracker()
        let r = record([inst(expiresIn: hour)])
        let job = RefreshJob(recordID: r.id, deviceID: "D1")
        #expect(t.evaluate([r], devices: [], now: now).isEmpty) // first sighting (device missing)
        #expect(t.evaluate([r], devices: [], now: now.addingTimeInterval(4 * min)).isEmpty)
        #expect(t.evaluate([r], devices: [], now: now.addingTimeInterval(5 * min)) == [job])
    }

    @Test func unreachableCountsUnavailableDevices() {
        var t = UnreachableTracker()
        let r = record([inst(expiresIn: -hour)]) // already expired: still reported
        let off = [device("D1", available: false)]
        _ = t.evaluate([r], devices: off, now: now)
        #expect(t.evaluate([r], devices: off, now: now.addingTimeInterval(6 * min))
                == [RefreshJob(recordID: r.id, deviceID: "D1")])
    }

    @Test func unreachableIgnoresNotDueAndAvailable() {
        var t = UnreachableTracker()
        let notDue = record([inst(expiresIn: 3 * 86_400)])
        let due = record([inst(expiresIn: hour)])
        _ = t.evaluate([notDue, due], devices: [device("D1")], now: now)
        #expect(t.evaluate([notDue, due], devices: [device("D1")], now: now.addingTimeInterval(10 * min)).isEmpty)
        _ = t.evaluate([notDue], devices: [], now: now)
        #expect(t.evaluate([notDue], devices: [], now: now.addingTimeInterval(10 * min)).isEmpty)
        // The debug threshold applies too.
        _ = t.evaluate([notDue], devices: [], now: now, threshold: 7 * 86_400)
        #expect(t.evaluate([notDue], devices: [], now: now.addingTimeInterval(10 * min), threshold: 7 * 86_400).count == 1)
    }

    @Test func unreachableRespectsRetryDelay() {
        var t = UnreachableTracker()
        let t2 = now.addingTimeInterval(10 * min)
        let recent = record([inst(expiresIn: hour, lastAttempt: t2.addingTimeInterval(-29 * min))])
        let old = record([inst(expiresIn: hour, lastAttempt: t2.addingTimeInterval(-31 * min))])
        _ = t.evaluate([recent, old], devices: [], now: now)
        #expect(t.evaluate([recent, old], devices: [], now: t2) == [RefreshJob(recordID: old.id, deviceID: "D1")])
    }

    @Test func unreachableClearsWhenDeviceComesBack() {
        var t = UnreachableTracker()
        let r = record([inst(expiresIn: hour)])
        _ = t.evaluate([r], devices: [], now: now)
        _ = t.evaluate([r], devices: [device("D1")], now: now.addingTimeInterval(3 * min)) // back: cleared
        // Unreachable again: needs a fresh 5-min confirmation.
        #expect(t.evaluate([r], devices: [], now: now.addingTimeInterval(6 * min)).isEmpty)
        #expect(t.evaluate([r], devices: [], now: now.addingTimeInterval(11 * min)).count == 1)
    }
}
