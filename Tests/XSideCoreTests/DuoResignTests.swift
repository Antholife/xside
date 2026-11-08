import Foundation
import Testing
@testable import XSideCore

private let ok = CommandResult(status: 0, stdout: Data(), stderr: "")
private let team = "TEAM123456"

private func tempDir(_ name: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("xside-\(name)-\(UUID().uuidString)")
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
/// with SDK 27.1 unless `vtoolFails`) and optionally XSide's library.
private struct DuoFixture {
    let ipa: URL, work: URL, profileURL: URL
    let fake: FakeRunner
    let welcome: URL?

    init(executable: Data, plistExtras: [String: Any] = ["CFBundleName": "Demo", "DTPlatformVersion": "26.4"],
         withLibrary: Bool = true, vtoolFails: Bool = false) async throws {
        let src = try tempDir("duo-src")
        try FakeIPA.makeApp(at: src, extensions: [], executableData: executable, plistExtras: plistExtras)
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
    }

    var resigner: Resigner { Resigner(runner: RoutingRunner(fake: fake), welcomeDylib: welcome) }

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

    @Test func anAppWithoutScenesIsLeftAsItCame() async throws {
        let original = versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4)))
        let f = try await DuoFixture(executable: original, withLibrary: false)
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
        let exe = versionedMachO(versionMin: (packed(12, 0), packed(14, 5)),
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

    @Test func optionDecodesFromOldOptions() throws {
        let old = try JSONDecoder().decode(InstallOptions.self, from: Data(#"{"fileSharing":true}"#.utf8))
        #expect(old.duoCompatibility == nil)
    }
}
