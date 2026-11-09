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
    private(set) var facts: [InstallationFacts?] = []
    func fact(_ f: InstallationFacts?) { facts.append(f) }
    private(set) var options: [InstallOptions] = []
    func option(_ o: InstallOptions) { options.append(o) }
    private(set) var uninstalls: [(bundleID: String, deviceID: String)] = []
    /// Install ("install:<device>") and uninstall ("uninstall:<device>") calls, in call order.
    private(set) var deviceCalls: [String] = []
    func install(_ app: URL, _ id: String) { installs.append((app, id)); deviceCalls.append("install:\(id)") }
    func uninstall(_ bundleID: String, _ id: String) { uninstalls.append((bundleID, id)); deviceCalls.append("uninstall:\(id)") }
    var total: Int { provisionUDIDs.count + resignArgs.count + installs.count + uninstalls.count }
}

/// Returns a profile listing exactly the requested UDIDs. With `dir`, writes a real per-call
/// profile file there (like `Provisioner` does); otherwise returns a path that does not exist.
private struct FakeProvisioner: Provisioning {
    let log: CallLog
    var error: (any Error)?
    var dir: URL?
    var gauge: ConcurrencyGauge?
    var delay: Duration = .zero
    /// nil: `expiry` for the first call, one second later for each following call (a renewal).
    var expires: Date?
    func profile(bundleID: String, env: SigningEnvironment,
                 deviceUDIDs: [String]) async throws -> (url: URL, profile: ProvisioningProfile) {
        await gauge?.enter()
        if delay > .zero { try? await Task.sleep(for: delay) }
        await gauge?.leave()
        await log.provision(deviceUDIDs)
        if let error { throw error }
        let calls = await log.provisionUDIDs.count
        let profile = makeProfile(expires: expires ?? expiry.addingTimeInterval(Double(calls - 1)), udids: deviceUDIDs)
        guard let dir else { return (URL(fileURLWithPath: "/nonexistent/profile.mobileprovision"), profile) }
        let url = dir.appendingPathComponent("\(bundleID)-\(UUID().uuidString).mobileprovision")
        try Data(profile.uuid.utf8).write(to: url)
        return (url, profile)
    }
}

private struct FakeResigner: Resigning {
    let log: CallLog
    /// Whether the signed app holds XSide's library (false: its injection failed).
    var libraryAdded = true
    /// Whether the signed app fills an iPhone Duo's screens (false: the Duo patch failed).
    var duoApplied = true
    /// Whether the signed app holds the signed-out iCloud library (false: this build has none).
    var iCloudApplied = true
    /// What the iCloud step says when the library isn't added.
    var iCloudSkip: ICloudOutcome = .failed
    /// Whether the signed app holds the Duo compatibility module.
    var duoModule = false
    func hasDuoLegacyModule(_ app: URL) -> Bool { duoModule }
    func hasXSideLibrary(_ app: URL) -> Bool { libraryAdded }
    func hasDuoCompatibility(_ app: URL) -> Bool { duoApplied }
    func hasICloudSignedOut(_ app: URL) -> Bool { iCloudApplied }
    func resign(ipa: URL, workDir: URL, bundleID: String, options: InstallOptions, iconURL: URL?,
                profileURL: URL, profile: ProvisioningProfile, identitySHA1: String,
                otherBundleIDs: Set<String>, facts: InstallationFacts?,
                onDuo: @Sendable (DuoOutcome?) async -> Void,
                onICloud: @Sendable () async -> Void,
                onICloudSkipped: @Sendable (ICloudOutcome) async -> Void,
                onThinning: @Sendable () async -> Void,
                onSigning: @Sendable () async -> Void) async throws -> URL {
        await log.resign(ipa, workDir, bundleID, iconURL, profileURL, profile)
        await log.fact(facts)
        await log.option(options)
        if options.duoCompatibility == true {
            await onDuo(nil)
            await onDuo(duoApplied ? .added : .failed)
        }
        if options.iCloudSignedOut == true {
            await onICloud()
            if !iCloudApplied { await onICloudSkipped(iCloudSkip) }
        }
        await onSigning()
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
    /// What `isInstalled` answers (nil: unknown, like a failed query).
    var installed: Bool?
    func isInstalled(bundleID: String, deviceID: String) async -> Bool? { installed }
    func install(app: URL, deviceID: String) async throws {
        await gauge?.enter()
        if let rendezvous { await gauge?.rendezvous(rendezvous) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        await gauge?.leave()
        await log.install(app, deviceID)
        if let error { throw error }
    }
    func uninstall(bundleID: String, deviceID: String) async throws {
        await gauge?.enter()
        if let rendezvous { await gauge?.rendezvous(rendezvous) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        await gauge?.leave()
        await log.uninstall(bundleID, deviceID)
        if let error { throw error }
    }
}

private struct OpaqueError: Error {}

/// Its first call times out (a hung xcodebuild); later calls succeed.
private struct FirstCallTimesOut: Provisioning {
    let log: CallLog
    func profile(bundleID: String, env: SigningEnvironment,
                 deviceUDIDs: [String]) async throws -> (url: URL, profile: ProvisioningProfile) {
        await log.provision(deviceUDIDs)
        if await log.provisionUDIDs.count == 1 { throw XSideError.timedOut(tool: "xcodebuild") }
        return (URL(fileURLWithPath: "/nonexistent/profile.mobileprovision"), makeProfile(udids: deviceUDIDs))
    }
}

private actor OutcomeLog {
    private(set) var items: [DuoOutcome] = []
    func add(_ outcome: DuoOutcome) { items.append(outcome) }
}

private actor StepLog {
    private(set) var items: [InstallStep] = []
    func add(_ step: InstallStep) { items.append(step) }
}

private actor TimeLog {
    private(set) var items: [String: Duration] = [:]
    func add(_ key: String, _ t: Duration) { items[key] = t }
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
                  now: @escaping @Sendable () -> Date = { fixedNow },
                  inAppDefaults: (@Sendable (Date) -> InAppSettings)? = nil,
                  withoutFeaturesByDefault: Bool = false, libraryAdded: Bool = true,
                  duoApplied: Bool = true, iCloudApplied: Bool = true,
                  iCloudSkip: ICloudOutcome = .failed, duoModule: Bool = false) -> SideloadPipeline {
        SideloadPipeline(library: library,
                         provisioner: provisioner ?? FakeProvisioner(log: log),
                         resigner: FakeResigner(log: log, libraryAdded: libraryAdded, duoApplied: duoApplied,
                                                iCloudApplied: iCloudApplied, iCloudSkip: iCloudSkip, duoModule: duoModule),
                         installer: installer ?? FakeInstaller(log: log),
                         workRoot: workRoot, now: now,
                         inAppDefaults: inAppDefaults ?? { InAppSettings.defaults(reminder: true, at: $0) },
                         withoutXSideFeaturesByDefault: { withoutFeaturesByDefault })
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
        let result = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)

        #expect(result == Installation(deviceID: "dev-1", installedAt: fixedNow, expiresAt: expiry,
                                       lastAttempt: fixedNow, lastErrorKey: nil,
                                       signedBundleID: "com.example.demo.TEAM123456",
                                       signingIdentitySHA1: "FAKESHA1", teamID: "TEAM123456", appVersion: "1.0",
                                       inApp: InAppSettings.defaults(reminder: true, at: fixedNow),
                                       firstInstalledAt: fixedNow,
                                       lastRefreshOutcome: RefreshOutcome(at: fixedNow, succeeded: true),
                                       channelSecret: result.channelSecret))
        #expect(result.channelSecret?.count == 32)
        let stored = try #require(await f.library.records().first?.installations.first)
        #expect(stored.deviceID == "dev-1")
        #expect(stored.expiresAt == expiry)
        #expect(stored.lastErrorKey == nil)
    }

    @Test func reportsStepsInOrder() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let steps = StepLog()
        _ = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env) { await steps.add($0) }
        #expect(await steps.items == [.profile, .welcome, .signing, .installing])
    }

    @Test func stopsReportingAtFailedStep() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let steps = StepLog()
        let failing = FakeProvisioner(log: f.log, error: XSideError.provisioningFailed("x"))
        await #expect(throws: XSideError.self) {
            _ = try await f.pipeline(provisioner: failing).install(recordID: f.record.id, device: device(), env: env) {
                await steps.add($0)
            }
        }
        #expect(await steps.items == [.profile])
    }

    @Test func passesExpectedArgumentsToEachStep() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        _ = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)

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
        _ = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
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
            try await pipeline.install(recordID: f.record.id, device: device(), env: env)
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
            try await pipeline.install(recordID: f.record.id, device: device(), env: env)
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
            try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        }
        #expect(await f.library.records().first?.installations.first?.lastErrorKey == "unknown")
    }

    @Test func failedFirstInstallRecordsNothing() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let pipeline = f.pipeline(installer: FakeInstaller(log: f.log, error: XSideError.deviceLocked))
        await #expect(throws: XSideError.deviceLocked) {
            try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        }
        #expect(await f.library.records().first?.installations == [])
        #expect(workRootIsEmpty(f.workRoot))
    }

    @Test func missingUDIDThrowsWithoutRunning() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        await #expect(throws: XSideError.deviceUnavailable) {
            try await f.pipeline().install(recordID: f.record.id, device: device(udid: nil), env: env)
        }
        #expect(await f.log.total == 0)
    }

    @Test func missingUDIDOnRefreshRecordsAttempt() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try await f.library.upsert(Installation(deviceID: "dev-1", installedAt: old, expiresAt: old), for: f.record.id)
        await #expect(throws: XSideError.deviceUnavailable) {
            try await f.pipeline().install(recordID: f.record.id, device: device(udid: nil), env: env)
        }
        let stored = try #require(await f.library.records().first?.installations.first)
        #expect(stored.lastAttempt == fixedNow) // so the 30-min retry delay applies
        #expect(stored.lastErrorKey == "deviceUnavailable")
        #expect(await f.log.total == 0)
    }

    @Test func unknownRecordThrows() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        await #expect(throws: XSideError.recordNotFound) {
            try await f.pipeline().install(recordID: UUID(), device: device(), env: env)
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
                                        workRoot: tmp.appendingPathComponent("work"), now: { fixedNow })
        await #expect {
            try await pipeline.install(recordID: id, device: device(), env: env)
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
        async let a = pipeline.install(recordID: id, device: device(), env: env)
        async let b = pipeline.install(recordID: id, device: device(), env: env)
        async let c = pipeline.install(recordID: id, device: device(), env: env)
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
        async let a = pipeline.install(recordID: id, device: device("dev-1", udid: "UDID-1"), env: env)
        async let b = pipeline.install(recordID: id, device: device("dev-2", udid: "UDID-2"), env: env)
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
        async let a = pipeline.install(recordID: id, device: device("dev-1", udid: "UDID-1"), env: env)
        async let b = pipeline.install(recordID: id, device: device("dev-2", udid: "UDID-2"), env: env)
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
            try await pipeline.install(recordID: f.record.id, device: device(), env: env)
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
        async let a: Installation? = try? pipeline.install(recordID: id, device: device(), env: env)
        async let b: Installation? = try? pipeline.install(recordID: id, device: device(), env: env)
        let results = await [a, b]
        #expect(results.allSatisfy { $0 == nil })
        #expect(await gauge.maximum == 1)
        #expect(await f.log.installs.count == 2)
    }

    @Test func provisioningIsSerializedAcrossDevices() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let provisioning = ConcurrencyGauge(), installing = ConcurrencyGauge()
        let pipeline = f.pipeline(
            provisioner: FakeProvisioner(log: f.log, gauge: provisioning, delay: .milliseconds(150)),
            installer: FakeInstaller(log: f.log, gauge: installing, rendezvous: 2))
        let id = f.record.id
        async let a = pipeline.install(recordID: id, device: device("dev-1", udid: "UDID-1"), env: env)
        async let b = pipeline.install(recordID: id, device: device("dev-2", udid: "UDID-2"), env: env)
        _ = try await (a, b)
        #expect(await provisioning.maximum == 1)
        #expect(await installing.maximum == 2) // installs still overlap across devices
        #expect(await f.log.provisionUDIDs.count == 2)
    }

    @Test func profileStepIsReportedOnlyOnceTheLockIsHeld() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let pipeline = f.pipeline(provisioner: FakeProvisioner(log: f.log, delay: .milliseconds(300)))
        let id = f.record.id
        let clock = ContinuousClock()
        let start = clock.now
        let times = TimeLog()
        // B starts only once A holds the lock (A reported .profile): no timing guess.
        let (aHoldsLock, signal) = AsyncStream<Void>.makeStream()
        async let a = pipeline.install(recordID: id, device: device("dev-1", udid: "UDID-1"), env: env) { step in
            if step == .profile {
                await times.add("a", clock.now - start)
                signal.yield(); signal.finish()
            }
        }
        for await _ in aHoldsLock { break }
        async let b = pipeline.install(recordID: id, device: device("dev-2", udid: "UDID-2"), env: env) { step in
            if step == .profile { await times.add("b", clock.now - start) }
        }
        _ = try await (a, b)
        let t = await times.items
        let gap = try #require(t["b"]) - (try #require(t["a"]))
        #expect(gap >= .milliseconds(250)) // B's .profile came after A released the lock
    }

    @Test func refreshWithoutLaterExpiryFails() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let installed = Date(timeIntervalSince1970: 1_799_000_000)
        try await f.library.upsert(Installation(deviceID: "dev-1", installedAt: installed, expiresAt: expiry),
                                   for: f.record.id)
        // Xcode handed back the profile already installed (same expiry).
        let pipeline = f.pipeline(provisioner: FakeProvisioner(log: f.log, expires: expiry))
        await #expect(throws: XSideError.profileNotRenewed) {
            try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        }
        let stored = try #require(await f.library.records().first?.installations.first)
        #expect(stored.expiresAt == expiry)
        #expect(stored.installedAt == installed)
        #expect(stored.lastAttempt == fixedNow)
        #expect(stored.lastErrorKey == "profileNotRenewed")
        #expect(await f.log.resignArgs.isEmpty)
        #expect(await f.log.installs.isEmpty)
        #expect(workRootIsEmpty(f.workRoot))
    }

    @Test func refreshWithEarlierExpiryFails() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        try await f.library.upsert(Installation(deviceID: "dev-1", installedAt: fixedNow,
                                                expiresAt: expiry.addingTimeInterval(60)), for: f.record.id)
        await #expect(throws: XSideError.profileNotRenewed) {
            try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        }
    }

    @Test func refreshWithLaterExpirySucceeds() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        try await f.library.upsert(Installation(deviceID: "dev-1", installedAt: fixedNow,
                                                expiresAt: expiry.addingTimeInterval(-1)), for: f.record.id)
        let result = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        #expect(result.expiresAt == expiry)
        #expect(result.lastErrorKey == nil)
    }

    @Test func refreshOfAnAppDeletedFromTheDeviceForgetsItThere() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        try await f.library.upsert(Installation(deviceID: "dev-1", installedAt: fixedNow,
                                                expiresAt: expiry.addingTimeInterval(-1)), for: f.record.id)
        let pipeline = f.pipeline(installer: FakeInstaller(log: f.log, installed: false))
        await #expect(throws: XSideError.appRemovedFromDevice) {
            _ = try await pipeline.install(recordID: f.record.id, device: device(), env: env, refresh: true)
        }
        #expect(try #require(await f.library.records().first).installations.isEmpty)
        #expect(await f.log.total == 0) // no profile (no App ID spent), nothing reinstalled
    }

    /// The version actually on the device: the custom one when set, else the .ipa's.
    @Test func installRecordsTheAppVersion() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let plain = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        #expect(plain.appVersion == "1.0")
        let g = try await Fixture(); defer { g.cleanup() }
        try await g.library.setOptions(InstallOptions(version: "9.9"), for: g.record.id)
        let custom = try await g.pipeline().install(recordID: g.record.id, device: device(), env: env)
        #expect(custom.appVersion == "9.9")
    }

    @Test func refreshWhenPresenceIsUnknownGoesOn() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        try await f.library.upsert(Installation(deviceID: "dev-1", installedAt: fixedNow,
                                                expiresAt: expiry.addingTimeInterval(-1)), for: f.record.id)
        let pipeline = f.pipeline(installer: FakeInstaller(log: f.log, installed: nil))
        let result = try await pipeline.install(recordID: f.record.id, device: device(), env: env, refresh: true)
        #expect(result.expiresAt == expiry)
    }

    /// Installing again (install window) puts it back on the device: nothing is checked.
    @Test func reinstallDoesNotCheckPresence() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        try await f.library.upsert(Installation(deviceID: "dev-1", installedAt: fixedNow,
                                                expiresAt: expiry.addingTimeInterval(-1)), for: f.record.id)
        let pipeline = f.pipeline(installer: FakeInstaller(log: f.log, installed: false))
        let result = try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        #expect(result.expiresAt == expiry)
    }

    @Test func reinstallingAPausedAppManagesItAgain() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let pipeline = f.pipeline()
        _ = try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        try await f.library.setRefreshPaused(true, recordID: f.record.id, deviceID: "dev-1")
        let result = try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        #expect(!result.refreshPaused)
        #expect(try #require(await f.library.records().first?.installations.first).refreshPaused == false)
    }

    @Test func failedReinstallKeepsThePause() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        try await f.library.upsert(Installation(deviceID: "dev-1", installedAt: fixedNow, expiresAt: expiry,
                                                refreshPaused: true), for: f.record.id)
        // Same expiry: the profile isn't renewed, the install fails.
        await #expect(throws: XSideError.profileNotRenewed) {
            _ = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        }
        #expect(try #require(await f.library.records().first?.installations.first).refreshPaused)
    }

    @Test func refreshKeepsTheBundleIDTheDeviceWasSignedWith() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let pipeline = f.pipeline()
        let original = f.record.signedBundleID
        _ = try await pipeline.install(recordID: f.record.id, device: device("dev-1", udid: "UDID-1"), env: env)
        // Reinstalled on another device with a new custom identifier.
        try await f.library.setOptions(InstallOptions(customBundleID: "com.custom.demo"), for: f.record.id)
        _ = try await pipeline.install(recordID: f.record.id, device: device("dev-2", udid: "UDID-2"), env: env)
        // The first device keeps refreshing the app it has.
        let refreshed = try await pipeline.install(recordID: f.record.id, device: device("dev-1", udid: "UDID-1"),
                                                   env: env, refresh: true)
        #expect(await f.log.resignArgs.map(\.bundleID) == [original, "com.custom.demo", original])
        #expect(refreshed.signedBundleID == original)
        let stored = try #require(await f.library.records().first?.installations)
        #expect(stored.first { $0.deviceID == "dev-2" }?.signedBundleID == "com.custom.demo")
        // An install (not a refresh) on the first device moves it to the record's current identifier.
        _ = try await pipeline.install(recordID: f.record.id, device: device("dev-1", udid: "UDID-1"), env: env)
        #expect(await f.log.resignArgs.last?.bundleID == "com.custom.demo")
    }

    @Test func recordsTheSigningCertificate() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let other = SigningEnvironment(developerDir: env.developerDir, identitySHA1: "NEWSHA1",
                                       identityName: env.identityName, teamID: env.teamID)
        let pipeline = f.pipeline()
        _ = try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        let renewed = try await pipeline.install(recordID: f.record.id, device: device(), env: other, refresh: true)
        #expect(renewed.signingIdentitySHA1 == "NEWSHA1")
        #expect(renewed.teamID == "TEAM123456")
    }

    @Test func timedOutProvisioningReleasesTheLock() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let pipeline = SideloadPipeline(library: f.library, provisioner: FirstCallTimesOut(log: f.log),
                                        resigner: FakeResigner(log: f.log), installer: FakeInstaller(log: f.log),
                                        workRoot: f.workRoot, now: { fixedNow })
        await #expect(throws: XSideError.timedOut(tool: "xcodebuild")) {
            try await pipeline.install(recordID: f.record.id, device: device("dev-1", udid: "UDID-1"), env: env)
        }
        // The next job (another device) gets the provisioning lock.
        _ = try await pipeline.install(recordID: f.record.id, device: device("dev-2", udid: "UDID-2"), env: env)
        #expect(await f.log.installs.map(\.deviceID) == ["dev-2"])
    }

    @Test func newCertificateAcceptsTheSameProfile() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        // Xcode hands back the same still-valid profile each time.
        let pipeline = f.pipeline(provisioner: FakeProvisioner(log: f.log, expires: expiry))
        _ = try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        await #expect(throws: XSideError.profileNotRenewed) {
            try await pipeline.install(recordID: f.record.id, device: device(), env: env, refresh: true)
        }
        let other = SigningEnvironment(developerDir: env.developerDir, identitySHA1: "NEWSHA1",
                                       identityName: env.identityName, teamID: env.teamID)
        let resigned = try await pipeline.install(recordID: f.record.id, device: device(), env: other, refresh: true)
        #expect(resigned.signingIdentitySHA1 == "NEWSHA1")
        #expect(await f.log.resignArgs.count == 2)
    }

    @Test func environmentIsReadWhenTheJobRuns() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let pipeline = f.pipeline()
        let other = SigningEnvironment(developerDir: env.developerDir, identitySHA1: "LATERSHA1",
                                       identityName: env.identityName, teamID: env.teamID)
        let result = try await pipeline.install(recordID: f.record.id, device: device(), environment: { other })
        #expect(result.signingIdentitySHA1 == "LATERSHA1")
    }

    @Test func brokenEnvironmentFailsWithoutRecordingAnAttempt() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let pipeline = f.pipeline()
        _ = try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        let before = try #require(await f.library.records().first?.installations.first)
        await #expect(throws: XSideError.xcodeNotSignedIn) {
            try await pipeline.install(recordID: f.record.id, device: device(),
                                       environment: { throw XSideError.xcodeNotSignedIn }, refresh: true)
        }
        #expect(await f.library.records().first?.installations.first == before)
        #expect(await f.log.provisionUDIDs.count == 1)
    }
}

/// Records the `DEVELOPER_DIR` each step's subprocesses would get.
private actor DirLog {
    private(set) var dirs: [String?] = []
    func add(_ dir: String?) { dirs.append(dir) }
}

private struct DirProvisioner: Provisioning {
    let dirs: DirLog
    func profile(bundleID: String, env: SigningEnvironment,
                 deviceUDIDs: [String]) async throws -> (url: URL, profile: ProvisioningProfile) {
        await dirs.add(CommandEnvironment.overrides["DEVELOPER_DIR"])
        return (URL(fileURLWithPath: "/nonexistent/profile.mobileprovision"), makeProfile(udids: deviceUDIDs))
    }
}

private struct DirInstaller: Installing {
    let dirs: DirLog
    var checks: DirLog?
    func isInstalled(bundleID: String, deviceID: String) async -> Bool? {
        await checks?.add(CommandEnvironment.overrides["DEVELOPER_DIR"])
        return true
    }
    func install(app: URL, deviceID: String) async throws {
        await dirs.add(CommandEnvironment.overrides["DEVELOPER_DIR"])
    }
    func uninstall(bundleID: String, deviceID: String) async throws {
        await dirs.add(CommandEnvironment.overrides["DEVELOPER_DIR"])
    }
}

struct PipelineDeveloperDirTests {
    @Test func runsEveryStepWithTheJobsXcode() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let dirs = DirLog()
        let pipeline = SideloadPipeline(library: f.library, provisioner: DirProvisioner(dirs: dirs),
                                        resigner: FakeResigner(log: f.log), installer: DirInstaller(dirs: dirs),
                                        workRoot: f.workRoot, now: { fixedNow })
        _ = try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        #expect(await dirs.dirs == [env.developerDir.path, env.developerDir.path])
        #expect(CommandEnvironment.overrides["DEVELOPER_DIR"] == nil)
    }

    /// Review I2: the deleted-app check runs devicectl with the job's Xcode too.
    @Test func refreshChecksPresenceWithTheJobsXcode() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        try await f.library.upsert(Installation(deviceID: "dev-1", installedAt: fixedNow,
                                                expiresAt: expiry.addingTimeInterval(-1)), for: f.record.id)
        let dirs = DirLog(), checks = DirLog()
        let pipeline = SideloadPipeline(library: f.library, provisioner: DirProvisioner(dirs: dirs),
                                        resigner: FakeResigner(log: f.log), installer: DirInstaller(dirs: dirs, checks: checks),
                                        workRoot: f.workRoot, now: { fixedNow })
        _ = try await pipeline.install(recordID: f.record.id, device: device(), env: env, refresh: true)
        #expect(await checks.dirs == [env.developerDir.path])
    }

    @Test func uninstallRunsWithTheJobsXcode() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let dirs = DirLog()
        let pipeline = SideloadPipeline(library: f.library, provisioner: DirProvisioner(dirs: dirs),
                                        resigner: FakeResigner(log: f.log), installer: DirInstaller(dirs: dirs),
                                        workRoot: f.workRoot, now: { fixedNow })
        for id in ["dev-1", "dev-2"] {
            try await f.library.upsert(Installation(deviceID: id, installedAt: fixedNow, expiresAt: expiry),
                                       for: f.record.id)
        }
        try await pipeline.uninstall(recordID: f.record.id, deviceID: "dev-1") { env.developerDir }
        // No Xcode known: the runner's own environment applies.
        try await pipeline.uninstall(recordID: f.record.id, deviceID: "dev-2") { nil }
        #expect(await dirs.dirs == [env.developerDir.path, nil])
    }
}

struct PipelineUninstallTests {
    private func installed(_ f: Fixture, _ devices: [String], signedAs bundleID: String? = nil) async throws {
        for id in devices {
            try await f.library.upsert(Installation(deviceID: id, installedAt: fixedNow, expiresAt: expiry,
                                                    signedBundleID: bundleID), for: f.record.id)
        }
    }

    @Test func removesTheAppTheDeviceWasSignedWith() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        try await installed(f, ["dev-1"], signedAs: "com.custom.demo")
        try await installed(f, ["dev-2"])
        try await f.pipeline().uninstall(recordID: f.record.id, deviceID: "dev-1") { nil }

        let calls = await f.log.uninstalls
        #expect(calls.map(\.bundleID) == ["com.custom.demo"])
        #expect(calls.map(\.deviceID) == ["dev-1"])
        let record = try #require(await f.library.records().first)
        #expect(record.installations.map(\.deviceID) == ["dev-2"])
        #expect(await f.log.provisionUDIDs.isEmpty)
    }

    @Test func olderInstallationsUseTheRecordsBundleID() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        try await installed(f, ["dev-1"])
        try await f.pipeline().uninstall(recordID: f.record.id, deviceID: "dev-1") { nil }
        #expect(await f.log.uninstalls.map(\.bundleID) == [f.record.signedBundleID])
        // The record stays, files included: the caller deletes it once nothing uses it.
        let record = try #require(await f.library.records().first)
        #expect(record.installations.isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.library.root.appendingPathComponent(record.ipaPath).path))
    }

    @Test func failureKeepsTheInstallation() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        try await installed(f, ["dev-1"])
        let pipeline = f.pipeline(installer: FakeInstaller(log: f.log, error: XSideError.deviceUnavailable))
        await #expect(throws: XSideError.deviceUnavailable) {
            try await pipeline.uninstall(recordID: f.record.id, deviceID: "dev-1") { nil }
        }
        let stored = try #require(await f.library.records().first?.installations.first)
        #expect(stored == Installation(deviceID: "dev-1", installedAt: fixedNow, expiresAt: expiry))
    }

    @Test func unknownInstallationThrowsWithoutRunning() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        await #expect(throws: XSideError.recordNotFound) {
            try await f.pipeline().uninstall(recordID: f.record.id, deviceID: "dev-1") { nil }
        }
        await #expect(throws: XSideError.recordNotFound) {
            try await f.pipeline().uninstall(recordID: UUID(), deviceID: "dev-1") { nil }
        }
        #expect(await f.log.total == 0)
    }

    @Test func waitsForTheJobRunningOnTheDevice() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let gauge = ConcurrencyGauge()
        let pipeline = f.pipeline(installer: FakeInstaller(log: f.log, gauge: gauge, delay: .milliseconds(150)))
        let id = f.record.id
        async let install = pipeline.install(recordID: id, device: device(), env: env)
        try await Task.sleep(for: .milliseconds(30)) // the install is queued first
        async let uninstall: Void = pipeline.uninstall(recordID: id, deviceID: "dev-1") { nil }
        _ = try await (install, uninstall)
        #expect(await gauge.maximum == 1)
        #expect(await f.log.deviceCalls == ["install:dev-1", "uninstall:dev-1"])
        #expect(try #require(await f.library.records().first).installations.isEmpty)
    }

    @Test func aJobQueuedBehindSeesTheInstallationGone() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        try await installed(f, ["dev-1"])
        let gauge = ConcurrencyGauge()
        let pipeline = f.pipeline(installer: FakeInstaller(log: f.log, gauge: gauge, delay: .milliseconds(150)))
        let id = f.record.id
        async let uninstall: Void = pipeline.uninstall(recordID: id, deviceID: "dev-1") { nil }
        try await Task.sleep(for: .milliseconds(30))
        // Queued behind the uninstall: a fresh install, not a refresh of the removed one.
        async let install = pipeline.install(recordID: id, device: device(), env: env)
        _ = try await (uninstall, install)
        #expect(await gauge.maximum == 1)
        #expect(await f.log.deviceCalls == ["uninstall:dev-1", "install:dev-1"])
        #expect(try #require(await f.library.records().first).installations.map(\.deviceID) == ["dev-1"])
    }

    @Test func otherDevicesAreNotHeldUp() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        try await installed(f, ["dev-2"])
        let gauge = ConcurrencyGauge()
        let pipeline = f.pipeline(installer: FakeInstaller(log: f.log, gauge: gauge, rendezvous: 2))
        let id = f.record.id
        async let install = pipeline.install(recordID: id, device: device("dev-1", udid: "UDID-1"), env: env)
        async let uninstall: Void = pipeline.uninstall(recordID: id, deviceID: "dev-2") { nil }
        _ = try await (install, uninstall)
        #expect(await gauge.maximum == 2)
    }
}

// MARK: - Cancellation

/// Signals when a call starts, then waits until its task is cancelled (like a subprocess killed
/// through `ProcessRunner`'s cancellation handler), or for good when `hangs` is false.
private actor Started {
    private(set) var count = 0
    private(set) var cancelled = 0
    func enter() { count += 1 }
    func cancel() { cancelled += 1 }
    func wait(for n: Int = 1, timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while count < n, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

private struct HangingInstaller: Installing {
    let log: CallLog
    let started: Started
    func install(app: URL, deviceID: String) async throws {
        await started.enter()
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            await started.cancel()
            throw error
        }
        await log.install(app, deviceID)
    }
    func uninstall(bundleID: String, deviceID: String) async throws {}
}

/// Holds the provisioning lock until cancelled.
private struct HangingProvisioner: Provisioning {
    let log: CallLog
    let started: Started
    func profile(bundleID: String, env: SigningEnvironment,
                 deviceUDIDs: [String]) async throws -> (url: URL, profile: ProvisioningProfile) {
        await started.enter()
        await log.provision(deviceUDIDs)
        try await Task.sleep(for: .seconds(30))
        return (URL(fileURLWithPath: "/nonexistent/profile.mobileprovision"), makeProfile(udids: deviceUDIDs))
    }
}

struct PipelineCancellationTests {
    @Test func cancellingTheCallerStopsTheRunningStep() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let started = Started()
        let pipeline = SideloadPipeline(library: f.library, provisioner: FakeProvisioner(log: f.log),
                                        resigner: FakeResigner(log: f.log),
                                        installer: HangingInstaller(log: f.log, started: started),
                                        workRoot: f.workRoot, now: { fixedNow })
        let task = Task { try await pipeline.install(recordID: f.record.id, device: device(), env: env) }
        await started.wait()
        let clock = ContinuousClock(), start = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - start < .seconds(5)) // not the 30 s of the step
        #expect(await started.cancelled == 1)
        #expect(await f.log.installs.isEmpty)
        // A first install that was cancelled records nothing.
        #expect(await f.library.records().first?.installations.isEmpty == true)
        #expect(workRootIsEmpty(f.workRoot))
    }

    @Test func cancelledRefreshLeavesTheInstallationUntouched() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        _ = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        let before = try #require(await f.library.records().first?.installations.first)
        let started = Started()
        let pipeline = SideloadPipeline(library: f.library, provisioner: FakeProvisioner(log: f.log),
                                        resigner: FakeResigner(log: f.log),
                                        installer: HangingInstaller(log: f.log, started: started),
                                        workRoot: f.workRoot, now: { fixedNow.addingTimeInterval(3600) })
        let task = Task {
            try await pipeline.install(recordID: f.record.id, device: device(), env: env, refresh: true)
        }
        await started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let after = try #require(await f.library.records().first?.installations.first)
        #expect(after == before) // no lastAttempt, no lastErrorKey: no retry delay, no error shown
        #expect(after.lastErrorKey == nil)
    }

    @Test func aJobWaitingForTheProvisioningLockLeavesAtOnce() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let started = Started()
        let pipeline = SideloadPipeline(library: f.library,
                                        provisioner: HangingProvisioner(log: f.log, started: started),
                                        resigner: FakeResigner(log: f.log), installer: FakeInstaller(log: f.log),
                                        workRoot: f.workRoot, now: { fixedNow })
        let holder = Task { try await pipeline.install(recordID: f.record.id, device: device("dev-1", udid: "UDID-1"), env: env) }
        await started.wait()
        let steps = StepLog()
        let waiter = Task {
            try await pipeline.install(recordID: f.record.id, device: device("dev-2", udid: "UDID-2"), env: env) { step in
                await steps.add(step)
            }
        }
        try await Task.sleep(for: .milliseconds(50)) // queued behind the holder
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await steps.items.isEmpty) // never got the lock
        #expect(await f.log.provisionUDIDs == [["UDID-1"]])
        // The holder, cancelled too, releases the lock: a new job gets it.
        holder.cancel()
        await #expect(throws: CancellationError.self) { try await holder.value }
        let next = Task { try await pipeline.install(recordID: f.record.id, device: device("dev-3", udid: "UDID-3"), env: env) }
        await started.wait(for: 2)
        #expect(await started.count == 2)
        next.cancel()
        _ = try? await next.value
    }

    @Test func aJobQueuedOnTheDeviceNeverStartsOnceCancelled() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let started = Started()
        let pipeline = SideloadPipeline(library: f.library, provisioner: FakeProvisioner(log: f.log),
                                        resigner: FakeResigner(log: f.log),
                                        installer: HangingInstaller(log: f.log, started: started),
                                        workRoot: f.workRoot, now: { fixedNow })
        let first = Task { try await pipeline.install(recordID: f.record.id, device: device(), env: env) }
        await started.wait()
        let second = Task { try await pipeline.install(recordID: f.record.id, device: device(), env: env) }
        try await Task.sleep(for: .milliseconds(50))
        second.cancel()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(await started.count == 1)
        #expect(await f.log.provisionUDIDs.count == 1)
    }
}

/// Holds an `AsyncLock` until released.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

struct AsyncLockTests {
    /// Runs `body` under the lock in a task; returns once the body holds it.
    private func hold(_ lock: AsyncLock, until gate: Gate, then log: StepLog? = nil) async -> Task<Void, any Error> {
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await lock.run {
                signal.yield(); signal.finish()
                await gate.wait()
                await log?.add(.profile)
            }
        }
        for await _ in entered { break }
        return task
    }

    @Test func aCancelledWaiterLeavesWithoutTheLock() async throws {
        let lock = AsyncLock()
        let gate = Gate()
        let order = StepLog()
        let holder = await hold(lock, until: gate, then: order)
        let cancelled = Task { try await lock.run { await order.add(.signing) } }
        await lock.untilWaiting(1)
        let next = Task { try await lock.run { await order.add(.installing) } }
        await lock.untilWaiting(2)
        cancelled.cancel()
        // Leaves while the holder still has the lock.
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await lock.waiterCount == 1)
        await gate.open()
        try await holder.value
        try await next.value
        #expect(await order.items == [.profile, .installing])
        // Not leaked: free again.
        try await lock.run {}
    }

    @Test func aWaiterCancelledBeforeQueueingNeverRuns() async throws {
        let lock = AsyncLock()
        let gate = Gate()
        let holder = await hold(lock, until: gate)
        let ran = StepLog()
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await lock.run { await ran.add(.profile) }
        }
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await gate.open()
        try await holder.value
        #expect(await ran.items.isEmpty)
        try await lock.run {}
    }

    @Test func aCancelledTaskNeverTakesAFreeLock() async throws {
        let lock = AsyncLock()
        let ran = StepLog()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await lock.run { await ran.add(.profile) }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await ran.items.isEmpty)
        try await lock.run {} // still free
    }

    @Test func aThrowingBodyHandsTheLockOn() async throws {
        let lock = AsyncLock()
        await #expect(throws: CancellationError.self) {
            try await lock.run { throw CancellationError() }
        }
        try await lock.run {}
        #expect(await lock.waiterCount == 0)
    }
}

/// Its first call signals and waits for `gate`; later calls install at once.
private struct GatedInstaller: Installing {
    let log: CallLog
    let gate: Gate
    let entered: AsyncStream<Void>.Continuation
    func install(app: URL, deviceID: String) async throws {
        if await log.installs.isEmpty, await log.provisionUDIDs.count == 1 {
            entered.yield()
            await gate.wait()
        }
        await log.install(app, deviceID)
    }
    func uninstall(bundleID: String, deviceID: String) async throws {}
}

struct PipelineChainCancellationTests {
    @Test func aCancelledQueuedJobLeavesAtOnceAndTheChainHolds() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let gate = Gate()
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let pipeline = SideloadPipeline(library: f.library, provisioner: FakeProvisioner(log: f.log),
                                        resigner: FakeResigner(log: f.log),
                                        installer: GatedInstaller(log: f.log, gate: gate, entered: signal),
                                        workRoot: f.workRoot, now: { fixedNow })
        let id = f.record.id
        let a = Task { try await pipeline.install(recordID: id, device: device(), env: env) }
        for await _ in entered { break } // A is installing, blocked
        let b = Task { try await pipeline.install(recordID: id, device: device(), env: env) }
        b.cancel()
        // B ends while A still runs (it doesn't wait for A to finish).
        await #expect(throws: CancellationError.self) { try await b.value }
        #expect(await f.log.installs.isEmpty)
        let c = Task { try await pipeline.install(recordID: id, device: device(), env: env) }
        // A broken chain would let C provision now, before A is done. Bounded grace for that.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await f.log.provisionUDIDs.count == 1)
        await gate.open()
        _ = try await a.value
        _ = try await c.value
        #expect(await f.log.provisionUDIDs.count == 2) // A and C; B never ran
        #expect(await f.log.installs.count == 2)
    }
}

// MARK: - XSide in the app (Task 4)

@Suite struct PipelineChannelTests {
    @Test func secretRotatesAtEachSigning() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let pipeline = f.pipeline()
        let first = try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        let second = try await pipeline.install(recordID: f.record.id, device: device(), env: env, refresh: true)
        let a = try #require(first.channelSecret), b = try #require(second.channelSecret)
        #expect(a.count == 32 && b.count == 32 && a != b)
        // What was written into the app is what XSide keeps.
        let facts = await f.log.facts.compactMap { $0 }
        #expect(facts.map(\.channelSecret) == [a, b])
        #expect(facts.allSatisfy { $0.installationID == ChannelEnvelope.installationID(recordID: f.record.id, deviceID: "dev-1") })
        #expect(try #require(await f.library.records().first?.installations.first).channelSecret == b)
    }

    /// The app still on the device holds the previous secret.
    @Test func failedSigningKeepsThePreviousSecret() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let first = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        let failing = f.pipeline(installer: FakeInstaller(log: f.log, error: XSideError.deviceUnavailable))
        await #expect(throws: XSideError.self) {
            _ = try await failing.install(recordID: f.record.id, device: device(), env: env, refresh: true)
        }
        let stored = try #require(await f.library.records().first?.installations.first)
        #expect(stored.channelSecret == first.channelSecret)
        #expect(stored.lastRefreshOutcome == RefreshOutcome(at: fixedNow, succeeded: false,
                                                            reasonKey: XSideError.deviceUnavailable.key))
    }

    @Test func firstInstallDateIsKeptAndSettingsSeeded() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let later = fixedNow.addingTimeInterval(86_400)
        let clock = TestClock(fixedNow)
        let pipeline = f.pipeline(now: { clock.now }, inAppDefaults: { InAppSettings.defaults(reminder: false, at: $0) })
        let first = try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        #expect(first.firstInstalledAt == fixedNow)
        #expect(first.inApp == InAppSettings.defaults(reminder: false, at: fixedNow))
        clock.now = later
        let second = try await pipeline.install(recordID: f.record.id, device: device(), env: env, refresh: true)
        #expect(second.firstInstalledAt == fixedNow)
        #expect(second.inApp == first.inApp) // kept, not reseeded
        let facts = try #require(await f.log.facts.last ?? nil)
        #expect(facts.firstInstalledAt == fixedNow && facts.appVersion == "1.0")
        #expect(facts.inApp == first.inApp)
        #expect(facts.lastRefreshOutcome == RefreshOutcome(at: later, succeeded: true))
    }

    /// Installed by an older XSide: no settings, no first-install date.
    @Test func olderInstallationsGetTheirSettingsAtSigning() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let old = fixedNow.addingTimeInterval(-3 * 86_400)
        try await f.library.upsert(Installation(deviceID: "dev-1", installedAt: old, expiresAt: expiry.addingTimeInterval(-1)),
                                   for: f.record.id)
        let result = try await f.pipeline(inAppDefaults: { InAppSettings.defaults(reminder: false, at: $0) })
            .install(recordID: f.record.id, device: device(), env: env, refresh: true)
        #expect(result.inApp == InAppSettings.defaults(reminder: false, at: fixedNow))
        #expect(result.firstInstalledAt == old) // the earliest date XSide knows it was there
    }

    /// The install window's settings: only the fields touched in step 3 are adopted by an
    /// existing installation, stamped and recorded as a Mac edit.
    @Test func installWindowSettingsAreAdopted() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let clock = TestClock(fixedNow)
        let pipeline = f.pipeline(now: { clock.now })
        let first = try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        #expect(first.lastMacEdit == nil) // a first install isn't an edit
        // The phone turned the validity off after the window opened; the user changed the reminder only.
        try await f.library.editInApp(recordID: f.record.id, deviceID: "dev-1", reminder: true,
                                      at: fixedNow.addingTimeInterval(10)) { _ in first.inApp! }
        _ = try await f.library.applyCheckIn(first.inApp!.setting(\.showValidity, to: false,
                                                                   at: fixedNow.addingTimeInterval(20), by: .device),
                                             checkIn: fixedNow.addingTimeInterval(20), outcome: nil,
                                             recordID: f.record.id, deviceID: "dev-1")
        let later = fixedNow.addingTimeInterval(3600)
        clock.now = later
        let draft = InAppSettings.defaults(reminder: false, at: fixedNow)
        let result = try await pipeline.install(recordID: f.record.id, device: device(), env: env,
                                                inApp: InAppDraft(settings: draft, touched: [.reminder]))
        #expect(result.inApp?.reminder == Field(value: false, changedAt: later, changedBy: .mac))
        #expect(result.inApp?.showValidity.value == false) // the phone's, untouched in the window
        #expect(result.lastMacEdit == later)
        #expect(await f.log.facts.last??.inApp.reminder.value == false)
    }

    /// A device getting the app for the first time takes every value the window showed.
    @Test func newInstallationTakesTheWholeDraft() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let draft = InAppSettings.defaults(reminder: false, at: fixedNow).setting(\.language, to: .en, at: fixedNow, by: .mac)
        let result = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env,
                                                    inApp: InAppDraft(settings: draft, touched: []))
        #expect(result.inApp?.reminder.value == false && result.inApp?.language.value == .en)
        #expect(result.lastMacEdit == nil)
    }

    /// An app that made no choice follows the Mac's default; its own choice wins.
    @Test func featuresChoiceIsResolvedBeforeSigning() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let bare = try await f.pipeline(withoutFeaturesByDefault: true).install(recordID: f.record.id, device: device(), env: env)
        #expect(await f.log.options.last?.withoutXSideFeatures == true)
        #expect(bare.withoutXSideFeatures == true) // the installation knows what it got
        var options = f.record.options
        options.withoutXSideFeatures = false
        try await f.library.setOptions(options, for: f.record.id)
        _ = try await f.pipeline(withoutFeaturesByDefault: true).install(recordID: f.record.id, device: device(), env: env)
        #expect(await f.log.options.last?.withoutXSideFeatures == false)
        _ = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        #expect(await f.log.options.last?.withoutXSideFeatures == false)
    }

    /// Morning review M7: a crash's "Reinstall without XSide features" for one device turns them
    /// off there only; the choice is kept across signings; the other device keeps the app's.
    @Test func featuresOffForOneDeviceOnly() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        _ = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        _ = try await f.pipeline().install(recordID: f.record.id, device: device("dev-2", udid: "U2"), env: env)
        #expect(try await f.library.setWithoutXSideFeaturesHere(true, recordID: f.record.id, deviceID: device().id))
        #expect(try await f.library.setWithoutXSideFeaturesHere(true, recordID: f.record.id, deviceID: device().id) == false)
        let here = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        #expect(await f.log.options.last?.withoutXSideFeatures == true)
        #expect(here.withoutXSideFeaturesHere == true && here.withoutXSideFeatures == true)
        // Kept at the next signing (a refresh).
        let again = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        #expect(await f.log.options.last?.withoutXSideFeatures == true)
        #expect(again.withoutXSideFeaturesHere == true)
        let other = try await f.pipeline().install(recordID: f.record.id, device: device("dev-2", udid: "U2"), env: env)
        #expect(await f.log.options.last?.withoutXSideFeatures == false)
        #expect(other.withoutXSideFeaturesHere == nil)
        // Back to the app's choice.
        #expect(try await f.library.setWithoutXSideFeaturesHere(false, recordID: f.record.id, deviceID: device().id))
        _ = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        #expect(await f.log.options.last?.withoutXSideFeatures == false)
    }

    /// Final review minor 4: features asked for but the library couldn't be added (patch error):
    /// the installation records what the app really got, so the Mac offers nothing it can't reach.
    @Test func libraryNotAddedIsRecordedAsWithoutFeatures() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let result = try await f.pipeline(libraryAdded: false).install(recordID: f.record.id, device: device(), env: env)
        #expect(await f.log.options.last?.withoutXSideFeatures == false)
        #expect(result.withoutXSideFeatures == true)
        let ok = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        #expect(ok.withoutXSideFeatures == nil)
    }

    /// Device feedback 3, E1: XSide's quick actions are static Info.plist items again, so they go
    /// with the module when the app is reinstalled without it; nothing is deleted from the device
    /// first. Options saved with the former opt-in ("deleteFirstWithoutFeatures") still load and
    /// only update the app.
    @Test func goingWithoutFeaturesOnlyUpdatesTheApp() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        _ = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        let options = try JSONDecoder().decode(InstallOptions.self, from: Data(
            #"{"withoutXSideFeatures":true,"deleteFirstWithoutFeatures":true}"#.utf8))
        try await f.library.setOptions(options, for: f.record.id)
        let bare = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env, refresh: true)
        #expect(bare.withoutXSideFeatures == true)
        #expect(await f.log.uninstalls.isEmpty)
        #expect(await f.log.deviceCalls == ["install:dev-1", "install:dev-1"])
    }

    /// Reinstalling clears a pause: the setting the app gets says so.
    @Test func reinstallTurnsAutomaticRefreshBackOn() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let pipeline = f.pipeline()
        _ = try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        try await f.library.setRefreshPaused(true, recordID: f.record.id, deviceID: "dev-1", by: .device,
                                             at: fixedNow.addingTimeInterval(-1))
        let result = try await pipeline.install(recordID: f.record.id, device: device(), env: env)
        #expect(result.inApp?.autoRefresh == Field(value: true, changedAt: fixedNow, changedBy: .mac))
        #expect(!result.refreshPaused && result.pausedBy == nil)
        #expect(await f.log.facts.last??.inApp.autoRefresh.value == true)
    }
}

/// Paused from the phone while it installs, then fails.
private struct PausingInstaller: Installing {
    let library: AppLibrary
    let recordID: UUID
    func install(app: URL, deviceID: String) async throws {
        try await library.setRefreshPaused(true, recordID: recordID, deviceID: deviceID, by: .device, at: fixedNow)
        throw XSideError.deviceUnavailable
    }
    func uninstall(bundleID: String, deviceID: String) async throws {}
}

extension PipelineChannelTests {
    @Test func failureKeepsAPauseMadeDuringTheJob() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let first = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        let pipeline = SideloadPipeline(library: f.library, provisioner: FakeProvisioner(log: f.log),
                                        resigner: FakeResigner(log: f.log),
                                        installer: PausingInstaller(library: f.library, recordID: f.record.id),
                                        workRoot: f.workRoot, now: { fixedNow })
        await #expect(throws: XSideError.self) {
            _ = try await pipeline.install(recordID: f.record.id, device: device(), env: env, refresh: true)
        }
        let stored = try #require(await f.library.records().first?.installations.first)
        #expect(stored.refreshPaused && stored.pausedBy == .device)
        #expect(stored.inApp?.autoRefresh.value == false)
        #expect(stored.channelSecret == first.channelSecret)
        #expect(stored.lastErrorKey == XSideError.deviceUnavailable.key)
    }

    // MARK: Signed-out iCloud

    /// Per device like the Duo option: remembered on the installation, applied at each refresh,
    /// a step of its own between the Duo step and the signature.
    @Test func iCloudSignedOutIsPerDeviceAStepAndKept() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let steps = StepLog()
        let first = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env, iCloudSignedOut: true,
                                                   progress: { await steps.add($0) })
        #expect(await steps.items == [.profile, .welcome, .icloud, .signing, .installing])
        #expect(await f.log.options.last?.iCloudSignedOut == true)
        #expect(first.iCloudSignedOut == true)
        #expect(first.iCloudSignedOutMissing == nil)
        let refreshSteps = StepLog()
        _ = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env, refresh: true,
                                           progress: { await refreshSteps.add($0) })
        #expect(await f.log.options.last?.iCloudSignedOut == true)
        #expect(await refreshSteps.items.contains(.icloud))
        let other = try await f.pipeline().install(recordID: f.record.id, device: device("dev-2", udid: "UDID-2"), env: env)
        #expect(await f.log.options.last?.iCloudSignedOut == false)
        #expect(other.iCloudSignedOut == nil)
        let offSteps = StepLog()
        let off = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env, iCloudSignedOut: false,
                                                 progress: { await offSteps.add($0) })
        #expect(off.iCloudSignedOut == nil)
        #expect(await !offSteps.items.contains(.icloud))
    }

    /// Asked for, but the app went without (no library in this build): installed anyway, said so.
    @Test func aMissingICloudLibraryIsRecorded() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let result = try await f.pipeline(iCloudApplied: false).install(recordID: f.record.id, device: device(), env: env,
                                                                        iCloudSignedOut: true)
        #expect(result.iCloudSignedOut == true)
        #expect(result.iCloudSignedOutMissing == true)
        #expect(result.iCloudSignedOutSkippedForModule == nil)
        // No room beside XSide's module: recorded, so the install and My apps say why.
        let room = try await f.pipeline(iCloudApplied: false, iCloudSkip: .noRoomBesideModule)
            .install(recordID: f.record.id, device: device(), env: env, iCloudSignedOut: true)
        #expect(room.iCloudSignedOutMissing == true && room.iCloudSignedOutSkippedForModule == true)
        let plain = try await f.pipeline(iCloudApplied: false).install(recordID: f.record.id, device: device("dev-2", udid: "U2"),
                                                                       env: env)
        #expect(plain.iCloudSignedOutMissing == nil)
    }

    @Test func libraryTurnsICloudSignedOutOnAndOff() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        _ = try await f.pipeline(iCloudApplied: false).install(recordID: f.record.id, device: device(), env: env,
                                                               iCloudSignedOut: true)
        #expect(try await !f.library.setICloudSignedOut(true, recordID: f.record.id, deviceID: "dev-1")) // already on
        #expect(try await f.library.setICloudSignedOut(false, recordID: f.record.id, deviceID: "dev-1"))
        let stored = try #require(await f.library.records().first?.installations.first)
        #expect(stored.iCloudSignedOut == nil)
        #expect(stored.iCloudSignedOutMissing == nil) // nothing asked, nothing missing
        #expect(try await f.library.setICloudSignedOut(true, recordID: f.record.id, deviceID: "dev-1"))
        #expect(await f.library.records().first?.installations.first?.iCloudSignedOut == true)
        #expect(try await !f.library.setICloudSignedOut(true, recordID: f.record.id, deviceID: "nope"))
    }

    // MARK: iPhone Duo compatibility

    /// Chosen per device in the install window, remembered on the installation and applied again
    /// at each refresh until turned off.
    @Test func duoChoiceIsPerDeviceAndKeptAcrossRefreshes() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let first = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env, duoCompatibility: true)
        #expect(await f.log.options.last?.duoCompatibility == true)
        #expect(first.duoCompatibility == true)
        #expect(first.duoCompatibilityMissing == nil)
        _ = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env, refresh: true)
        #expect(await f.log.options.last?.duoCompatibility == true)
        // Another device of the same app doesn't get it.
        let other = try await f.pipeline().install(recordID: f.record.id, device: device("dev-2", udid: "UDID-2"), env: env)
        #expect(await f.log.options.last?.duoCompatibility == false)
        #expect(other.duoCompatibility == nil)
        // Turned off: the next signing goes without.
        let off = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env, duoCompatibility: false)
        #expect(await f.log.options.last?.duoCompatibility == false)
        #expect(off.duoCompatibility == nil)
    }

    /// The patch failed (or wasn't possible): the app is installed anyway and the installation
    /// says so, for the window and the panel.
    @Test func aMissingDuoPatchIsRecorded() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let result = try await f.pipeline(duoApplied: false).install(recordID: f.record.id, device: device(), env: env,
                                                                     duoCompatibility: true)
        #expect(result.duoCompatibility == true)
        #expect(result.duoCompatibilityMissing == true)
        #expect(!result.hasDuoCompatibility)
        // Morning review M3: what the signed app has, for the crash context and a fix request.
        let module = try await f.pipeline(duoModule: true).install(recordID: f.record.id, device: device(), env: env,
                                                                    duoCompatibility: true)
        #expect(module.hasDuoCompatibility && module.duoLegacyModule == true)
        // Not asked: nothing is missing, whatever the app is.
        let plain = try await f.pipeline(duoApplied: false).install(recordID: f.record.id, device: device("dev-2", udid: "U2"), env: env)
        #expect(plain.duoCompatibilityMissing == nil)
        #expect(plain.onDuo == nil)
        // A Duo is remembered as one, for when it isn't connected.
        let duo = Device(id: "duo", udid: "U3", name: "Duo", model: "iPhone", kind: .iPhone, transport: .usb,
                         isPaired: true, isAvailable: true, developerModeEnabled: true, productType: "iPhone19,4")
        #expect(try await f.pipeline().install(recordID: f.record.id, device: duo, env: env).onDuo == true)
    }

    /// With the option on, the Duo patch is a step of its own, between the module and the
    /// signature, and its outcome is told as soon as it's known (Anthony, duo fix pass).
    @Test func duoIsAStepWithItsOutcome() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let steps = StepLog()
        let outcomes = OutcomeLog()
        _ = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env, duoCompatibility: true,
                                           progress: { await steps.add($0) }, duoOutcome: { await outcomes.add($0) })
        #expect(await steps.items == [.profile, .welcome, .duo, .signing, .installing])
        #expect(await outcomes.items == [.added])
        let failedSteps = StepLog()
        let failed = OutcomeLog()
        _ = try await f.pipeline(duoApplied: false).install(recordID: f.record.id, device: device(), env: env,
                                                            progress: { await failedSteps.add($0) },
                                                            duoOutcome: { await failed.add($0) })
        #expect(await failedSteps.items == [.profile, .welcome, .duo, .signing, .installing]) // kept: still on
        #expect(await failed.items == [.failed])
        // Off: no such step.
        let offSteps = StepLog()
        _ = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env, duoCompatibility: false) {
            await offSteps.add($0)
        }
        #expect(await offSteps.items == [.profile, .welcome, .signing, .installing])
    }

    /// devicectl may leave out the hardware facts (over Wi-Fi): a device known as a Duo stays
    /// one instead of turning into "not recommended" (duo review minor 4).
    @Test func aDuoStaysOneWhenItsModelIsntSaid() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let duo = Device(id: "duo", udid: "U3", name: "Duo", model: "iPhone", kind: .iPhone, transport: .usb,
                         isPaired: true, isAvailable: true, developerModeEnabled: true, productType: "iPhone19,4")
        let anonymous = Device(id: "duo", udid: "U3", name: "Duo", model: "iPhone", kind: .iPhone, transport: .network,
                               isPaired: true, isAvailable: true, developerModeEnabled: true)
        #expect(try await f.pipeline().install(recordID: f.record.id, device: duo, env: env).onDuo == true)
        #expect(try await f.pipeline().install(recordID: f.record.id, device: anonymous, env: env, refresh: true).onDuo == true)
        // Said, and not a Duo: forgotten.
        let other = Device(id: "duo", udid: "U3", name: "Duo", model: "iPhone", kind: .iPhone, transport: .usb,
                           isPaired: true, isAvailable: true, developerModeEnabled: true, productType: "iPhone18,2")
        #expect(try await f.pipeline().install(recordID: f.record.id, device: other, env: env, refresh: true).onDuo == nil)
        #expect(anonymous.isDuo(remembered: true))
        #expect(!anonymous.isDuo(remembered: nil))
        #expect(!other.isDuo(remembered: true))
        #expect(duo.isDuo(remembered: nil))
    }

    @Test func duoChoiceCanBeChangedForTheNextSigning() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        _ = try await f.pipeline().install(recordID: f.record.id, device: device(), env: env)
        #expect(try await f.library.setDuoCompatibility(true, recordID: f.record.id, deviceID: "dev-1"))
        #expect(await f.library.records().first?.installations.first?.duoCompatibility == true)
        #expect(try await !f.library.setDuoCompatibility(true, recordID: f.record.id, deviceID: "dev-1")) // unchanged
        #expect(try await !f.library.setDuoCompatibility(true, recordID: f.record.id, deviceID: "nope"))
        #expect(try await f.library.setDuoCompatibility(false, recordID: f.record.id, deviceID: "dev-1"))
        #expect(await f.library.records().first?.installations.first?.duoCompatibility == nil)
        // A choice whose last signing went without it can be cleared, and the note goes with it
        // (duo review minor 2: whatever the current .ipa allows).
        _ = try await f.pipeline(duoApplied: false).install(recordID: f.record.id, device: device(), env: env,
                                                            duoCompatibility: true)
        #expect(await f.library.records().first?.installations.first?.duoCompatibilityMissing == true)
        #expect(try await f.library.setDuoCompatibility(false, recordID: f.record.id, deviceID: "dev-1"))
        #expect(await f.library.records().first?.installations.first?.duoCompatibilityMissing == nil)
    }

    /// Saved before the option existed: decodes without it.
    @Test func installationsWithoutDuoFieldsDecode() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(Installation.self, from: Data(
            #"{"deviceID":"d","installedAt":"2026-01-01T00:00:00Z","expiresAt":"2026-01-08T00:00:00Z"}"#.utf8))
        #expect(old.duoCompatibility == nil && old.duoCompatibilityMissing == nil && old.onDuo == nil)
    }

    /// The app's Duo facts are kept with its record from the import on.
    @Test func importKeepsTheDuoFacts() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let duo = DuoAppInfo(sdkVersion: "26.4", adoptsScenes: false, sceneDelegateClass: "YTSceneDelegate")
        let src = f.tmp.appendingPathComponent("again.ipa")
        try Data("ipa".utf8).write(to: src)
        let info = AppInfo(bundleID: "com.example.demo", name: "Demo", version: "1.1", executable: "Demo", duo: duo)
        let record = try await f.library.importIPA(src, info: info, teamID: "TEAM123456")
        #expect(record.duo == duo)
        #expect(AppLibrary.readRecords(root: f.library.root)?.first?.duo == duo)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
