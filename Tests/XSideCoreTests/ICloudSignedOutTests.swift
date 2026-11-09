import Foundation
import Testing
@testable import XSideCore

private let ok = CommandResult(status: 0, stdout: Data(), stderr: "")
private let team = "TEAM123456"
private let cloudKit = "/System/Library/Frameworks/CloudKit.framework/CloudKit"
private let foundation = "/System/Library/Frameworks/Foundation.framework/Foundation"

private func tempDir(_ name: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("xside-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// Thin arm64 Mach-O: a `__TEXT` segment whose section starts `padding` bytes after the load
/// commands, a load command per library in `dylibs` (cmd, path), and, with `entitlements`, a last
/// LC_CODE_SIGNATURE pointing at a super blob holding them (after the section).
private func iCloudMachO(dylibs: [(cmd: UInt32, path: String)] = [], entitlements: [String: Any]? = nil,
                         rpaths: [String] = [], padding: Int = 256) throws -> Data {
    var commands = Data()
    func le(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    var count: UInt32 = 1
    for dylib in dylibs {
        var name = Array(dylib.path.utf8) + [0]
        let size = (24 + name.count + 7) & ~7
        name += Array(repeating: 0, count: size - 24 - name.count)
        for v in [dylib.cmd, UInt32(size), 24, 2, 0x10000, 0x10000] { le(v, &commands) }
        commands.append(contentsOf: name)
        count += 1
    }
    for path in rpaths {
        var name = Array(path.utf8) + [0]
        let size = (12 + name.count + 7) & ~7
        name += Array(repeating: 0, count: size - 12 - name.count)
        le(0x8000_001C, &commands); le(UInt32(size), &commands); le(12, &commands)
        commands.append(contentsOf: name)
        count += 1
    }
    let xml = try entitlements.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0) }
    let segmentSize = 72 + 80
    let signatureCommand = xml == nil ? 0 : 16
    let sizeofcmds = segmentSize + commands.count + signatureCommand
    let sectionOffset = 32 + sizeofcmds + padding
    let codeEnd = sectionOffset + 16
    var d = Data()
    func h32(_ v: UInt32) { le(v, &d) }
    func h64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func name16(_ s: String) { var b = Array(s.utf8); b += Array(repeating: 0, count: 16 - b.count); d.append(contentsOf: b) }
    h32(0xFEEDFACF); h32(0x0100000C); h32(0); h32(2)
    h32(count + (xml == nil ? 0 : 1)); h32(UInt32(sizeofcmds)); h32(0); h32(0)
    h32(0x19); h32(UInt32(segmentSize)); name16("__TEXT")
    h64(0x100000000); h64(UInt64(codeEnd)); h64(0); h64(UInt64(codeEnd))
    h32(5); h32(5); h32(1); h32(0)
    name16("__text"); name16("__TEXT"); h64(0x100000000 + UInt64(sectionOffset)); h64(16)
    h32(UInt32(sectionOffset)); h32(2); for _ in 0..<6 { h32(0) }
    d.append(commands)
    var blob = Data()
    if let xml {
        func be(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { blob.append(contentsOf: $0) } }
        let entSize = UInt32(8 + xml.count)
        let superSize = 12 + 8 + entSize
        be(0xFADE_0CC0); be(superSize); be(1); be(5); be(20)
        be(0xFADE_7171); be(entSize); blob.append(xml)
        h32(0x1D); h32(16); h32(UInt32(codeEnd)); h32(UInt32(blob.count))
    }
    d.append(Data(count: sectionOffset - d.count))
    d.append(Data(repeating: 0xAB, count: 16))
    d.append(blob)
    return d
}

private func write(_ data: Data) throws -> URL {
    let url = try tempDir("icloud-macho").appendingPathComponent("Demo")
    try data.write(to: url)
    return url
}

struct ICloudDetectionTests {
    @Test func entitlementsThatMeanICloud() {
        for key in ICloudSignedOut.entitlementKeys {
            let value: Any = key.hasSuffix("kvstore-identifier") ? "TEAM.com.vendor.app" : ["iCloud.com.vendor.app"]
            #expect(ICloudSignedOut.entitlementsUseICloud([key: value]), "\(key)")
        }
        #expect(ICloudSignedOut.entitlementsUseICloud(["com.apple.developer.icloud-services": "*"]))
        #expect(!ICloudSignedOut.entitlementsUseICloud(["com.apple.developer.icloud-container-identifiers": [Any]()]))
        #expect(!ICloudSignedOut.entitlementsUseICloud(["keychain-access-groups": ["TEAM.x"]]))
        #expect(!ICloudSignedOut.entitlementsUseICloud(nil))
        // Only a truthy value: a non-empty list or string, or true (the .ipa is untrusted).
        #expect(ICloudSignedOut.entitlementsUseICloud(["com.apple.developer.icloud-services": true]))
        #expect(!ICloudSignedOut.entitlementsUseICloud(["com.apple.developer.icloud-services": false]))
        #expect(!ICloudSignedOut.entitlementsUseICloud(["com.apple.developer.ubiquity-kvstore-identifier": ""]))
        #expect(!ICloudSignedOut.entitlementsUseICloud(["com.apple.developer.icloud-services": 1]))
        #expect(!ICloudSignedOut.entitlementsUseICloud(["com.apple.developer.icloud-container-identifiers": ["x": 1]]))
    }

    /// Only plain `iCloud.` identifiers, in order, once each, capped: the .ipa is untrusted.
    @Test func containersAreCheckedAndCapped() {
        let declared: [Any] = ["iCloud.com.vendor.app", 42, "iCloud.*", "$(TeamIdentifierPrefix)x", "TEAM.com.vendor",
                               "iCloud.com.vendor.app", "iCloud.", "iCloud.a..b", "iCloud.bad/slash", "iCloud.é",
                               "iCloud.com.vendor.shared_1-2", "iCloud." + String(repeating: "a", count: 300)]
        #expect(ICloudSignedOut.containerIdentifiers(["com.apple.developer.icloud-container-identifiers": declared])
                == ["iCloud.com.vendor.app", "iCloud.com.vendor.shared_1-2"])
        let many = (0..<40).map { "iCloud.c\($0)" }
        #expect(ICloudSignedOut.containerIdentifiers(["com.apple.developer.icloud-container-identifiers": many]).count == 16)
        #expect(ICloudSignedOut.containerIdentifiers(["com.apple.developer.icloud-container-identifiers": "iCloud.x"]).isEmpty)
        #expect(ICloudSignedOut.containerIdentifiers(nil).isEmpty)
    }

    @Test func linksCloudKitFromAnyLoadCommand() throws {
        for cmd: UInt32 in [0xC, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023] {
            let url = try write(try iCloudMachO(dylibs: [(0xC, foundation), (cmd, cloudKit)]))
            #expect(ICloudSignedOut.linksCloudKit(url), "cmd \(cmd)")
        }
        #expect(ICloudSignedOut.linksCloudKit(try write(try iCloudMachO(dylibs: [(0xC, "/System/Library/Frameworks/CloudKit.framework/Versions/A/CloudKit")]))))
        #expect(!ICloudSignedOut.linksCloudKit(try write(try iCloudMachO(dylibs: [(0xC, foundation)]))))
        // A name that only looks like it, or another command type, isn't CloudKit.
        #expect(!ICloudSignedOut.linksCloudKit(try write(try iCloudMachO(dylibs: [(0xC, "@rpath/MyCloudKit.framework/MyCloudKit")]))))
        #expect(!ICloudSignedOut.linksCloudKit(try write(try iCloudMachO(rpaths: [cloudKit]))))
        // In one slice of a fat binary.
        let fat = FakeIPA.fatMachO(slices: [try iCloudMachO(dylibs: [(0xC, foundation)]), try iCloudMachO(dylibs: [(0xC, cloudKit)])])
        #expect(ICloudSignedOut.linksCloudKit(try write(fat)))
    }

    /// Malformed or hostile executables are "doesn't link CloudKit", never a crash.
    @Test func hostileExecutablesAreNo() throws {
        let good = try iCloudMachO(dylibs: [(0xC, cloudKit)])
        var cases: [Data] = [Data(), Data([0xCF, 0xFA]), good.prefix(40), Data(repeating: 0xFF, count: 512)]
        // sizeofcmds past the end of the file.
        var big = good; big.replaceSubrange(20..<24, with: withUnsafeBytes(of: UInt32.max.littleEndian) { Data($0) }); cases.append(big)
        // ncmds huge.
        var many = good; many.replaceSubrange(16..<20, with: withUnsafeBytes(of: UInt32(0x7FFF_FFFF).littleEndian) { Data($0) }); cases.append(many)
        // The library's name offset points outside its command.
        let dylibAt = 32 + 72 + 80
        var offset = good; offset.replaceSubrange(dylibAt + 8..<dylibAt + 12, with: withUnsafeBytes(of: UInt32(0xFFFF_FFF0).littleEndian) { Data($0) }); cases.append(offset)
        // A command size of zero.
        var zero = good; zero.replaceSubrange(dylibAt + 4..<dylibAt + 8, with: Data(count: 4)); cases.append(zero)
        // A fat header claiming slices past the end, and too many slices.
        var fat = Data(); for v: UInt32 in [0xCAFEBABE, 2, 0x0100000C, 0, 0xFFFF_0000, 64, 14] { withUnsafeBytes(of: v.bigEndian) { fat.append(contentsOf: $0) } }
        cases.append(fat)
        var huge = Data(); for v: UInt32 in [0xCAFEBABE, 0xFFFF_FFFF] { withUnsafeBytes(of: v.bigEndian) { huge.append(contentsOf: $0) } }
        cases.append(huge)
        for (i, data) in cases.enumerated() {
            #expect(!ICloudSignedOut.linksCloudKit(try write(data)), "case \(i)")
        }
        #expect(!ICloudSignedOut.linksCloudKit(URL(fileURLWithPath: "/nonexistent/Demo")))
        // The name offset pointing outside is skipped, a valid second command still counts.
        var mixed = try iCloudMachO(dylibs: [(0xC, foundation), (0xC, cloudKit)])
        mixed.replaceSubrange(dylibAt + 8..<dylibAt + 12, with: withUnsafeBytes(of: UInt32(5000).littleEndian) { Data($0) })
        #expect(ICloudSignedOut.linksCloudKit(try write(mixed)))
    }

    @Test func readsTheAppsFacts() throws {
        let ents: [String: Any] = ["com.apple.developer.icloud-container-identifiers": ["iCloud.com.vendor.app"]]
        let exe = try write(try iCloudMachO(dylibs: [(0xC, foundation)], entitlements: ents))
        let read = ICloudAppInfo.read(executable: exe, entitlements: IPAInspector.embeddedEntitlements(exe))
        #expect(read == ICloudAppInfo(declaresICloud: true, containers: ["iCloud.com.vendor.app"]))
        // Linking CloudKit is remembered apart: it doesn't mean the app uses iCloud.
        let linked = try write(try iCloudMachO(dylibs: [(0xC, cloudKit)]))
        #expect(ICloudAppInfo.read(executable: linked, entitlements: nil) == ICloudAppInfo(declaresICloud: false, linksCloudKit: true))
        let both = try write(try iCloudMachO(dylibs: [(0xC, cloudKit)], entitlements: ents))
        #expect(ICloudAppInfo.read(executable: both, entitlements: ents)
                == ICloudAppInfo(declaresICloud: true, linksCloudKit: true, containers: ["iCloud.com.vendor.app"]))
        let plain = try write(try iCloudMachO(dylibs: [(0xC, foundation)]))
        #expect(ICloudAppInfo.read(executable: plain, entitlements: [:]) == ICloudAppInfo(declaresICloud: false))
    }

    /// Recommended only from the entitlements; an app that only links CloudKit (YouTube) is
    /// offered neutrally. No account kind changes it (XSide gives no app iCloud).
    @Test func optionStateMatrix() {
        #expect(ICloudSignedOut.optionState(app: ICloudAppInfo(declaresICloud: true)) == .recommended)
        #expect(ICloudSignedOut.optionState(app: ICloudAppInfo(declaresICloud: true, linksCloudKit: true)) == .recommended)
        #expect(ICloudSignedOut.optionState(app: ICloudAppInfo(declaresICloud: false, linksCloudKit: true)) == .useful)
        #expect(ICloudSignedOut.optionState(app: ICloudAppInfo(declaresICloud: false)) == .notNeeded)
        #expect(ICloudSignedOut.optionState(app: nil) == .unknown)
    }

    /// A record written before the split (one `usesICloud` key, which counted linking CloudKit)
    /// reads as "not known", never as recommended.
    @Test func oldAppInfoIsNotKnown() throws {
        let old = Data(#"{"usesICloud":true,"containers":[]}"#.utf8)
        #expect((try? JSONDecoder().decode(ICloudAppInfo.self, from: old)) == nil)
        let info = ICloudAppInfo(declaresICloud: false, linksCloudKit: true, containers: ["iCloud.a"])
        #expect(try JSONDecoder().decode(ICloudAppInfo.self, from: JSONEncoder().encode(info)) == info)
    }

    /// Asked for but not added by the last signing: the app doesn't have it.
    @Test func installationHasTheLibraryOnlyWhenAdded() {
        var i = Installation(deviceID: "D", installedAt: Date(), expiresAt: Date())
        #expect(!i.hasICloudSignedOut)
        i.iCloudSignedOut = true
        #expect(i.hasICloudSignedOut)
        i.iCloudSignedOutMissing = true
        #expect(!i.hasICloudSignedOut)
    }

    @Test func infoPlistKeys() {
        var plist: [String: Any] = ["XSideOriginalBundleID": "old", "XSideICloudContainers": ["iCloud.old"], "CFBundleIdentifier": "x"]
        ICloudSignedOut.applyInfoPlist(&plist, originalBundleID: "com.vendor.app", containers: [])
        #expect(plist["XSideOriginalBundleID"] as? String == "com.vendor.app")
        #expect(plist["XSideICloudContainers"] == nil)
        ICloudSignedOut.applyInfoPlist(&plist, originalBundleID: "com.vendor.app", containers: ["iCloud.a"])
        #expect(plist["XSideICloudContainers"] as? [String] == ["iCloud.a"])
        #expect(plist[ICloudSignedOut.enabledKey] as? Bool == true)
        ICloudSignedOut.clearInfoPlist(&plist)
        #expect(plist["XSideOriginalBundleID"] == nil && plist["XSideICloudContainers"] == nil)
        #expect(plist[ICloudSignedOut.enabledKey] == nil)
        #expect(plist["CFBundleIdentifier"] as? String == "x")
    }

    @Test func crashActionTurnsTheOptionOn() {
        #expect(CrashAction.suggested(for: CrashDiagnosis(cause: .iCloud)) == .turnOnICloudSignedOut)
        var on = CrashDiagnosis(cause: .iCloud); on.iCloudSignedOutOn = true
        #expect(CrashAction.suggested(for: on) == nil) // already on: something it doesn't cover
        #expect(CrashAction.suggested(for: CrashDiagnosis(cause: .other)) == nil)
        // Older crash files have no key; files of a build that knew paid teams still offer it.
        let old = try? JSONDecoder().decode(CrashDiagnosis.self, from: Data(#"{"cause":"iCloud","duoCompatibilityOn":false,"topFrames":[]}"#.utf8))
        #expect(old.map(CrashAction.suggested(for:)) == .turnOnICloudSignedOut)
        let paid = try? JSONDecoder().decode(CrashDiagnosis.self, from: Data(#"{"cause":"iCloud","duoCompatibilityOn":false,"topFrames":[],"iCloudSignedOutUnavailable":true}"#.utf8))
        #expect(paid.map(CrashAction.suggested(for:)) == .turnOnICloudSignedOut)
    }

    @Test func preflightNoteOnlyWhenTheEntitlementsDeclareICloud() {
        let targets = [InstallPreflight.Target(deviceID: "a", osVersion: "27.3", otherApps: [], hasThisApp: false),
                       InstallPreflight.Target(deviceID: "b", osVersion: "27.3", otherApps: [], hasThisApp: false)]
        func check(_ icloud: ICloudAppInfo?, on: Set<String> = []) -> [InstallPreflight.Warning] {
            InstallPreflight.check(minimumOS: nil, targets: targets, needsNewAppID: false, appIDsRemaining: nil,
                                   icloud: icloud, iCloudSignedOutDevices: on)
        }
        let uses = ICloudAppInfo(declaresICloud: true)
        #expect(check(uses) == [.usesICloud(optionOn: false)])
        #expect(check(uses, on: ["a"]) == [.usesICloud(optionOn: true)])
        #expect(check(uses, on: ["a", "b"]).isEmpty)
        #expect(check(ICloudAppInfo(declaresICloud: true, linksCloudKit: true)) == [.usesICloud(optionOn: false)])
        // Linking CloudKit alone: no note (YouTube links it and runs fine).
        #expect(check(ICloudAppInfo(declaresICloud: false, linksCloudKit: true)).isEmpty)
        #expect(check(ICloudAppInfo(declaresICloud: false)).isEmpty)
        #expect(check(nil).isEmpty)
    }

    @Test func progressListHasTheStepOnlyWhenAsked() {
        #expect(!ProgressStep.list(includingWifiCheck: false).contains(.icloud))
        let steps = ProgressStep.list(includingWifiCheck: false, includingDuo: true, includingICloud: true)
        #expect(steps == [.preparing, .profile, .welcome, .duo, .icloud, .signing, .installing])
        #expect(ProgressStep(.icloud) == .icloud)
    }

    @Test func summaryLine() {
        let s = InAppSettings.defaults(reminder: true, at: Date())
        let none = InstallSummary.lines(options: InstallOptions(), inApp: s, withoutXSideFeatures: false, openAppAfter: false,
                                        openTrustPage: false, offersKeychain: false)
        #expect(!(none.install + none.fixes).contains { if case .iCloudSignedOut = $0 { true } else { false } })
        let offered = InstallSummary.lines(options: InstallOptions(), inApp: s, withoutXSideFeatures: false, openAppAfter: false,
                                           openTrustPage: false, offersKeychain: false, iCloudDevices: ["iPhone"], offersICloud: true)
        #expect(offered.fixes.contains(.iCloudSignedOut(["iPhone"])))
        #expect(!offered.install.contains(.iCloudSignedOut(["iPhone"])))
    }

    @Test func oldStateDecodes() throws {
        let options = try JSONDecoder().decode(InstallOptions.self, from: Data(#"{"fileSharing":true}"#.utf8))
        #expect(options.iCloudSignedOut == nil)
        let installation = try JSONDecoder().decode(Installation.self, from: Data(
            #"{"deviceID":"d","installedAt":0,"expiresAt":0}"#.utf8))
        #expect(installation.iCloudSignedOut == nil && installation.iCloudSignedOutMissing == nil)
    }
}

// MARK: - Signing

private func profile() -> ProvisioningProfile {
    let ents: [String: Any] = ["application-identifier": "\(team).com.example.new"]
    let data = try! PropertyListSerialization.data(fromPropertyList: ents, format: .xml, options: 0)
    return ProvisioningProfile(uuid: "U-1", teamID: team, bundleID: "com.example.new", creationDate: Date(),
                               expirationDate: Date().addingTimeInterval(1000), deviceUDIDs: [], entitlements: data)
}

private struct ICloudFixture {
    let ipa: URL, work: URL, profileURL: URL
    let fake = FakeRunner()
    let welcome: URL?
    let shim: URL?

    init(executable: Data, plistExtras: [String: Any] = ["CFBundleName": "Demo"],
         withModule: Bool = true, withShim: Bool = true, frameworks: [String: Data] = [:]) async throws {
        let src = try tempDir("icloud-src")
        let made = try FakeIPA.makeApp(at: src, bundleID: "com.vendor.app", extensions: [], executableData: executable, plistExtras: plistExtras)
        // Files an earlier XSide signing left in the .ipa.
        for (name, data) in frameworks { try data.write(to: made.appendingPathComponent("Frameworks/\(name)")) }
        let out = try tempDir("icloud-ipa")
        ipa = out.appendingPathComponent("Demo.ipa")
        let r = try await ProcessRunner().run("/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", "--keepParent", src.appendingPathComponent("Payload").path, ipa.path], cwd: nil)
        #expect(r.status == 0)
        profileURL = out.appendingPathComponent("p.mobileprovision")
        try Data("PROFILE".utf8).write(to: profileURL)
        work = try tempDir("icloud-work")
        fake.stub("/usr/bin/codesign", result: ok)
        let libs = try tempDir("icloud-libs")
        if withModule {
            welcome = libs.appendingPathComponent("XSideWelcome.dylib")
            try Data("WELCOME".utf8).write(to: welcome!)
        } else { welcome = nil }
        if withShim {
            shim = libs.appendingPathComponent("XSideICloud.dylib")
            try Data("ICLOUD".utf8).write(to: shim!)
        } else { shim = nil }
    }

    var resigner: Resigner { Resigner(runner: RoutingRunner(fake: fake), welcomeDylib: welcome, iCloudLibrary: shim) }

    func run(_ options: InstallOptions, onICloud: @Sendable () async -> Void = {},
             onICloudSkipped: @Sendable (ICloudOutcome) async -> Void = { _ in }) async throws -> URL {
        try await resigner.resign(ipa: ipa, workDir: work, bundleID: "com.vendor.app.\(team)", options: options, iconURL: nil,
                                  profileURL: profileURL, profile: profile(), identitySHA1: "SHA", facts: nil,
                                  onICloud: onICloud, onICloudSkipped: onICloudSkipped)
    }
}

private func plist(_ app: URL) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")),
                                               format: nil) as! [String: Any]
}

private actor Count { var n = 0; func add() { n += 1 } }
private actor Outcomes { var all: [ICloudOutcome] = []; func add(_ o: ICloudOutcome) { all.append(o) } }

struct ICloudResignTests {
    private let ents: [String: Any] = ["application-identifier": "OLDTEAM123.com.vendor.app",
                                       "com.apple.developer.icloud-container-identifiers": ["iCloud.com.vendor.app.data", "iCloud.*"]]

    @Test func onAddsTheLibraryAndTheKeys() async throws {
        let f = try await ICloudFixture(executable: try iCloudMachO(dylibs: [(0xC, cloudKit)], entitlements: ents))
        let count = Count()
        let app = try await f.run(InstallOptions(iCloudSignedOut: true), onICloud: { await count.add() })
        #expect(await count.n == 1)
        let copied = app.appendingPathComponent("Frameworks/XSideICloud.dylib")
        #expect(try Data(contentsOf: copied) == Data("ICLOUD".utf8))
        let exe = app.appendingPathComponent("Demo")
        #expect(MachOPatcher.loadsDylib(ICloudSignedOut.loadPath, in: exe))
        #expect(MachOPatcher.loadsDylib("@executable_path/Frameworks/XSideWelcome.dylib", in: exe))
        #expect(f.resigner.hasICloudSignedOut(app))
        #expect(f.resigner.hasXSideLibrary(app))
        let info = try plist(app)
        // The app's own id, not the signed one, and only the valid declared containers.
        #expect(info["XSideOriginalBundleID"] as? String == "com.vendor.app")
        #expect(info["XSideICloudSignedOut"] as? Bool == true)
        #expect(info["XSideICloudContainers"] as? [String] == ["iCloud.com.vendor.app.data"])
        #expect(info["CFBundleIdentifier"] as? String == "com.vendor.app.\(team)")
        // Signed after the change, the library too.
        let targets = f.fake.calls.map { $0.last! }
        #expect(targets.firstIndex(of: copied.path)! < targets.firstIndex(of: app.path)!)
        // Paid-team behaviour unchanged: the signing entitlements never get iCloud keys.
        let last = try #require(f.fake.calls.last)
        let i = try #require(last.firstIndex(of: "--entitlements"))
        let granted = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: last[i + 1])),
                                                                 format: nil) as? [String: Any]
        #expect(granted?.keys.contains { ICloudSignedOut.entitlementKeys.contains($0) } == false)
    }

    @Test func offAddsNothingAndClearsCarriedKeys() async throws {
        let original = try iCloudMachO(dylibs: [(0xC, cloudKit)])
        let f = try await ICloudFixture(executable: original, plistExtras: ["CFBundleName": "Demo", "XSideOriginalBundleID": "evil",
                                                                            "XSideICloudContainers": ["iCloud.evil"]],
                                        withModule: false)
        let count = Count()
        let app = try await f.run(InstallOptions(), onICloud: { await count.add() })
        #expect(await count.n == 0)
        #expect(try Data(contentsOf: app.appendingPathComponent("Demo")) == original)
        #expect(!f.resigner.hasICloudSignedOut(app))
        let info = try plist(app)
        #expect(info["XSideOriginalBundleID"] == nil && info["XSideICloudContainers"] == nil)
    }

    @Test func worksWithoutXSidesModule() async throws {
        let f = try await ICloudFixture(executable: try iCloudMachO(dylibs: [(0xC, cloudKit)]))
        let app = try await f.run(InstallOptions(withoutXSideFeatures: true, iCloudSignedOut: true))
        #expect(f.resigner.hasICloudSignedOut(app))
        #expect(!f.resigner.hasXSideLibrary(app))
        let exe = app.appendingPathComponent("Demo")
        #expect(MachOPatcher.loadsDylib(ICloudSignedOut.loadPath, in: exe))
        #expect(!MachOPatcher.loadsDylib("@executable_path/Frameworks/XSideWelcome.dylib", in: exe))
        #expect(try plist(app)["XSideOriginalBundleID"] as? String == "com.vendor.app")
    }

    /// A build without the library: the install goes on as without the option, the step still told.
    @Test func noLibraryInThisBuild() async throws {
        let original = try iCloudMachO(dylibs: [(0xC, cloudKit)])
        let f = try await ICloudFixture(executable: original, withModule: false, withShim: false)
        let count = Count()
        let app = try await f.run(InstallOptions(iCloudSignedOut: true), onICloud: { await count.add() })
        #expect(await count.n == 1)
        #expect(!f.resigner.hasICloudSignedOut(app))
        #expect(try Data(contentsOf: app.appendingPathComponent("Demo")) == original)
        #expect(try plist(app)["XSideOriginalBundleID"] == nil)
    }

    /// No room even after dropping the toolchain run paths: the app is installed without it, and
    /// nothing of it is left in the bundle.
    @Test func noRoomLeavesNothingBehind() async throws {
        let f = try await ICloudFixture(executable: try iCloudMachO(dylibs: [(0xC, cloudKit)], padding: 16), withModule: false)
        let app = try await f.run(InstallOptions(iCloudSignedOut: true))
        #expect(!f.resigner.hasICloudSignedOut(app))
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/XSideICloud.dylib").path))
        #expect(try plist(app)["XSideOriginalBundleID"] == nil)
    }

    /// Room for both libraries only once the build Mac's toolchain run paths are gone: they go,
    /// and both load commands fit.
    @Test func makesRoomForBothLibraries() async throws {
        let toolchain = "/private/var/select/developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/iphoneos"
        let exe = try iCloudMachO(dylibs: [(0xC, cloudKit)], rpaths: [toolchain, "@executable_path/Frameworks"], padding: 120)
        let f = try await ICloudFixture(executable: exe)
        let app = try await f.run(InstallOptions(iCloudSignedOut: true))
        let out = app.appendingPathComponent("Demo")
        #expect(try MachOPatcher.rpaths(in: out) == ["@executable_path/Frameworks"])
        #expect(f.resigner.hasICloudSignedOut(app))
        #expect(f.resigner.hasXSideLibrary(app))
        // Without the option the run paths stay.
        let plain = try await ICloudFixture(executable: exe)
        let plainApp = try await plain.run(InstallOptions())
        #expect(try MachOPatcher.rpaths(in: plainApp.appendingPathComponent("Demo")).count == 2)
    }

    /// Morning review M1: an .ipa XSide signed before, with the iCloud library, its module and the
    /// Duo compatibility module (its delegate no longer named), signed again with all of them off:
    /// the files and their load commands go, the app's own library stays, the gate key goes.
    @Test func librariesFromAnEarlierSigningGoWhenTheirOptionIsOff() async throws {
        let welcome = "@executable_path/Frameworks/XSideWelcome.dylib"
        let exe = try iCloudMachO(dylibs: [(0xC, cloudKit), (0x8000_0018, DuoCompatibility.legacyLoadPath),
                                           (0x8000_0018, welcome), (0x8000_0018, ICloudSignedOut.loadPath)])
        let f = try await ICloudFixture(executable: exe, plistExtras: ["CFBundleName": "Demo", "XSideICloudSignedOut": true,
                                                                       "XSideOriginalBundleID": "com.vendor.app"],
                                        frameworks: ["XSideICloud.dylib": Data("OLD".utf8), "XSideWelcome.dylib": Data("OLD".utf8),
                                                     "XSideDuoLegacy.dylib": Data("OLD".utf8)])
        let app = try await f.run(InstallOptions(withoutXSideFeatures: true))
        let out = app.appendingPathComponent("Demo")
        for name in ["XSideICloud.dylib", "XSideWelcome.dylib", "XSideDuoLegacy.dylib"] {
            #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/\(name)").path))
        }
        for path in [ICloudSignedOut.loadPath, welcome, DuoCompatibility.legacyLoadPath] {
            #expect(!MachOPatcher.loadsAnySlice(path, in: out))
        }
        #expect(MachOPatcher.loadsDylib(cloudKit, in: out))
        #expect(!f.resigner.hasICloudSignedOut(app) && !f.resigner.hasXSideLibrary(app))
        #expect(try plist(app)["XSideICloudSignedOut"] == nil)
        // The option on again: a fresh library replaces the old one, the command once.
        let on = try await ICloudFixture(executable: exe, frameworks: ["XSideICloud.dylib": Data("OLD".utf8)])
        let onApp = try await on.run(InstallOptions(iCloudSignedOut: true))
        #expect(try Data(contentsOf: onApp.appendingPathComponent("Frameworks/XSideICloud.dylib")) == Data("ICLOUD".utf8))
        #expect(MachOPatcher.loadsDylib(ICloudSignedOut.loadPath, in: onApp.appendingPathComponent("Demo")))
    }

    /// A library of the app's own loaded after XSide's (a tool injected one since): XSide's command
    /// stays (removing it would shift that library's ordinal), its file goes, so it can't load.
    @Test func aStaleCommandBeforeTheAppsOwnLibraryStays() async throws {
        let exe = try iCloudMachO(dylibs: [(0x8000_0018, ICloudSignedOut.loadPath), (0xC, cloudKit)])
        let f = try await ICloudFixture(executable: exe, frameworks: ["XSideICloud.dylib": Data("OLD".utf8)])
        let app = try await f.run(InstallOptions())
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/XSideICloud.dylib").path))
        #expect(MachOPatcher.loadsDylib(ICloudSignedOut.loadPath, in: app.appendingPathComponent("Demo")))
        #expect(MachOPatcher.loadsDylib(cloudKit, in: app.appendingPathComponent("Demo")))
    }

    /// The Duo compatibility module stays while the Info.plist names its delegate (the raised SDK needs it).
    @Test func theDuoModuleStaysWhileTheManifestNamesIt() async throws {
        let manifest: [String: Any] = ["UISceneConfigurations": ["UIWindowSceneSessionRoleApplication": [
            ["UISceneDelegateClassName": DuoCompatibility.legacySceneDelegateClass]]]]
        let exe = try iCloudMachO(dylibs: [(0xC, cloudKit), (0x8000_0018, DuoCompatibility.legacyLoadPath)])
        let f = try await ICloudFixture(executable: exe, plistExtras: ["CFBundleName": "Demo", "UIApplicationSceneManifest": manifest],
                                        frameworks: ["XSideDuoLegacy.dylib": Data("OLD".utf8)])
        let app = try await f.run(InstallOptions())
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/XSideDuoLegacy.dylib").path))
        #expect(MachOPatcher.loadsDylib(DuoCompatibility.legacyLoadPath, in: app.appendingPathComponent("Demo")))
    }

    /// Morning review M2: room for one more load command only. XSide's module keeps it and the
    /// install says why signed-out iCloud is missing; with the module turned off, iCloud gets it.
    @Test func roomForOneKeepsTheModule() async throws {
        let exe = try iCloudMachO(dylibs: [(0xC, cloudKit)], padding: 80)
        let f = try await ICloudFixture(executable: exe)
        let said = Outcomes()
        let app = try await f.run(InstallOptions(iCloudSignedOut: true), onICloudSkipped: { await said.add($0) })
        #expect(f.resigner.hasXSideLibrary(app))
        #expect(!f.resigner.hasICloudSignedOut(app))
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/XSideICloud.dylib").path))
        #expect(try plist(app)["XSideICloudSignedOut"] == nil)
        #expect(await said.all == [.noRoomBesideModule])
        let off = try await ICloudFixture(executable: exe)
        let offSaid = Outcomes()
        let offApp = try await off.run(InstallOptions(withoutXSideFeatures: true, iCloudSignedOut: true),
                                       onICloudSkipped: { await offSaid.add($0) })
        #expect(off.resigner.hasICloudSignedOut(offApp))
        #expect(await offSaid.all.isEmpty)
    }

    @Test func loadsDylibIsFalseForUnreadable() throws {
        #expect(!MachOPatcher.loadsDylib(ICloudSignedOut.loadPath, in: URL(fileURLWithPath: "/nonexistent")))
        #expect(!MachOPatcher.loadsDylib(ICloudSignedOut.loadPath, in: try write(Data(repeating: 0, count: 64))))
    }
}
