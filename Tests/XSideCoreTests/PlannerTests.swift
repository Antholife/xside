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

    @Test func nextWakeIsBeforeEarliestThreshold() {
        let r = record([inst(expiresIn: 72 * hour), inst("D2", expiresIn: 100 * hour), inst("D3", expiresIn: hour)])
        let expected = now.addingTimeInterval(72 * hour - 2 * 86_400 - 600)
        #expect(RefreshPlanner.nextWake([r], now: now) == expected)
        #expect(RefreshPlanner.nextWake([record([inst(expiresIn: hour)])], now: now) == nil)
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
}
