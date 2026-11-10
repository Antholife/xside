import Foundation
import Testing
@testable import XSideCore

private let ok = CommandResult(status: 0, stdout: Data(), stderr: "")
private let team = "TEAM123456"

private func tempDir(_ name: String) throws -> URL {
    let u = TestTemp.root.appendingPathComponent("xside-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func profile() -> ProvisioningProfile {
    let ents: [String: Any] = ["application-identifier": "\(team).com.example.new"]
    let data = try! PropertyListSerialization.data(fromPropertyList: ents, format: .xml, options: 0)
    return ProvisioningProfile(uuid: "U-1", teamID: team, bundleID: "com.example.new", creationDate: Date(),
                               expirationDate: Date().addingTimeInterval(1000), deviceUDIDs: [], entitlements: data)
}

private func realExecutable(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/macho/\(name)"))
}

/// An IPA with `executable`, a fake runner (codesign, and `xcrun vtool` writing `vtoolOutput`
/// with SDK 27.1 unless `vtoolFails`) and optionally XSide's library, the signed-out iCloud one
/// and the Duo compatibility module (in the build unless `withLegacy` is false).
private struct DuoFixture {
    let ipa: URL, work: URL, profileURL: URL
    let fake: FakeRunner
    let welcome: URL?
    let iCloud: URL?
    let legacy: URL?

    init(executable: Data, plistExtras: [String: Any] = ["CFBundleName": "Demo", "DTPlatformVersion": "26.4"],
         withLibrary: Bool = true, withICloud: Bool = false, withLegacy: Bool = true, vtoolFails: Bool = false,
         prepare: (URL) throws -> Void = { _ in }) async throws {
        let src = try tempDir("duo-src")
        try prepare(try FakeIPA.makeApp(at: src, extensions: [], executableData: executable, plistExtras: plistExtras))
        let out = try tempDir("duo-ipa")
        ipa = out.appendingPathComponent("Demo.ipa")
        let r = try await ProcessRunner().run("/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", "--keepParent", src.appendingPathComponent("Payload").path, ipa.path], cwd: nil)
        #expect(r.status == 0)
        profileURL = out.appendingPathComponent("p.mobileprovision")
        try Data("PROFILE".utf8).write(to: profileURL)
        work = try tempDir("duo-work")
        fake = FakeRunner()
        fake.stub("/usr/bin/codesign", result: ok)
        fake.stub("/usr/bin/xcrun", firstArg: "vtool", result: vtoolFails ? CommandResult(status: 1, stdout: Data(), stderr: "no") : ok) { args in
            guard !vtoolFails, let i = args.firstIndex(of: "-output"), i + 2 < args.count else { return }
            // What vtool does: the input with every version command set to SDK 27.1.
            let input = URL(fileURLWithPath: args[i + 2])
            var data = try! Data(contentsOf: input)
            raiseSDK(&data)
            try! data.write(to: URL(fileURLWithPath: args[i + 1]))
        }
        if withLibrary {
            let url = try tempDir("duo-welcome").appendingPathComponent("XSideWelcome.dylib")
            try Data("WELCOME".utf8).write(to: url)
            welcome = url
        } else {
            welcome = nil
        }
        let libs = try tempDir("duo-libs")
        iCloud = withICloud ? libs.appendingPathComponent("XSideICloud.dylib") : nil
        if let iCloud { try Data("ICLOUD".utf8).write(to: iCloud) }
        legacy = withLegacy ? libs.appendingPathComponent("XSideDuoLegacy.dylib") : nil
        if let legacy { try Data("DUOLEGACY".utf8).write(to: legacy) }
    }

    var resigner: Resigner {
        Resigner(runner: RoutingRunner(fake: fake), welcomeDylib: welcome, iCloudLibrary: iCloud, duoLegacyLibrary: legacy)
    }

    func run(_ options: InstallOptions) async throws -> URL {
        try await resigner.resign(ipa: ipa, workDir: work, bundleID: "com.example.new", options: options, iconURL: nil,
                                  profileURL: profileURL, profile: profile(), identitySHA1: "SHA", facts: nil)
    }

    var vtoolCalls: [[String]] { fake.calls.filter { $0.first == "/usr/bin/xcrun" } }
}

/// Sets the SDK of every LC_BUILD_VERSION of a thin or fat binary to 27.1 (what the fake vtool does).
private func raiseSDK(_ data: inout Data) {
    guard let starts = try? IPAInspector.sliceOffsets(data) else { return }
    for start in starts {
        guard let commands = try? MachOPatcher.loadCommands(data, at: start) else { continue }
        for c in commands where c.cmd == 0x32 {
            withUnsafeBytes(of: packed(27, 1).littleEndian) { data.replaceSubrange(c.pos + 16..<c.pos + 20, with: $0) }
        }
    }
}

private func plist(_ app: URL) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")),
                                               format: nil) as! [String: Any]
}

private func manifestDelegate(_ info: [String: Any]) -> String? {
    let manifest = info["UIApplicationSceneManifest"] as? [String: Any]
    let configs = manifest?["UISceneConfigurations"] as? [String: Any]
    return (configs?["UIWindowSceneSessionRoleApplication"] as? [[String: Any]])?.first?["UISceneDelegateClassName"] as? String
}

private actor CallOrder {
    var items: [String] = []
    func add(_ s: String) { items.append(s) }
}

struct DuoResignTests {
    @Test func raisesTheSDKAndNamesTheAppsSceneDelegate() async throws {
        let f = try await DuoFixture(executable: realExecutable("duo-objc-fat"))
        let app = try await f.run(InstallOptions(duoCompatibility: true))
        let exe = app.appendingPathComponent("Demo")
        #expect(MachOBuildInfo.sdkVersion(of: exe) == "27.1")
        #expect(f.vtoolCalls.count == 1)
        #expect(f.vtoolCalls[0][1...5] == ["vtool", "-set-build-version", "ios", "15.0", "27.1"])
        let info = try plist(app)
        #expect(info["DTPlatformVersion"] as? String == "27.1")
        #expect(info["DTSDKName"] as? String == "iphoneos27.1")
        #expect(manifestDelegate(info) == "FXBaseSceneDelegate")
        #expect(f.resigner.hasDuoCompatibility(app))
        // XSide's library is still added, and the executable is signed after the change.
        #expect(f.resigner.hasXSideLibrary(app))
        #expect(f.fake.calls.last?.last == app.path)
        // Nothing of the patch's own files is left in the bundle.
        let items = try FileManager.default.contentsOfDirectory(atPath: app.path)
        #expect(!items.contains { $0.hasPrefix("duo-") })
    }

    @Test func legacySlicesAreRemovedBeforeThePatchSoTheSDKCheckOnlySeesModernCode() async throws {
        let thin = try realExecutable("duo-swift-arm64")
        let fat = FakeIPA.fat([(12, 9, FakeIPA.machO(cpuType: 12, cryptid: 0)), (0x0100000C, 0, thin)])
        let f = try await DuoFixture(executable: fat)
        let order = CallOrder()
        let app = try await f.resigner.resign(ipa: f.ipa, workDir: f.work, bundleID: "com.example.new",
                                              options: InstallOptions(duoCompatibility: true), iconURL: nil,
                                              profileURL: f.profileURL, profile: profile(), identitySHA1: "SHA", facts: nil,
                                              onDuo: { if $0 == nil { await order.add("duo") } },
                                              onThinning: { await order.add("thin") })
        #expect(await order.items == ["thin", "duo"])
        let exe = app.appendingPathComponent("Demo")
        #expect(MachOBuildInfo.sdkVersion(of: exe) == "27.1")
        #expect(try IPAInspector.sliceEntries(Data(contentsOf: exe)).count == 1) // thin now, no fat header
        #expect(f.resigner.hasDuoCompatibility(app))
        #expect(f.resigner.hasXSideLibrary(app))
        #expect(manifestDelegate(try plist(app)) == "_TtC4main16AppSceneDelegate")
    }

    @Test func worksWithoutXSidesModule() async throws {
        let f = try await DuoFixture(executable: realExecutable("duo-swift-arm64"))
        let app = try await f.run(InstallOptions(withoutXSideFeatures: true, duoCompatibility: true))
        #expect(!f.resigner.hasXSideLibrary(app))
        #expect(MachOBuildInfo.sdkVersion(of: app.appendingPathComponent("Demo")) == "27.1")
        #expect(manifestDelegate(try plist(app)) == "_TtC4main16AppSceneDelegate")
        #expect(f.resigner.hasDuoCompatibility(app))
    }

    @Test func offLeavesTheAppAlone() async throws {
        let original = try realExecutable("duo-objc-fat")
        let f = try await DuoFixture(executable: original, withLibrary: false)
        let app = try await f.run(InstallOptions())
        #expect(f.vtoolCalls.isEmpty)
        #expect(try Data(contentsOf: app.appendingPathComponent("Demo")) == original)
        #expect(try plist(app)["UIApplicationSceneManifest"] == nil)
        #expect(try plist(app)["DTPlatformVersion"] as? String == "26.4")
        #expect(!f.resigner.hasDuoCompatibility(app))
    }

    /// A build without the compatibility module: an app without scene support is left as it came.
    @Test func anAppWithoutScenesIsLeftAsItCameWithoutTheModule() async throws {
        let original = versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4)))
        let f = try await DuoFixture(executable: original, withLibrary: false, withLegacy: false)
        let app = try await f.run(InstallOptions(duoCompatibility: true))
        #expect(f.vtoolCalls.isEmpty)
        #expect(try Data(contentsOf: app.appendingPathComponent("Demo")) == original)
        #expect(try plist(app)["DTPlatformVersion"] as? String == "26.4")
        #expect(!f.resigner.hasDuoCompatibility(app))
    }

    @Test func anAppWithAManifestOnlyGetsTheSDK() async throws {
        let own: [String: Any] = ["UIApplicationSupportsMultipleScenes": true]
        let f = try await DuoFixture(executable: versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4))),
                                     plistExtras: ["UIApplicationSceneManifest": own], withLibrary: false)
        let app = try await f.run(InstallOptions(duoCompatibility: true))
        let info = try plist(app)
        #expect(info["DTPlatformVersion"] as? String == "27.1")
        #expect((info["UIApplicationSceneManifest"] as? [String: Any])?["UIApplicationSupportsMultipleScenes"] as? Bool == true)
        #expect(f.resigner.hasDuoCompatibility(app))
    }

    @Test func anAppAlreadyBuiltForTheDuoIsntTouched() async throws {
        let original = versionedMachO(buildVersion: (2, packed(15, 0), packed(27, 2)))
        let f = try await DuoFixture(executable: original, plistExtras: ["DTPlatformVersion": "27.2"], withLibrary: false)
        let app = try await f.run(InstallOptions(duoCompatibility: true))
        #expect(f.vtoolCalls.isEmpty)
        #expect(try Data(contentsOf: app.appendingPathComponent("Demo")) == original)
        #expect(try plist(app)["DTPlatformVersion"] as? String == "27.2")
        #expect(f.resigner.hasDuoCompatibility(app)) // it already fills the screens
    }

    /// Any failure of the patch: the app is installed as it would have been without it.
    @Test func aFailedPatchNeverFailsTheInstall() async throws {
        let f = try await DuoFixture(executable: realExecutable("duo-objc-fat"), vtoolFails: true)
        let app = try await f.run(InstallOptions(duoCompatibility: true))
        let info = try plist(app)
        #expect(info["DTPlatformVersion"] as? String == "26.4")
        #expect(info["UIApplicationSceneManifest"] == nil)
        #expect(MachOBuildInfo.sdkVersion(of: app.appendingPathComponent("Demo")) == "26.4")
        #expect(!f.resigner.hasDuoCompatibility(app))
        #expect(f.resigner.hasXSideLibrary(app))
        #expect(f.fake.calls.last?.last == app.path)
    }

    /// No room for XSide's load command and the new version command: the build Mac's toolchain
    /// run paths go (only then), and both fit.
    @Test func makesRoomByDroppingTheToolchainRpaths() async throws {
        let toolchain = "/private/var/select/developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/iphoneos"
        let exe = versionedMachO(buildVersion: (2, packed(12, 0), packed(14, 5)),
                                 rpaths: [toolchain, "@executable_path/Frameworks"], padding: 40)
        let manifest: [String: Any] = ["UIApplicationSupportsMultipleScenes": false]
        let f = try await DuoFixture(executable: exe, plistExtras: ["UIApplicationSceneManifest": manifest])
        let app = try await f.run(InstallOptions(duoCompatibility: true))
        let out = app.appendingPathComponent("Demo")
        #expect(try MachOPatcher.rpaths(in: out) == ["@executable_path/Frameworks"])
        #expect(f.resigner.hasXSideLibrary(app))
        #expect(f.vtoolCalls.count == 1)

        // The same binary without the option keeps its run paths (and has no room for the library).
        let plainFixture = try await DuoFixture(executable: exe)
        let plainApp = try await plainFixture.run(InstallOptions())
        #expect(try MachOPatcher.rpaths(in: plainApp.appendingPathComponent("Demo")).count == 2)
        #expect(!plainFixture.resigner.hasXSideLibrary(plainApp))
    }

    /// The patch is done on a copy: when vtool fails after the run paths were dropped to make
    /// room, the executable is exactly what it would be without the option (duo review minor 3).
    @Test func aFailedPatchKeepsTheRunPaths() async throws {
        let toolchain = "/private/var/select/developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/iphoneos"
        let exe = versionedMachO(buildVersion: (2, packed(12, 0), packed(14, 5)),
                                 rpaths: [toolchain, "@executable_path/Frameworks"], padding: 40)
        let manifest: [String: Any] = ["UIApplicationSupportsMultipleScenes": false]
        let failing = try await DuoFixture(executable: exe, plistExtras: ["UIApplicationSceneManifest": manifest], vtoolFails: true)
        let app = try await failing.run(InstallOptions(duoCompatibility: true))
        let plain = try await DuoFixture(executable: exe, plistExtras: ["UIApplicationSceneManifest": manifest])
        let plainApp = try await plain.run(InstallOptions())
        #expect(failing.vtoolCalls.count == 1)
        #expect(try Data(contentsOf: app.appendingPathComponent("Demo")) == Data(contentsOf: plainApp.appendingPathComponent("Demo")))
        #expect(try MachOPatcher.rpaths(in: app.appendingPathComponent("Demo")).count == 2)
        #expect(failing.resigner.hasXSideLibrary(app) == plain.resigner.hasXSideLibrary(plainApp))
        #expect(!failing.resigner.hasDuoCompatibility(app))
        #expect(try plist(app)["DTPlatformVersion"] as? String != "27.1")
        // Nothing of the patch is left in the work folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: failing.work.path).filter { $0.hasPrefix("duo-") }.isEmpty)
    }

    /// Each signing tells how the option went, for the install window's Duo step.
    @Test func tellsTheOutcome() async throws {
        actor Outcomes { var items: [DuoOutcome?] = []; func add(_ o: DuoOutcome?) { items.append(o) } }
        func outcomes(_ f: DuoFixture, _ options: InstallOptions) async throws -> [DuoOutcome?] {
            let log = Outcomes()
            _ = try await f.resigner.resign(ipa: f.ipa, workDir: f.work, bundleID: "com.example.new", options: options,
                                            iconURL: nil, profileURL: f.profileURL, profile: profile(), identitySHA1: "SHA",
                                            facts: nil, onDuo: { await log.add($0) })
            return await log.items
        }
        let on = InstallOptions(duoCompatibility: true)
        #expect(try await outcomes(DuoFixture(executable: realExecutable("duo-objc-fat")), on) == [nil, .added])
        #expect(try await outcomes(DuoFixture(executable: realExecutable("duo-objc-fat"), vtoolFails: true), on) == [nil, .failed])
        #expect(try await outcomes(DuoFixture(executable: versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4))),
                                              withLibrary: false, withLegacy: false), on) == [nil, .notPossible])
        #expect(try await outcomes(DuoFixture(executable: versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4))),
                                              withLibrary: false), on) == [nil, .addedWithModule])
        #expect(try await outcomes(DuoFixture(executable: versionedMachO(buildVersion: (2, packed(15, 0), packed(27, 2))),
                                              plistExtras: ["DTPlatformVersion": "27.2"], withLibrary: false), on)
                == [nil, .alreadySupported])
        #expect(try await outcomes(DuoFixture(executable: realExecutable("duo-objc-fat")), InstallOptions()).isEmpty)
    }

    // MARK: Apps without scene support: the compatibility module

    /// No manifest, no scene delegate: the module goes in Frameworks/, the executable loads it
    /// (weakly), the manifest names its delegate, the SDK is raised; signed with the rest.
    @Test func anAppWithoutScenesGetsTheModule() async throws {
        let f = try await DuoFixture(executable: versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4))))
        let app = try await f.run(InstallOptions(duoCompatibility: true))
        let exe = app.appendingPathComponent("Demo")
        let module = app.appendingPathComponent("Frameworks/XSideDuoLegacy.dylib")
        #expect(try Data(contentsOf: module) == Data("DUOLEGACY".utf8))
        #expect(MachOPatcher.loadsDylib(DuoCompatibility.legacyLoadPath, in: exe))
        #expect(MachOBuildInfo.sdkVersion(of: exe) == "27.1")
        #expect(manifestDelegate(try plist(app)) == "XSDuoSceneDelegate")
        #expect(f.resigner.hasDuoCompatibility(app))
        #expect(f.resigner.hasDuoLegacyModule(app))
        #expect(f.resigner.hasXSideLibrary(app))
        let targets = f.fake.calls.filter { $0.first == "/usr/bin/codesign" }.map { $0.last! }
        #expect(targets.firstIndex(of: module.path)! < targets.firstIndex(of: app.path)!)
    }

    @Test func theModuleWorksWithoutXSidesModule() async throws {
        let f = try await DuoFixture(executable: versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4))))
        let app = try await f.run(InstallOptions(withoutXSideFeatures: true, duoCompatibility: true))
        #expect(!f.resigner.hasXSideLibrary(app))
        #expect(f.resigner.hasDuoLegacyModule(app))
        #expect(manifestDelegate(try plist(app)) == "XSDuoSceneDelegate")
    }

    /// An app with its own scene delegate never gets the module (today's behaviour).
    @Test func anAppWithItsOwnDelegateGetsNoModule() async throws {
        let f = try await DuoFixture(executable: realExecutable("duo-objc-fat"))
        let app = try await f.run(InstallOptions(duoCompatibility: true))
        #expect(manifestDelegate(try plist(app)) == "FXBaseSceneDelegate")
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/XSideDuoLegacy.dylib").path))
        #expect(!MachOPatcher.loadsDylib(DuoCompatibility.legacyLoadPath, in: app.appendingPathComponent("Demo")))
        #expect(!f.resigner.hasDuoLegacyModule(app))
    }

    /// Off: no module, even for an app without scenes.
    @Test func offAddsNoModule() async throws {
        let original = versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4)))
        let f = try await DuoFixture(executable: original, withLibrary: false)
        let app = try await f.run(InstallOptions())
        #expect(try Data(contentsOf: app.appendingPathComponent("Demo")) == original)
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/XSideDuoLegacy.dylib").path))
    }

    /// A failed patch leaves neither the module nor a manifest: an SDK 27.1 app without scenes
    /// would be stopped at launch, a manifest naming a missing class would show black.
    @Test func aFailedPatchLeavesNoModule() async throws {
        let original = versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4)))
        let f = try await DuoFixture(executable: original, withLibrary: false, vtoolFails: true)
        let app = try await f.run(InstallOptions(duoCompatibility: true))
        #expect(try Data(contentsOf: app.appendingPathComponent("Demo")) == original)
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/XSideDuoLegacy.dylib").path))
        #expect(try plist(app)["UIApplicationSceneManifest"] == nil)
        #expect(!f.resigner.hasDuoCompatibility(app))
    }

    /// No room for the module's load command even without the toolchain run paths: no patch at all.
    @Test func noRoomForTheModuleMeansNoPatch() async throws {
        let original = versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4)), padding: 40)
        let f = try await DuoFixture(executable: original, withLibrary: false)
        let app = try await f.run(InstallOptions(duoCompatibility: true))
        #expect(f.vtoolCalls.isEmpty)
        #expect(try Data(contentsOf: app.appendingPathComponent("Demo")) == original)
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/XSideDuoLegacy.dylib").path))
        #expect(try plist(app)["UIApplicationSceneManifest"] == nil)
    }

    /// The header room counts all three libraries (the module, signed-out iCloud, XSide's module):
    /// 224 bytes of load commands. 160 bytes free: the toolchain run path (96 bytes) goes, and all
    /// three fit.
    @Test func headerRoomCountsAllThreeLibraries() async throws {
        let toolchain = "/private/var/select/developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/iphoneos"
        let needed = [DuoCompatibility.legacyLoadPath, ICloudSignedOut.loadPath, "@executable_path/Frameworks/XSideWelcome.dylib"]
            .reduce(0) { $0 + MachOPatcher.dylibCommand($1).count }
        #expect(needed == 224)
        let exe = versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4)),
                                 rpaths: [toolchain, "@executable_path/Frameworks"], padding: 160)
        let f = try await DuoFixture(executable: exe, withICloud: true)
        let order = CallOrder()
        let app = try await f.resigner.resign(ipa: f.ipa, workDir: f.work, bundleID: "com.example.new",
                                              options: InstallOptions(duoCompatibility: true, iCloudSignedOut: true),
                                              iconURL: nil, profileURL: f.profileURL, profile: profile(),
                                              identitySHA1: "SHA", facts: nil,
                                              onDuo: { await order.add($0 == nil ? "duo" : "duo:\($0!.rawValue)") },
                                              onICloud: { await order.add("icloud") },
                                              onSigning: { await order.add("sign") })
        #expect(await order.items == ["duo", "duo:addedWithModule", "icloud", "sign"])
        let out = app.appendingPathComponent("Demo")
        #expect(try MachOPatcher.rpaths(in: out) == ["@executable_path/Frameworks"])
        #expect(f.resigner.hasDuoLegacyModule(app))
        #expect(f.resigner.hasICloudSignedOut(app))
        #expect(f.resigner.hasXSideLibrary(app))
        #expect(MachOBuildInfo.sdkVersion(of: out) == "27.1")
    }

    /// Mega review S2/D1: a storyboard app without scenes gets the module, and its manifest names
    /// the storyboard (iOS then loads it into the scene's window, which the module hands over).
    @Test func aStoryboardAppsManifestNamesTheStoryboard() async throws {
        let f = try await DuoFixture(executable: versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4))),
                                     plistExtras: ["CFBundleName": "Demo", "UIMainStoryboardFile": "Main"])
        let app = try await f.run(InstallOptions(duoCompatibility: true))
        let info = try plist(app)
        #expect(manifestDelegate(info) == "XSDuoSceneDelegate")
        let configs = (info["UIApplicationSceneManifest"] as? [String: Any])?["UISceneConfigurations"] as? [String: Any]
        #expect((configs?["UIWindowSceneSessionRoleApplication"] as? [[String: Any]])?.first?["UISceneStoryboardFile"] as? String == "Main")
    }

    /// Mega review S3: the usage texts the option adds are translated in the app's lprojs, with or
    /// without XSide's module, and the app's own translations win.
    @Test func addedUsageDescriptionsAreTranslatedInTheAppsLprojs() async throws {
        let f = try await DuoFixture(executable: realExecutable("duo-objc-fat")) { app in
            for lproj in ["fr.lproj", "en.lproj"] {
                try FileManager.default.createDirectory(at: app.appendingPathComponent(lproj), withIntermediateDirectories: true)
            }
            try Data(#""NSCameraUsageDescription" = "Caméra de l'app";"#.utf8)
                .write(to: app.appendingPathComponent("fr.lproj/InfoPlist.strings"))
        }
        let app = try await f.run(InstallOptions(withoutXSideFeatures: true, duoCompatibility: true))
        func table(_ lproj: String) throws -> [String: String] {
            try #require(try PropertyListSerialization.propertyList(
                from: Data(contentsOf: app.appendingPathComponent("\(lproj)/InfoPlist.strings")), format: nil) as? [String: String])
        }
        #expect(try table("fr.lproj")["NSPhotoLibraryUsageDescription"] == DuoCompatibility.usageDescriptions["fr"])
        #expect(try table("fr.lproj")["NSCameraUsageDescription"] == "Caméra de l'app")
        #expect(try table("en.lproj")["NSPhotoLibraryAddUsageDescription"] == DuoCompatibility.usageDescriptions["en"])
        #expect(try plist(app)["NSCameraUsageDescription"] as? String == DuoCompatibility.usageDescriptions["en"])
    }

    @Test func optionDecodesFromOldOptions() throws {
        let old = try JSONDecoder().decode(InstallOptions.self, from: Data(#"{"fileSharing":true}"#.utf8))
        #expect(old.duoCompatibility == nil)
    }
}
