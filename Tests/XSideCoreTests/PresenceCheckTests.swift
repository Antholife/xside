import Testing
import Foundation
@testable import XSideCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600

private func device(_ id: String, available: Bool = true) -> Device {
    Device(id: id, udid: nil, name: id, model: "iPhone", kind: .iPhone, transport: .usb,
           isPaired: true, isAvailable: available, developerModeEnabled: true)
}

private func record(_ installs: [Installation], signed: String = "com.x.T", id: UUID = UUID()) -> AppRecord {
    AppRecord(id: id, displayName: "App", originalBundleID: "com.x", signedBundleID: signed,
              ipaPath: "a.ipa", options: InstallOptions(), installations: installs, teamID: "T")
}

private func inst(_ dev: String = "D1", installedAgo: TimeInterval = hour, signed: String? = nil,
                  paused: Bool = false) -> Installation {
    Installation(deviceID: dev, installedAt: now.addingTimeInterval(-installedAgo),
                 expiresAt: now.addingTimeInterval(5 * 24 * hour), signedBundleID: signed, refreshPaused: paused)
}

struct PresenceCheckTests {
    @Test func missingAppsAreTheOnesNotListed() {
        let gone = record([inst()], signed: "com.gone.T")
        let here = record([inst()], signed: "com.here.T")
        let missing = PresenceCheck.missing([gone, here], deviceID: "D1", installed: ["com.here.T"], queriedAt: now)
        #expect(missing == [RefreshJob(recordID: gone.id, deviceID: "D1")])
    }

    @Test func usesTheBundleIDTheDeviceWasSignedWith() {
        // The record was reinstalled elsewhere under a new id; this device still has the old one.
        let r = record([inst(signed: "com.old.T")], signed: "com.new.T")
        #expect(PresenceCheck.missing([r], deviceID: "D1", installed: ["com.old.T"], queriedAt: now).isEmpty)
        #expect(PresenceCheck.missing([r], deviceID: "D1", installed: ["com.new.T"], queriedAt: now)
                == [RefreshJob(recordID: r.id, deviceID: "D1")])
    }

    /// Installed while the list was being read: it may not be in it yet.
    @Test func installedAfterTheQueryIsKept() {
        let r = record([inst(installedAgo: -60)])
        #expect(PresenceCheck.missing([r], deviceID: "D1", installed: [], queriedAt: now).isEmpty)
    }

    @Test func otherDevicesAreIgnored() {
        let r = record([inst("D2")])
        #expect(PresenceCheck.missing([r], deviceID: "D1", installed: [], queriedAt: now).isEmpty)
    }

    @Test func pausedAppsGoToo() {
        let r = record([inst(paused: true)])
        #expect(PresenceCheck.missing([r], deviceID: "D1", installed: [], queriedAt: now)
                == [RefreshJob(recordID: r.id, deviceID: "D1")])
    }

    @Test func checksAvailableDevicesWithAppsHourly() {
        let r = record([inst("D1"), inst("D2"), inst("D3")])
        let devices = [device("D1"), device("D2"), device("D3", available: false), device("D4")]
        let last = ["D2": now.addingTimeInterval(-59 * 60)]
        #expect(PresenceCheck.devicesToCheck(devices, records: [r], lastChecked: last, now: now) == ["D1"])
        let later = ["D1": now.addingTimeInterval(-61 * 60), "D2": now.addingTimeInterval(-hour)]
        #expect(PresenceCheck.devicesToCheck(devices, records: [r], lastChecked: later, now: now) == ["D1", "D2"])
    }
}
