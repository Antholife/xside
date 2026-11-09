import Testing
import Foundation
@testable import XSideCore

private let date = Date(timeIntervalSince1970: 1_800_000_000)

private func package(_ id: String, name: String, packageID: String, version: String = "1.0",
                     origin: TweakOrigin = .added) -> TweakPackage {
    TweakPackage(id: id, kind: .deb, origin: origin, packageID: packageID, name: name, version: version,
                 binaries: [TweakBinary(path: "Library/MobileSubstrate/DynamicLibraries/\(name).dylib", isEntry: true,
                                        filter: nil, slices: [], linked: [], mentionsJailbreakPaths: false,
                                        imageName: "\(name).dylib")],
                 addedAt: date)
}

private let alpha = package("aaaaaaaaaaaaaaaa", name: "Alpha", packageID: "com.example.alpha", version: "1.2")
private let alpha2 = package("aaaaaaaaaaaaaaa2", name: "Alpha", packageID: "com.example.alpha", version: "1.3")
private let beta = package("bbbbbbbbbbbbbbbb", name: "Beta", packageID: "com.example.beta")

private func installation(_ device: String, uses: [TweakUse], injected: [InjectedTweak]? = nil,
                          results: [String: TweakResult]? = nil, support: [String]? = nil) -> Installation {
    Installation(deviceID: device, installedAt: date, expiresAt: date.addingTimeInterval(7 * 86_400), tweaks: uses,
                 tweakResults: results, injectedTweaks: injected, tweakSupportImages: support)
}

struct TweakCrashTests {
    @Test func historyIsWhatTheLastSigningRecordedElseTheResults() {
        let recorded = installation("d1", uses: [], injected: [InjectedTweak(alpha, conversions: [.hookingLibrary])],
                                    results: [beta.id: .injected(converted: false)])
        // The recorded history wins, even when the pool no longer has that version.
        #expect(recorded.injectedTweakHistory(pool: [alpha2, beta]).map(\.id) == [alpha.id])
        let older = installation("d1", uses: [], results: [alpha.id: .injected(converted: true), beta.id: .skipped(.noRoom)])
        let h = older.injectedTweakHistory(pool: [alpha, beta])
        #expect(h.map(\.id) == [alpha.id] && h.first?.converted == true)
    }

    @Test func historyAndSupportImagesSurviveCoding() throws {
        let i = installation("d1", uses: [TweakUse(id: alpha.id)],
                             injected: [InjectedTweak(alpha, conversions: [.jailbreakPaths, .dependencyAdded("Cephei")])],
                             support: ["XSideTweakSupport.dylib", "Cephei"])
        let back = try JSONDecoder().decode(Installation.self, from: JSONEncoder().encode(i))
        #expect(back == i)
        // A damaged history is dropped, not the installation.
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(i)) as? [String: Any])
        json["injectedTweaks"] = "nope"
        let damaged = try JSONDecoder().decode(Installation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(damaged.injectedTweaks == nil && damaged.deviceID == "d1")
    }

    @Test func contextNamesTheTweaksAndWhatSupportsThem() {
        var c = CrashContext(moduleName: "XSideWelcome.dylib")
        c.addTweaks(of: installation("d1", uses: [], injected: [InjectedTweak(alpha, conversions: nil)], support: ["Cephei"]),
                    pool: [])
        #expect(c.tweakNames == ["Alpha.dylib"])
        #expect(c.tweakIDs == [alpha.id])
        #expect(c.tweakLabels == ["Alpha.dylib": "Alpha 1.2"])
        // Only what the signing recorded: no ElleKit when it added none.
        #expect(c.tweakSupportNames == ["Cephei"])
    }

    @Test func noTweaksNoTweakContext() {
        var c = CrashContext(moduleName: "XSideWelcome.dylib")
        c.addTweaks(of: installation("d1", uses: []), pool: [alpha])
        #expect(c.tweakNames.isEmpty && c.tweakIDs.isEmpty && c.tweakSupportNames.isEmpty)
    }

    @Test func olderStateWithAConvertedTweakStillKnowsElleKitAndTheSupport() {
        var c = CrashContext(moduleName: "XSideWelcome.dylib")
        c.addTweaks(of: installation("d1", uses: [], results: [alpha.id: .injected(converted: true)]), pool: [alpha])
        #expect(c.tweakSupportNames == [TweakLayout.elleKitName, TweakLayout.supportName])
        var plain = CrashContext(moduleName: "XSideWelcome.dylib")
        plain.addTweaks(of: installation("d1", uses: [], results: [alpha.id: .injected(converted: false)]), pool: [alpha])
        #expect(plain.tweakSupportNames.isEmpty)
    }

    @Test func theActionIsOfferedOnlyWhenItWouldChangeSomething() {
        let crashed = installation("d1", uses: [TweakUse(id: alpha.id, enabled: false)],
                                   injected: [InjectedTweak(alpha, conversions: [.hookingLibrary])])
        var record = AppRecord(id: UUID(), displayName: "Demo", originalBundleID: "com.example.demo",
                               signedBundleID: "com.example.demo.T", ipaPath: "x.ipa", options: InstallOptions(),
                               installations: [crashed], teamID: "T")
        record.tweaks = [alpha]
        let d = CrashDiagnosis(cause: .tweak, subject: "Alpha.dylib")
        #expect(TweakCrashFix.action(for: d, crashed: crashed, record: record) == nil)
        record.installations[0].tweaks = [TweakUse(id: alpha.id)]
        #expect(TweakCrashFix.action(for: d, crashed: record.installations[0], record: record) == .disableTweak)
        // Other causes are left to CrashAction.suggested.
        #expect(TweakCrashFix.action(for: CrashDiagnosis(cause: .codeSignature), crashed: crashed, record: record) == .refresh)
        #expect(TweakCrashFix.action(for: CrashDiagnosis(cause: .tweak), crashed: crashed, record: record) == nil)
    }

    @Test func disableThisTweakKeepsItListedAndFindsTheReplacedVersion() {
        let crashed = installation("d1", uses: [TweakUse(id: alpha2.id), TweakUse(id: beta.id)],
                                   injected: [InjectedTweak(alpha, conversions: nil), InjectedTweak(beta, conversions: nil)])
        // Alpha 1.2 crashed; the person replaced it with 1.3 since: the device's list has 1.3.
        let uses = TweakCrashFix.disablingTweak(image: "Alpha.dylib", crashed: crashed, in: crashed, pool: [alpha2, beta])
        #expect(uses == [TweakUse(id: alpha2.id, enabled: false), TweakUse(id: beta.id)])
        // Already off, or an image that isn't a tweak: nothing to do.
        let off = installation("d1", uses: [TweakUse(id: alpha2.id, enabled: false)], injected: crashed.injectedTweaks)
        #expect(TweakCrashFix.disablingTweak(image: "Alpha.dylib", crashed: off, in: off, pool: [alpha2]) == nil)
        #expect(TweakCrashFix.disablingTweak(image: "UIKitCore", crashed: crashed, in: crashed, pool: [alpha2, beta]) == nil)
    }

    @Test func disableTheConvertedTweaksOnly() {
        let crashed = installation("d1", uses: [TweakUse(id: alpha.id, force: true), TweakUse(id: beta.id)],
                                   injected: [InjectedTweak(alpha, conversions: [.hookingLibrary]),
                                              InjectedTweak(beta, conversions: nil)])
        #expect(TweakCrashFix.disablingConverted(crashed: crashed, in: crashed, pool: [alpha, beta])
                == [TweakUse(id: alpha.id, enabled: false, force: true), TweakUse(id: beta.id)])
        let none = installation("d1", uses: [TweakUse(id: beta.id)], injected: [InjectedTweak(beta, conversions: nil)])
        #expect(TweakCrashFix.disablingConverted(crashed: none, in: none, pool: [beta]) == nil)
    }

    @Test func theScopeIsAskedOnlyWhenAnotherDeviceHasTheTweak() {
        let crashed = installation("d1", uses: [TweakUse(id: alpha.id)], injected: [InjectedTweak(alpha, conversions: [.jailbreakPaths])])
        let other = installation("d2", uses: [TweakUse(id: alpha.id)])
        let without = installation("d3", uses: [TweakUse(id: beta.id)])
        var record = AppRecord(id: UUID(), displayName: "Demo", originalBundleID: "com.example.demo",
                               signedBundleID: "com.example.demo.T", ipaPath: "x.ipa", options: InstallOptions(),
                               installations: [crashed, other, without], teamID: "T")
        record.tweaks = [alpha, beta]
        #expect(TweakCrashFix.affected(.disableTweak, subject: "Alpha.dylib", crashed: crashed, record: record)
            .map(\.deviceID) == ["d1", "d2"])
        #expect(TweakCrashFix.affected(.disableConvertedTweaks, subject: nil, crashed: crashed, record: record)
            .map(\.deviceID) == ["d1", "d2"])
        #expect(TweakCrashFix.affected(.refresh, subject: nil, crashed: crashed, record: record).isEmpty)
    }

    @Test func reportLinesAndSummary() {
        let hostile = InjectedTweak(id: "x", name: "Evil\n\u{7}Name" + String(repeating: "z", count: 200), packageID: "p",
                                    version: "2", imageNames: [], conversions: [])
        let line = TweakCrashFix.reportLine(hostile)
        #expect(!line.contains("\n") && !line.contains("\u{7}") && line.count < 120 && line.hasSuffix("(converted)"))
        #expect(TweakCrashFix.reportLine(InjectedTweak(alpha, conversions: [.dependency("AltList")]))
                == "Alpha 1.2 (converted: dependency: AltList)")
        let i = installation("d1", uses: [], injected: [InjectedTweak(alpha, conversions: [.hookingLibrary]),
                                                        InjectedTweak(beta, conversions: nil)])
        #expect(TweakCrashFix.summary(i, pool: []) == "2 tweaks (1 converted)")
        #expect(TweakCrashFix.summary(installation("d1", uses: []), pool: []) == nil)
    }
}

private func tempDir() throws -> URL {
    let d = TestTemp.root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

struct TweakCrashLibraryTests {
    private func setUp(_ tmp: URL) async throws -> (AppLibrary, AppRecord, TweakPackage, TweakPackage) {
        let lib = AppLibrary(root: tmp.appendingPathComponent("lib"))
        let ipa = tmp.appendingPathComponent("src.ipa")
        try Data("ipa".utf8).write(to: ipa)
        let rec = try await lib.importIPA(ipa, info: AppInfo(bundleID: "com.example.demo", name: "Demo", version: "1.0",
                                                             executable: "Demo"), teamID: "TEAM123456")
        let a = try await lib.addTweak(try tweakFile(in: tmp, "Alpha.dylib"), recordID: rec.id, deviceIDs: [],
                                       runner: ProcessRunner(), now: date).package
        let b = try await lib.addTweak(try tweakFile(in: tmp, "Beta.dylib"), recordID: rec.id, deviceIDs: [],
                                       runner: ProcessRunner(), now: date).package
        for device in ["d1", "d2"] {
            var i = installation(device, uses: [TweakUse(id: a.id), TweakUse(id: b.id)],
                                 injected: [InjectedTweak(a, conversions: [.jailbreakPaths]), InjectedTweak(b, conversions: nil)])
            i.signedChoices = SigningChoices(withoutXSideFeatures: false, duoCompatibility: false, iCloudSignedOut: false,
                                             tweaks: [a.id, b.id])
            i.tweakResults = [a.id: .injected(converted: true), b.id: .injected(converted: false)]
            _ = try await lib.recordSigning(i, for: rec.id, requireExisting: false)
        }
        return (lib, try #require(await lib.records().first), a, b)
    }

    private func tweakFile(in dir: URL, _ name: String) throws -> URL {
        let folder = dir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try FakeIPA.dylibMachO(linking: [], padding: 64, strings: [name]).write(to: url)
        return url
    }

    private func uses(_ lib: AppLibrary, _ device: String) async -> [TweakUse]? {
        await lib.records().first?.installations.first { $0.deviceID == device }?.tweaks
    }

    @Test func disableThisTweakHereOnlyRaisesThePendingChange() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec, a, b) = try await setUp(tmp)
        let d = CrashDiagnosis(cause: .tweak, subject: "Alpha.dylib")
        #expect(try await lib.disableTweaksAfterCrash(.disableTweak, diagnosis: d, recordID: rec.id, deviceID: "d1", allDevices: false))
        #expect(await uses(lib, "d1") == [TweakUse(id: a.id, enabled: false), TweakUse(id: b.id)])
        #expect(await uses(lib, "d2") == [TweakUse(id: a.id), TweakUse(id: b.id)])
        // « Changement en attente »: the enabled ids no longer match what the last signing asked.
        let d1 = try #require(await lib.records().first?.installations.first { $0.deviceID == "d1" })
        #expect(d1.pendingSigningChanges(wantsWithoutXSideFeatures: false).contains(.tweaks))
        // Nothing left to change: false (no refresh).
        #expect(try await lib.disableTweaksAfterCrash(.disableTweak, diagnosis: d, recordID: rec.id, deviceID: "d1", allDevices: false) == false)
    }

    @Test func disableTheConvertedTweaksOnAllDevices() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec, a, b) = try await setUp(tmp)
        let d = CrashDiagnosis(cause: .tweakSupport, subject: "XSideTweakSupport.dylib")
        #expect(try await lib.disableTweaksAfterCrash(.disableConvertedTweaks, diagnosis: d, recordID: rec.id, deviceID: "d1",
                                                       allDevices: true))
        for device in ["d1", "d2"] {
            #expect(await uses(lib, device) == [TweakUse(id: a.id, enabled: false), TweakUse(id: b.id)])
        }
        // Persisted.
        #expect(await AppLibrary(root: lib.root).records() == (await lib.records()))
    }

    @Test func nothingToDoIsFalse() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec, _, _) = try await setUp(tmp)
        let before = await lib.records()
        // No subject, an image that isn't a tweak, an action that isn't a tweak's, a device without the app.
        #expect(try await lib.disableTweaksAfterCrash(.disableTweak, diagnosis: CrashDiagnosis(cause: .tweak), recordID: rec.id,
                                                       deviceID: "d1", allDevices: true) == false)
        #expect(try await lib.disableTweaksAfterCrash(.disableTweak, diagnosis: nil, recordID: rec.id,
                                                       deviceID: "d1", allDevices: true) == false)
        #expect(try await lib.disableTweaksAfterCrash(.disableTweak, diagnosis: CrashDiagnosis(cause: .tweak, subject: "UIKitCore"),
                                                       recordID: rec.id, deviceID: "d1", allDevices: true) == false)
        #expect(try await lib.disableTweaksAfterCrash(.refresh, diagnosis: CrashDiagnosis(cause: .codeSignature), recordID: rec.id,
                                                       deviceID: "d1", allDevices: true) == false)
        #expect(try await lib.disableTweaksAfterCrash(.disableConvertedTweaks, diagnosis: CrashDiagnosis(cause: .tweakSupport),
                                                       recordID: rec.id, deviceID: "nope", allDevices: true) == false)
        #expect(await lib.records() == before)
    }

    @Test func onlyOtherDevicesChangedIsFalseForTheCrashedOne() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (lib, rec, a, b) = try await setUp(tmp)
        try await lib.setTweaks([TweakUse(id: a.id, enabled: false), TweakUse(id: b.id)], recordID: rec.id, deviceID: "d1")
        let d = CrashDiagnosis(cause: .tweak, subject: "Alpha.dylib")
        // d2 changes (at its next signing), but d1 has nothing new to sign: no refresh.
        #expect(try await lib.disableTweaksAfterCrash(.disableTweak, diagnosis: d, recordID: rec.id, deviceID: "d1",
                                                       allDevices: true) == false)
        #expect(await uses(lib, "d2") == [TweakUse(id: a.id, enabled: false), TweakUse(id: b.id)])
    }

    @Test func aFailedSaveThrowsAndChangesNothing() async throws {
        let tmp = try tempDir(); defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.appendingPathComponent("lib").path)
            try? FileManager.default.removeItem(at: tmp)
        }
        let (lib, rec, _, _) = try await setUp(tmp)
        let before = await lib.records()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lib.root.path)
        await #expect(throws: (any Error).self) {
            try await lib.disableTweaksAfterCrash(.disableTweak, diagnosis: CrashDiagnosis(cause: .tweak, subject: "Alpha.dylib"),
                                                  recordID: rec.id, deviceID: "d1", allDevices: true)
        }
        #expect(await lib.records() == before)
    }
}
