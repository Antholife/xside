import Testing
import Foundation
@testable import XSideCore

// MARK: - Fakes

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
private let expiry = Date(timeIntervalSince1970: 1_800_000_000 + 7 * 86400)

private func makeProfile(expires: Date = expiry, udids: [String] = ["UDID-1"]) -> ProvisioningProfile {
    ProvisioningProfile(uuid: "U-\(udids.joined(separator: ","))", teamID: "TEAM123456",
                        bundleID: "com.example.demo.TEAM123456", creationDate: fixedNow, expirationDate: expires,
                        deviceUDIDs: udids, entitlements: Data())
}

/// Tracks how many calls are in flight and the maximum ever observed.
private actor ConcurrencyGauge {
    private(set) var current = 0
    private(set) var maximum = 0
    func enter() { current += 1; maximum = max(maximum, current) }
    func leave() { current -= 1 }
    /// Waits until `count` calls have been in flight at once, or the timeout elapses.
    func rendezvous(_ count: Int, timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while maximum < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor CallLog {
    private(set) var provisionUDIDs: [[String]] = []
    private(set) var resignArgs: [(ipa: URL, workDir: URL, bundleID: String, icon: URL?,
                                   profileURL: URL, profile: ProvisioningProfile)] = []
    private(set) var installs: [(app: URL, deviceID: String)] = []
    func provision(_ udids: [String]) { provisionUDIDs.append(udids) }
    func resign(_ ipa: URL, _ workDir: URL, _ bundleID: String, _ icon: URL?,
                _ profileURL: URL, _ profile: ProvisioningProfile) {
        resignArgs.append((ipa, workDir, bundleID, icon, profileURL, profile))
    }
    func install(_ app: URL, _ id: String) { installs.append((app, id)) }
    var total: Int { provisionUDIDs.count + resignArgs.count + installs.count }
}

/// Returns a profile listing exactly the requested UDIDs. With `dir`, writes a real per-call
/// profile file there (like `Provisioner` does); otherwise returns a path that does not exist.
private struct FakeProvisioner: Provisioning {
    let log: CallLog
    var error: (any Error)?
    var dir: URL?
    func profile(bundleID: String, env: SigningEnvironment,
                 deviceUDIDs: [String]) async throws -> (url: URL, profile: ProvisioningProfile) {
        await log.provision(deviceUDIDs)
        if let error { throw error }
        let profile = makeProfile(udids: deviceUDIDs)
        guard let dir else { return (URL(fileURLWithPath: "/nonexistent/profile.mobileprovision"), profile) }
        let url = dir.appendingPathComponent("\(bundleID)-\(UUID().uuidString).mobileprovision")
        try Data(profile.uuid.utf8).write(to: url)
        return (url, profile)
    }
}

private struct FakeResigner: Resigning {
    let log: CallLog
    func resign(ipa: URL, workDir: URL, bundleID: String, options: InstallOptions, iconURL: URL?,
                profileURL: URL, profile: ProvisioningProfile, identitySHA1: String) async throws -> URL {
        await log.resign(ipa, workDir, bundleID, iconURL, profileURL, profile)
        // Simulate unpacking into the work dir.
        let app = workDir.appendingPathComponent("Payload/Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        return app
    }
}

private struct FakeInstaller: Installing {
    let log: CallLog
    var error: (any Error)?
    var gauge: ConcurrencyGauge?
    var delay: Duration = .zero
    /// When set, each call waits (bounded) until this many calls are in flight together.
    var rendezvous: Int?
    func install(app: URL, deviceID: String) async throws {
        await gauge?.enter()
        if let rendezvous { await gauge?.rendezvous(rendezvous) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        await gauge?.leave()
        await log.install(app, deviceID)
        if let error { throw error }
    }
}

private struct OpaqueError: Error {}

private actor StepLog {
    private(set) var items: [InstallStep] = []
    func add(_ step: InstallStep) { items.append(step) }
}

// MARK: - Helpers

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let env = SigningEnvironment(developerDir: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
                                     identitySHA1: "FAKESHA1", identityName: "Apple Development: Test",
                                     teamID: "TEAM123456")

private func device(_ id: String = "dev-1", udid: String? = "UDID-1") -> Device {
    Device(id: id, udid: udid, name: "Test", model: "iPhone", kind: .iPhone, transport: .usb,
           isPaired: true, isAvailable: true, developerModeEnabled: true)
}

private struct Fixture {
    let tmp: URL
    let library: AppLibrary
    let record: AppRecord
    let workRoot: URL
    let log = CallLog()

    init() async throws {
        tmp = try tempDir()
        library = AppLibrary(root: tmp.appendingPathComponent("lib"))
        let src = tmp.appendingPathComponent("src.ipa")
        try Data("ipa".utf8).write(to: src)
        let info = AppInfo(bundleID: "com.example.demo", name: "Demo", version: "1.0", executable: "Demo")
        record = try await library.importIPA(src, info: info, teamID: "TEAM123456")
        workRoot = tmp.appendingPathComponent("work")
    }

    func pipeline(provisioner: FakeProvisioner? = nil, installer: FakeInstaller? = nil,
                  now: @escaping @Sendable () -> Date = { fixedNow }) -> SideloadPipeline {
        SideloadPipeline(library: library,
                         provisioner: provisioner ?? FakeProvisioner(log: log),
                         resigner: FakeResigner(log: log),
                         installer: installer ?? FakeInstaller(log: log),
                         env: env, workRoot: workRoot, now: now)
    }

    func cleanup() { try? FileManager.default.removeItem(at: tmp) }
}

private func workRootIsEmpty(_ url: URL) -> Bool {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty
}

// MARK: - Tests

struct PipelineTests {
    @Test func successRecordsExpiry() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let result = try await f.pipeline().install(recordID: f.record.id, device: device())

        #expect(result == Installation(deviceID: "dev-1", installedAt: fixedNow, expiresAt: expiry,
                                       lastAttempt: fixedNow, lastErrorKey: nil))
        let stored = try #require(await f.library.records().first?.installations.first)
        #expect(stored.deviceID == "dev-1")
        #expect(stored.expiresAt == expiry)
        #expect(stored.lastErrorKey == nil)
    }

    @Test func reportsStepsInOrder() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let steps = StepLog()
        _ = try await f.pipeline().install(recordID: f.record.id, device: device()) { await steps.add($0) }
        #expect(await steps.items == [.profile, .signing, .installing])
    }

    @Test func stopsReportingAtFailedStep() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let steps = StepLog()
        let failing = FakeProvisioner(log: f.log, error: XSideError.provisioningFailed("x"))
        await #expect(throws: XSideError.self) {
            _ = try await f.pipeline(provisioner: failing).install(recordID: f.record.id, device: device()) {
                await steps.add($0)
            }
        }
        #expect(await steps.items == [.profile])
    }

    @Test func passesExpectedArgumentsToEachStep() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        _ = try await f.pipeline().install(recordID: f.record.id, device: device())

        #expect(await f.log.provisionUDIDs == [["UDID-1"]])
        let resign = try #require(await f.log.resignArgs.first)
        #expect(resign.ipa.standardizedFileURL == f.library.root.appendingPathComponent(f.record.ipaPath).standardizedFileURL)
        #expect(resign.bundleID == f.record.signedBundleID)
        #expect(resign.icon == nil)
        #expect(resign.workDir.deletingLastPathComponent().standardizedFileURL == f.workRoot.standardizedFileURL)
        let install = try #require(await f.log.installs.first)
        #expect(install.deviceID == "dev-1")
        #expect(install.app.path.hasPrefix(resign.workDir.path))
        #expect(workRootIsEmpty(f.workRoot))
    }

    @Test func resolvesIconInsideLibrary() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let icon = f.tmp.appendingPathComponent("icon.png")
        try Data("png".utf8).write(to: icon)
        try await f.library.setOptions(InstallOptions(iconPath: icon.path), for: f.record.id)
        _ = try await f.pipeline().install(recordID: f.record.id, device: device())
        let resign = try #require(await f.log.resignArgs.first)
        let expected = f.library.root.appendingPathComponent("apps/\(f.record.id.uuidString)/icon.png")
        #expect(resign.icon?.standardizedFileURL == expected.standardizedFileURL)
    }

    @Test func failedInstallKeepsPreviousExpiry() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let oldInstalled = Date(timeIntervalSince1970: 1_700_000_000)
        let oldExpiry = Date(timeIntervalSince1970: 1_700_000_000 + 7 * 86400)
        try await f.library.upsert(Installation(deviceID: "dev-1", installedAt: oldInstalled, expiresAt: oldExpiry),
                                   for: f.record.id)
        let pipeline = f.pipeline(installer: FakeInstaller(log: f.log, error: XSideError.deviceUnavailable))

        await #expect(throws: XSideError.deviceUnavailable) {
            try await pipeline.install(recordID: f.record.id, device: device())
        }
        let stored = try #require(await f.library.records().first?.installations.first)
        #expect(stored.installedAt == oldInstalled)
        #expect(stored.expiresAt == oldExpiry)
        #expect(stored.lastAttempt == fixedNow)
        #expect(stored.lastErrorKey == "deviceUnavailable")
        #expect(workRootIsEmpty(f.workRoot))
    }

    @Test func failedProvisioningRecordsErrorKey() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let oldExpiry = Date(timeIntervalSince1970: 1_700_000_000)
        try await f.library.upsert(Installation(deviceID: "dev-1", installedAt: oldExpiry, expiresAt: oldExpiry),
                                   for: f.record.id)
        let pipeline = f.pipeline(provisioner: FakeProvisioner(log: f.log, error: XSideError.appIDLimitReached))
        await #expect(throws: XSideError.appIDLimitReached) {
            try await pipeline.install(recordID: f.record.id, device: device())
        }
        let stored = try #require(await f.library.records().first?.installations.first)
        #expect(stored.expiresAt == oldExpiry)
        #expect(stored.lastErrorKey == "appIDLimitReached")
        #expect(await f.log.installs.isEmpty)
    }

    @Test func nonXSideErrorRecordsUnknownKey() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try await f.library.upsert(Installation(deviceID: "dev-1", installedAt: old, expiresAt: old), for: f.record.id)
        let pipeline = f.pipeline(installer: FakeInstaller(log: f.log, error: OpaqueError()))
        await #expect(throws: OpaqueError.self) {
            try await pipeline.install(recordID: f.record.id, device: device())
        }
        #expect(await f.library.records().first?.installations.first?.lastErrorKey == "unknown")
    }

    @Test func failedFirstInstallRecordsNothing() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let pipeline = f.pipeline(installer: FakeInstaller(log: f.log, error: XSideError.deviceLocked))
        await #expect(throws: XSideError.deviceLocked) {
            try await pipeline.install(recordID: f.record.id, device: device())
        }
        #expect(await f.library.records().first?.installations == [])
        #expect(workRootIsEmpty(f.workRoot))
    }

    @Test func missingUDIDThrowsWithoutRunning() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        await #expect(throws: XSideError.deviceUnavailable) {
            try await f.pipeline().install(recordID: f.record.id, device: device(udid: nil))
        }
        #expect(await f.log.total == 0)
    }

    @Test func missingUDIDOnRefreshRecordsAttempt() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try await f.library.upsert(Installation(deviceID: "dev-1", installedAt: old, expiresAt: old), for: f.record.id)
        await #expect(throws: XSideError.deviceUnavailable) {
            try await f.pipeline().install(recordID: f.record.id, device: device(udid: nil))
        }
        let stored = try #require(await f.library.records().first?.installations.first)
        #expect(stored.lastAttempt == fixedNow) // so the 30-min retry delay applies
        #expect(stored.lastErrorKey == "deviceUnavailable")
        #expect(await f.log.total == 0)
    }

    @Test func unknownRecordThrows() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        await #expect(throws: XSideError.recordNotFound) {
            try await f.pipeline().install(recordID: UUID(), device: device())
        }
        #expect(await f.log.total == 0)
    }

    @Test func rejectsPathsEscapingLibrary() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let state = """
        [{"id":"\(id.uuidString)","displayName":"Evil","originalBundleID":"com.evil","signedBundleID":"com.evil.T",
          "ipaPath":"../outside.ipa","options":{"fileSharing":false,"iPadFullScreen":false,"proMotion":false},
          "installations":[],"teamID":"T"}]
        """
        try Data(state.utf8).write(to: root.appendingPathComponent("state.json"))
        let library = AppLibrary(root: root)
        #expect(await library.records().count == 1)
        let log = CallLog()
        let pipeline = SideloadPipeline(library: library, provisioner: FakeProvisioner(log: log),
                                        resigner: FakeResigner(log: log), installer: FakeInstaller(log: log),
                                        env: env, workRoot: tmp.appendingPathComponent("work"), now: { fixedNow })
        await #expect {
            try await pipeline.install(recordID: id, device: device())
        } throws: { error in
            if case XSideError.invalidIPA = error { return true }
            return false
        }
        #expect(await log.total == 0)
    }

    @Test func serializesPerDevice() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let gauge = ConcurrencyGauge()
        let pipeline = f.pipeline(installer: FakeInstaller(log: f.log, gauge: gauge, delay: .milliseconds(150)))
        let id = f.record.id
        async let a = pipeline.install(recordID: id, device: device())
        async let b = pipeline.install(recordID: id, device: device())
        async let c = pipeline.install(recordID: id, device: device())
        _ = try await (a, b, c)
        #expect(await gauge.maximum == 1)
        #expect(await f.log.installs.count == 3)
    }

    @Test func differentDevicesRunConcurrently() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let gauge = ConcurrencyGauge()
        // Each call waits until both are in flight: passes only if the devices really overlap
        // (otherwise the first call times out alone and the maximum stays 1).
        let pipeline = f.pipeline(installer: FakeInstaller(log: f.log, gauge: gauge, rendezvous: 2))
        let id = f.record.id
        async let a = pipeline.install(recordID: id, device: device("dev-1", udid: "UDID-1"))
        async let b = pipeline.install(recordID: id, device: device("dev-2", udid: "UDID-2"))
        _ = try await (a, b)
        #expect(await gauge.maximum == 2)
        #expect(await f.library.records().first?.installations.count == 2)
    }

    @Test func concurrentDevicesEachEmbedTheirOwnProfile() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let provisionDir = f.tmp.appendingPathComponent("provisioning")
        try FileManager.default.createDirectory(at: provisionDir, withIntermediateDirectories: true)
        let gauge = ConcurrencyGauge()
        let pipeline = f.pipeline(provisioner: FakeProvisioner(log: f.log, dir: provisionDir),
                                  installer: FakeInstaller(log: f.log, gauge: gauge, rendezvous: 2))
        let id = f.record.id
        async let a = pipeline.install(recordID: id, device: device("dev-1", udid: "UDID-1"))
        async let b = pipeline.install(recordID: id, device: device("dev-2", udid: "UDID-2"))
        _ = try await (a, b)

        #expect(await gauge.maximum == 2)
        let resigns = await f.log.resignArgs
        #expect(resigns.count == 2)
        #expect(Set(resigns.map(\.profileURL)).count == 2)
        #expect(Set(resigns.map(\.profile.deviceUDIDs)) == [["UDID-1"], ["UDID-2"]])
        let installs = await f.log.installs
        for r in resigns {
            // The app installed on a device came from the job whose profile lists that device.
            let target = try #require(installs.first { $0.app.path.hasPrefix(r.workDir.path) })
            #expect(r.profile.deviceUDIDs == [target.deviceID == "dev-1" ? "UDID-1" : "UDID-2"])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: provisionDir.path).isEmpty)
        #expect(workRootIsEmpty(f.workRoot))
    }

    @Test func profileFileRemovedAfterFailure() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let provisionDir = f.tmp.appendingPathComponent("provisioning")
        try FileManager.default.createDirectory(at: provisionDir, withIntermediateDirectories: true)
        let pipeline = f.pipeline(provisioner: FakeProvisioner(log: f.log, dir: provisionDir),
                                  installer: FakeInstaller(log: f.log, error: XSideError.deviceLocked))
        await #expect(throws: XSideError.deviceLocked) {
            try await pipeline.install(recordID: f.record.id, device: device())
        }
        #expect(await f.log.resignArgs.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: provisionDir.path).isEmpty)
    }

    @Test func serializationSurvivesFailure() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let gauge = ConcurrencyGauge()
        let pipeline = f.pipeline(installer: FakeInstaller(log: f.log, error: XSideError.deviceLocked,
                                                           gauge: gauge, delay: .milliseconds(100)))
        let id = f.record.id
        async let a: Installation? = try? pipeline.install(recordID: id, device: device())
        async let b: Installation? = try? pipeline.install(recordID: id, device: device())
        let results = await [a, b]
        #expect(results.allSatisfy { $0 == nil })
        #expect(await gauge.maximum == 1)
        #expect(await f.log.installs.count == 2)
    }
}
