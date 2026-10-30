import Testing
import Foundation
@testable import XSideCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600

private func device(_ id: String, _ transport: Transport = .usb, available: Bool = true) -> Device {
    Device(id: id, udid: nil, name: id, model: "iPhone", kind: .iPhone, transport: transport,
           isPaired: true, isAvailable: available, developerModeEnabled: true)
}

private func inst(_ dev: String = "D1", expiresIn: TimeInterval, paused: Bool, error: String? = nil,
                  sha1: String? = nil) -> Installation {
    Installation(deviceID: dev, installedAt: now.addingTimeInterval(-hour), expiresAt: now.addingTimeInterval(expiresIn),
                 lastErrorKey: error, signingIdentitySHA1: sha1, refreshPaused: paused)
}

private func record(_ installs: [Installation]) -> AppRecord {
    AppRecord(id: UUID(), displayName: "App", originalBundleID: "com.x", signedBundleID: "com.x.t",
              ipaPath: "a.ipa", options: InstallOptions(), installations: installs, teamID: "T")
}

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// "Stop refreshing" pauses an installation: it stays in the library, nothing plans it any more.
struct PausedRefreshTests {
    @Test func pausedInstallationIsNeverDue() {
        let paused = record([inst(expiresIn: hour, paused: true)])
        let expired = record([inst(expiresIn: -86_400, paused: true)])
        let active = record([inst(expiresIn: hour, paused: false)])
        #expect(RefreshPlanner.dueJobs([paused, expired, active], devices: [device("D1")], now: now)
                == [RefreshJob(recordID: active.id, deviceID: "D1")])
    }

    @Test func certificateChangeDoesNotForcePausedRefreshes() {
        let paused = record([inst(expiresIn: 6 * 86_400, paused: true, sha1: "OLDSHA1")])
        #expect(RefreshPlanner.dueJobs([paused], devices: [device("D1")], now: now, currentIdentitySHA1: "NEWSHA1").isEmpty)
    }

    @Test func pausedOnesPerDevice() {
        // Paused on one device only: the other device's installation is still refreshed.
        let r = record([inst("D1", expiresIn: hour, paused: true), inst("D2", expiresIn: hour, paused: false)])
        #expect(RefreshPlanner.dueJobs([r], devices: [device("D1"), device("D2")], now: now)
                == [RefreshJob(recordID: r.id, deviceID: "D2")])
        #expect(RefreshPlanner.refreshedJobs([r]) == [RefreshJob(recordID: r.id, deviceID: "D2")])
    }

    @Test func pausedInstallationNeedsNoUSB() {
        var prefs = DevicePrefs()
        prefs.setWifiRefresh(false, for: "D1")
        let paused = record([inst(expiresIn: hour, paused: true)])
        let active = record([inst(expiresIn: hour, paused: false)])
        #expect(RefreshPlanner.blockedByWifiPref([paused, active], devices: [device("D1", .network)], now: now, prefs: prefs)
                == [RefreshJob(recordID: active.id, deviceID: "D1")])
    }

    @Test func pausedInstallationIsNeverReportedUnreachable() {
        var tracker = UnreachableTracker()
        let paused = record([inst(expiresIn: hour, paused: true)])
        let active = record([inst(expiresIn: hour, paused: false)])
        _ = tracker.evaluate([paused, active], devices: [], now: now)
        let later = now.addingTimeInterval(UnreachableTracker.confirmDelay + 1)
        #expect(tracker.evaluate([paused, active], devices: [], now: later)
                == [RefreshJob(recordID: active.id, deviceID: "D1")])
    }

    @Test func pausedInstallationsLeaveTheBadgeAndQuitWarningAlone() {
        let expired = record([inst(expiresIn: -60, paused: true)])
        let failing = record([inst(expiresIn: hour, paused: true, error: "deviceLocked")])
        let valid = record([inst(expiresIn: 6 * 86_400, paused: true)])
        #expect(!ExpiryWatch.hasExpired([expired], now: now))
        #expect(!ExpiryWatch.needsAttention([expired, failing], now: now, threshold: RefreshPlanner.threshold))
        #expect(!ExpiryWatch.quitStopsRefreshes([valid], now: now))
        // Not paused: as before.
        #expect(ExpiryWatch.hasExpired([record([inst(expiresIn: -60, paused: false)])], now: now))
        #expect(ExpiryWatch.quitStopsRefreshes([record([inst(expiresIn: 6 * 86_400, paused: false)])], now: now))
    }

    @Test func pausedInstallationsGetNoReminder() {
        let r = record([inst("D1", expiresIn: 5 * 86_400, paused: true)])
        #expect(RefreshPlanner.refreshedJobs([r]).isEmpty)
    }

    // MARK: Library

    @Test func pauseAndResumeKeepTheInstallation() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        let lib = AppLibrary(root: root)
        let src = tmp.appendingPathComponent("src.ipa")
        try Data("ipa".utf8).write(to: src)
        let info = AppInfo(bundleID: "com.example.demo", name: "Demo", version: "1.0", executable: "Demo")
        let rec = try await lib.importIPA(src, info: info, teamID: "TEAM123456")
        let installation = inst("a", expiresIn: 5 * 86_400, paused: false)
        try await lib.upsert(installation, for: rec.id)

        #expect(try await lib.setRefreshPaused(true, recordID: rec.id, deviceID: "a"))
        #expect(try await lib.setRefreshPaused(true, recordID: rec.id, deviceID: "a") == false) // already paused
        var stored = try #require(await AppLibrary(root: root).records().first?.installations.first) // persisted
        #expect(stored.refreshPaused)
        stored.refreshPaused = false
        #expect(stored == installation) // nothing else changed

        #expect(try await lib.setRefreshPaused(false, recordID: rec.id, deviceID: "a"))
        #expect(try #require(await lib.records().first?.installations.first) == installation)
        #expect(try await lib.setRefreshPaused(true, recordID: rec.id, deviceID: "other") == false)
        await #expect(throws: XSideError.recordNotFound) {
            try await lib.setRefreshPaused(true, recordID: UUID(), deviceID: "a")
        }
    }

    @Test func decodesWithoutOrWithABadPausedFlag() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let base = #""deviceID":"D1","installedAt":"2026-01-01T00:00:00Z","expiresAt":"2026-01-08T00:00:00Z""#
        #expect(try decoder.decode(Installation.self, from: Data("{\(base)}".utf8)).refreshPaused == false)
        #expect(try decoder.decode(Installation.self, from: Data("{\(base),\"refreshPaused\":\"yes\"}".utf8)).refreshPaused == false)
        #expect(try decoder.decode(Installation.self, from: Data("{\(base),\"refreshPaused\":true}".utf8)).refreshPaused)
        // Round trip.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let paused = inst(expiresIn: hour, paused: true)
        #expect(try decoder.decode(Installation.self, from: encoder.encode(paused)) == paused)
    }
}
