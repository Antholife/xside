import Foundation
import Testing
@testable import XSideCore

/// Real iOS executables (Fixtures/macho), built once with the iOS SDK from the `.txt` sources
/// next to them, then given SDK 26.4 like an older IPA:
///   duo-objc-fat: `xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc
///     -framework UIKit -Wl,-rpath,/private/var/select/developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/iphoneos
///     -Wl,-rpath,@executable_path/Frameworks duo-objc.m`, the same for arm64e (no rpaths), each
///     `xcrun vtool -set-build-version ios 15.0 26.4 -replace`, then `lipo -create`.
///   duo-swift-arm64: `xcrun -sdk iphoneos swiftc -target arm64-apple-ios15.0 -parse-as-library
///     duo-swift.swift`, then the same vtool call.
private func machO(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/macho/\(name)")
}

private func copy(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("xside-duo-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: machO(name), to: url)
    return url
}

private func write(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("xside-duo-\(UUID().uuidString)")
    try data.write(to: url)
    return url
}

/// Thin arm64 Mach-O with one version command and `padding` free bytes after the commands.
/// `buildVersion`: LC_BUILD_VERSION (platform, minos, sdk); else `versionMin`:
/// LC_VERSION_MIN_IPHONEOS (version, sdk); `rpaths`: LC_RPATH commands.
func versionedMachO(buildVersion: (platform: UInt32, minos: UInt32, sdk: UInt32)? = nil,
                    versionMin: (version: UInt32, sdk: UInt32)? = nil, rpaths: [String] = [],
                    padding: Int = 256) -> Data {
    var commands = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { commands.append(contentsOf: $0) } }
    var count: UInt32 = 0
    if let b = buildVersion {
        le32(0x32); le32(32); le32(b.platform); le32(b.minos); le32(b.sdk); le32(1); le32(3); le32(0x0400_0000)
        count += 1
    } else if let v = versionMin {
        le32(0x25); le32(16); le32(v.version); le32(v.sdk)
        count += 1
    }
    for path in rpaths {
        var name = Array(path.utf8) + [0]
        let size = (12 + name.count + 7) & ~7
        name += Array(repeating: 0, count: size - 12 - name.count)
        le32(0x8000_001C); le32(UInt32(size)); le32(12)
        commands.append(contentsOf: name)
        count += 1
    }
    // A __TEXT segment with one section right after the free space.
    let segmentSize = 72 + 80
    let sizeofcmds = commands.count + segmentSize
    let sectionOffset = 32 + sizeofcmds + padding
    var d = Data()
    func h32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func h64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func name(_ s: String) { var b = Array(s.utf8); b += Array(repeating: 0, count: 16 - b.count); d.append(contentsOf: b) }
    h32(0xFEEDFACF); h32(0x0100000C); h32(0); h32(2)
    h32(count + 1); h32(UInt32(sizeofcmds)); h32(0); h32(0)
    h32(0x19); h32(UInt32(segmentSize)); name("__TEXT")
    h64(0x100000000); h64(UInt64(sectionOffset + 16)); h64(0); h64(UInt64(sectionOffset + 16))
    h32(5); h32(5); h32(1); h32(0)
    name("__text"); name("__TEXT"); h64(0x100000000 + UInt64(sectionOffset)); h64(16)
    h32(UInt32(sectionOffset)); h32(2); h32(0); h32(0); h32(0); h32(0); h32(0); h32(0)
    d.append(commands)
    d.append(Data(count: sectionOffset - d.count))
    d.append(Data(repeating: 0xAB, count: 16))
    return d
}

/// xxxx.yy.zz nibbles, as Mach-O stores versions.
func packed(_ major: UInt32, _ minor: UInt32, _ patch: UInt32 = 0) -> UInt32 { major << 16 | minor << 8 | patch }

private let plain = DuoAppInfo(sdkVersion: "26.4", adoptsScenes: false, sceneDelegateClass: "YTSceneDelegate")

struct DuoCompatibilityTests {
    // MARK: Devices

    @Test func knowsTheDuoByProductTypeOrName() {
        #expect(DeviceModel.isDuo(productType: "iPhone19,4", marketingName: "iPhone"))
        #expect(DeviceModel.isDuo(productType: "iPhone20,1", marketingName: "iPhone Duo"))
        #expect(!DeviceModel.isDuo(productType: "iPhone18,2", marketingName: "iPhone 17 Pro Max"))
        #expect(!DeviceModel.isDuo(productType: "iPad16,3", marketingName: "iPad Air"))
        #expect(!DeviceModel.isDuo(productType: nil, marketingName: nil))
    }

    @Test func devicesCarryTheirProductType() throws {
        let json = """
        {"result":{"devices":[{"identifier":"D1","connectionProperties":{"pairingState":"paired","transportType":"wired"},
        "deviceProperties":{"name":"iPhone Duo de Test","osVersionNumber":"27.3"},
        "hardwareProperties":{"deviceType":"iPhone","marketingName":"iPhone","productType":"iPhone19,4","reality":"physical"}}]}}
        """
        let d = try DeviceService.parse(Data(json.utf8))[0]
        #expect(d.productType == "iPhone19,4")
        #expect(d.isDuo)
        // Devices saved or built without it still decode and aren't a Duo.
        let old = Device(id: "x", udid: nil, name: "n", model: "iPhone 17", kind: .iPhone, transport: .usb,
                         isPaired: true, isAvailable: true, developerModeEnabled: true)
        #expect(!old.isDuo)
    }

    // MARK: SDK

    @Test func readsTheSDKFromTheBuildVersion() throws {
        let url = try write(versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4))))
        let slices = try MachOBuildInfo.slices(of: url)
        #expect(slices.count == 1)
        #expect(slices[0].minOS == "15.0")
        #expect(slices[0].sdk == "26.4")
        #expect(slices[0].platform == 2)
        #expect(slices[0].archName == "arm64")
        #expect(MachOBuildInfo.sdkVersion(of: url) == "26.4")
    }

    @Test func fallsBackToTheVersionMinCommand() throws {
        let url = try write(versionedMachO(versionMin: (packed(12, 0), packed(14, 5))))
        let slice = try MachOBuildInfo.slices(of: url)[0]
        #expect(slice.minOS == "12.0")
        #expect(slice.sdk == "14.5")
        #expect(slice.platform == nil)
        #expect(MachOBuildInfo.sdkVersion(of: url) == "14.5")
    }

    @Test func fallsBackToTheInfoPlist() throws {
        let url = try write(versionedMachO())
        #expect(MachOBuildInfo.sdkVersion(of: url) == nil)
        #expect(DuoAppInfo.read(executable: url, plist: ["DTPlatformVersion": "18.2"]).sdkVersion == "18.2")
        let built = try write(versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4))))
        // The executable wins over the plist (which a tweak may have edited).
        #expect(DuoAppInfo.read(executable: built, plist: ["DTPlatformVersion": "27.1"]).sdkVersion == "26.4")
    }

    @Test func readsEverySliceOfARealFatBinary() throws {
        let slices = try MachOBuildInfo.slices(of: machO("duo-objc-fat"))
        #expect(slices.map(\.archName) == ["arm64", "arm64e"])
        #expect(slices.allSatisfy { $0.sdk == "26.4" && $0.minOS == "15.0" && $0.platform == 2 })
    }

    @Test func supportsTheDuoFrom27_1() {
        #expect(!DuoCompatibility.supportsDuo(sdk: "26.4"))
        #expect(!DuoCompatibility.supportsDuo(sdk: "27.0"))
        #expect(DuoCompatibility.supportsDuo(sdk: "27.1"))
        #expect(DuoCompatibility.supportsDuo(sdk: "28"))
        #expect(!DuoCompatibility.supportsDuo(sdk: nil))
    }

    // MARK: Option state

    @Test func optionStateMatrix() {
        #expect(DuoCompatibility.optionState(isDuo: false, app: plain) == .notADuo)
        #expect(DuoCompatibility.optionState(isDuo: true, app: plain) == .recommended)
        let recent = DuoAppInfo(sdkVersion: "27.1", adoptsScenes: true, sceneDelegateClass: nil)
        #expect(DuoCompatibility.optionState(isDuo: true, app: recent) == .alreadySupported)
        #expect(DuoCompatibility.optionState(isDuo: false, app: recent) == .alreadySupported)
        let noScenes = DuoAppInfo(sdkVersion: "26.4", adoptsScenes: false, sceneDelegateClass: nil)
        // No scene support of its own: offered like any other (XSide's module adapts it).
        #expect(DuoCompatibility.optionState(isDuo: true, app: noScenes) == .recommended)
        #expect(DuoCompatibility.optionState(isDuo: false, app: noScenes) == .notADuo)
        // Morning review M4: a build without the compatibility module can't do it for such an app.
        #expect(DuoCompatibility.optionState(isDuo: true, app: noScenes, legacyModuleAvailable: false) == .unavailable)
        #expect(DuoCompatibility.optionState(isDuo: false, app: noScenes, legacyModuleAvailable: false) == .unavailable)
        #expect(!DuoCompatibility.OptionState.unavailable.canTurnOn)
        #expect(DuoCompatibility.optionState(isDuo: true, app: plain, legacyModuleAvailable: false) == .recommended)
        #expect(noScenes.needsLegacyModule)
        #expect(!plain.needsLegacyModule)
        // An app that already declares its scenes only needs the SDK raised.
        let manifest = DuoAppInfo(sdkVersion: "26.4", adoptsScenes: true, sceneDelegateClass: nil)
        #expect(DuoCompatibility.optionState(isDuo: true, app: manifest) == .recommended)
        // Unknown (an app imported by an older XSide): offered, never recommended.
        #expect(DuoCompatibility.optionState(isDuo: true, app: nil) == .unknown)
        #expect(DuoCompatibility.optionState(isDuo: false, app: nil) == .notADuo)
        #expect(DuoCompatibility.OptionState.recommended.canTurnOn)
        #expect(DuoCompatibility.OptionState.notADuo.canTurnOn)
        #expect(DuoCompatibility.OptionState.unknown.canTurnOn)
        #expect(!DuoCompatibility.OptionState.alreadySupported.canTurnOn)
    }

    /// Which way the option brings scenes: the app's manifest, its own delegate, or XSide's module.
    @Test func sceneSupportDecidesTheModule() {
        #expect(DuoCompatibility.sceneSupport(for: plain) == .ownSceneDelegate("YTSceneDelegate"))
        #expect(DuoCompatibility.sceneSupport(for: DuoAppInfo(sdkVersion: "26.4", adoptsScenes: true, sceneDelegateClass: nil))
                == .ownManifest)
        // A manifest wins over a found class: it already runs with scenes.
        #expect(DuoCompatibility.sceneSupport(for: DuoAppInfo(sdkVersion: "26.4", adoptsScenes: true, sceneDelegateClass: "X"))
                == .ownManifest)
        #expect(DuoCompatibility.sceneSupport(for: DuoAppInfo(sdkVersion: "26.4", adoptsScenes: false, sceneDelegateClass: nil))
                == .legacyModule)
        #expect(DuoCompatibility.sceneSupport(for: DuoAppInfo(sdkVersion: "27.1", adoptsScenes: false, sceneDelegateClass: nil)) == nil)
        #expect(DuoCompatibility.sceneSupport(for: DuoAppInfo(sdkVersion: nil, adoptsScenes: false, sceneDelegateClass: nil))
                == .legacyModule)
    }

    @Test func manifestNamesTheRightDelegate() {
        #expect(DuoCompatibility.manifestDelegate(for: .ownManifest) == nil)
        #expect(DuoCompatibility.manifestDelegate(for: .ownSceneDelegate("YTSceneDelegate")) == "YTSceneDelegate")
        #expect(DuoCompatibility.manifestDelegate(for: .legacyModule) == "XSDuoSceneDelegate")
        #expect(DuoCompatibility.legacyLoadPath == "@executable_path/Frameworks/XSideDuoLegacy.dylib")
        #expect(DuoOutcome.addedWithModule.isAdded && DuoOutcome.added.isAdded)
        #expect(!DuoOutcome.notPossible.isAdded && !DuoOutcome.failed.isAdded && !DuoOutcome.alreadySupported.isAdded)
    }

    // MARK: Info.plist

    @Test func infoPlistGetsTheSDKAndAManifestNamingTheAppsDelegate() throws {
        var plist: [String: Any] = ["DTPlatformVersion": "26.4", "DTSDKName": "iphoneos26.4", "CFBundleName": "Demo"]
        DuoCompatibility.applyInfoPlist(&plist, sceneDelegateClass: "YTSceneDelegate")
        #expect(plist["DTPlatformVersion"] as? String == "27.1")
        #expect(plist["DTSDKName"] as? String == "iphoneos27.1")
        let manifest = try #require(plist["UIApplicationSceneManifest"] as? [String: Any])
        #expect(manifest["UIApplicationSupportsMultipleScenes"] as? Bool == false)
        let configs = try #require(manifest["UISceneConfigurations"] as? [String: Any])
        let app = try #require(configs["UIWindowSceneSessionRoleApplication"] as? [[String: Any]])
        #expect(app.count == 1)
        #expect(app[0]["UISceneConfigurationName"] as? String == "Default")
        #expect(app[0]["UISceneDelegateClassName"] as? String == "YTSceneDelegate")
        #expect(plist["CFBundleName"] as? String == "Demo")
    }

    @Test func anExistingManifestIsLeftAlone() {
        let own: [String: Any] = ["UIApplicationSupportsMultipleScenes": true]
        var plist: [String: Any] = ["UIApplicationSceneManifest": own]
        DuoCompatibility.applyInfoPlist(&plist, sceneDelegateClass: "Other")
        #expect((plist["UIApplicationSceneManifest"] as? [String: Any])?["UIApplicationSupportsMultipleScenes"] as? Bool == true)
        #expect((plist["UIApplicationSceneManifest"] as? [String: Any])?["UISceneConfigurations"] == nil)
        #expect(plist["DTPlatformVersion"] as? String == "27.1")
    }

    @Test func noManifestWithoutADelegate() {
        var plist: [String: Any] = [:]
        DuoCompatibility.applyInfoPlist(&plist, sceneDelegateClass: nil)
        #expect(plist["UIApplicationSceneManifest"] == nil)
    }

    // MARK: vtool

    @Test func vtoolKeepsTheMinimumOSOfASingleSlice() {
        let slices = [MachOBuildInfo.Slice(cpuType: 0x0100000C, cpuSubtype: 0, platform: 2, minOS: "15.0", sdk: "26.4")]
        let calls = DuoCompatibility.vtoolCalls(input: "/w/App", output: "/w/App.duo", slices: slices, temp: { "/w/t\($0)" })
        #expect(calls == [["vtool", "-set-build-version", "ios", "15.0", "27.1", "-replace", "-output", "/w/App.duo", "/w/App"]])
    }

    @Test func vtoolGoesSliceBySliceWhenTheMinimumsDiffer() {
        let slices = [MachOBuildInfo.Slice(cpuType: 0x0100000C, cpuSubtype: 0, platform: 2, minOS: "15.0", sdk: "26.4"),
                      MachOBuildInfo.Slice(cpuType: 0x0100000C, cpuSubtype: 2, platform: 2, minOS: "16.0", sdk: "26.4")]
        let calls = DuoCompatibility.vtoolCalls(input: "/w/App", output: "/w/App.duo", slices: slices, temp: { "/w/t\($0)" })
        #expect(calls == [
            ["vtool", "-arch", "arm64", "-set-build-version", "ios", "15.0", "27.1", "-replace", "-output", "/w/t0", "/w/App"],
            ["vtool", "-arch", "arm64e", "-set-build-version", "ios", "16.0", "27.1", "-replace", "-output", "/w/App.duo", "/w/t0"],
        ])
    }

    @Test func vtoolRefusesWhatIsntAnIOSSlice() {
        let mac = [MachOBuildInfo.Slice(cpuType: 0x0100000C, cpuSubtype: 0, platform: 1, minOS: "14.0", sdk: "15.0")]
        #expect(DuoCompatibility.vtoolCalls(input: "a", output: "b", slices: mac, temp: { "\($0)" }) == nil)
        let unknown = [MachOBuildInfo.Slice(cpuType: 0x0100000C, cpuSubtype: 0, platform: nil, minOS: nil, sdk: nil)]
        #expect(DuoCompatibility.vtoolCalls(input: "a", output: "b", slices: unknown, temp: { "\($0)" }) == nil)
        // LC_VERSION_MIN_IPHONEOS (no platform field) is iOS.
        let old = [MachOBuildInfo.Slice(cpuType: 0x0100000C, cpuSubtype: 0, platform: nil, minOS: "12.0", sdk: "14.5")]
        #expect(DuoCompatibility.vtoolCalls(input: "a", output: "b", slices: old, temp: { "\($0)" })?.first?[3] == "12.0")
    }

    @Test func bytesTheNewVersionCommandNeeds() throws {
        // LC_BUILD_VERSION with a tool (32 bytes) becomes one without (24): nothing more.
        let built = try write(versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4))))
        #expect(try MachOBuildInfo.versionCommandGrowth(of: built) == 0)
        // LC_VERSION_MIN_IPHONEOS (16) becomes LC_BUILD_VERSION (24).
        let old = try write(versionedMachO(versionMin: (packed(12, 0), packed(14, 5))))
        #expect(try MachOBuildInfo.versionCommandGrowth(of: old) == 8)
    }

    // MARK: Room and rpaths

    @Test func freeSpaceIsWhatLiesBeforeTheFirstSection() throws {
        let url = try write(versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4)), padding: 40))
        #expect(try MachOPatcher.freeSpace(in: url) == 40)
    }

    @Test func stripsOnlyTheBuildMacToolchainRpaths() throws {
        let toolchain = "/private/var/select/developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/iphoneos"
        let link = "/var/db/xcode_select_link/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphoneos"
        let url = try write(versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4)),
                                           rpaths: [toolchain, "@executable_path/Frameworks", link, "/usr/lib/swift"],
                                           padding: 16))
        let before = try MachOPatcher.freeSpace(in: url)
        let removed = try MachOPatcher.removeRpaths(from: url, where: DuoCompatibility.isBuildMacToolchainPath)
        #expect(removed == [toolchain, link])
        #expect(try MachOPatcher.rpaths(in: url) == ["@executable_path/Frameworks", "/usr/lib/swift"])
        #expect(try MachOPatcher.freeSpace(in: url) > before)
        // Still a valid binary: its version is read as before.
        #expect(MachOBuildInfo.sdkVersion(of: url) == "26.4")
        #expect(try MachOPatcher.removeRpaths(from: url, where: DuoCompatibility.isBuildMacToolchainPath).isEmpty)
    }

    @Test func strippingKeepsTheFileSizeWhenTheHeaderClaimsMoreThanItsCommands() throws {
        // sizeofcmds larger than the commands it holds (accepted by the parser): the bytes after
        // the commands must not move, nor the file shrink (duo review, important 3).
        let toolchain = "/private/var/select/developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/iphoneos"
        var d = versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4)), rpaths: [toolchain], padding: 64)
        let sizeofcmds = MachOPatcher.u32(d, 20)
        withUnsafeBytes(of: (sizeofcmds + 32).littleEndian) { d.replaceSubrange(20..<24, with: $0) }
        let url = try write(d)
        let removed = try MachOPatcher.removeRpaths(from: url, where: DuoCompatibility.isBuildMacToolchainPath)
        #expect(removed == [toolchain])
        let after = try Data(contentsOf: url)
        #expect(after.count == d.count)
        #expect(after.suffix(16) == Data(repeating: 0xAB, count: 16)) // the section, where it was
        #expect(MachOPatcher.u32(after, 20) == sizeofcmds + 32 - 112) // the rpath command's 112 bytes freed
        #expect(MachOBuildInfo.sdkVersion(of: url) == "26.4")
    }

    @Test func strippingAppliesOncePerSliceEvenWhenTheFatHeaderRepeatsIt() throws {
        func be32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        let toolchain = "/private/var/select/developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/iphoneos"
        let slice = versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4)),
                                   rpaths: [toolchain, "@executable_path/Frameworks"], padding: 64)
        var fat = Data()
        be32(0xCAFE_BABE, &fat); be32(2, &fat)
        for _ in 0..<2 { be32(0x0100_000C, &fat); be32(0, &fat); be32(4096, &fat); be32(UInt32(slice.count), &fat); be32(12, &fat) }
        fat.append(Data(count: 4096 - fat.count)); fat.append(slice)
        let url = try write(fat)
        let removed = try MachOPatcher.removeRpaths(from: url, where: DuoCompatibility.isBuildMacToolchainPath)
        #expect(removed == [toolchain])
        let after = try Data(contentsOf: url)
        #expect(after.count == fat.count)
        #expect(MachOPatcher.u32(after, 4096 + 16) == MachOPatcher.u32(slice, 16) - 1)
        #expect(MachOPatcher.u32(after, 4096 + 20) == MachOPatcher.u32(slice, 20) - 112)
        #expect(try MachOPatcher.rpaths(in: url) == ["@executable_path/Frameworks"])
    }

    @Test func toolchainPathsAreOnlyTheKnownOnes() {
        #expect(DuoCompatibility.isBuildMacToolchainPath("/private/var/select/developer_dir/x"))
        #expect(DuoCompatibility.isBuildMacToolchainPath("/var/db/xcode_select_link/Toolchains/x"))
        #expect(!DuoCompatibility.isBuildMacToolchainPath("/usr/lib/swift"))
        #expect(!DuoCompatibility.isBuildMacToolchainPath("@executable_path/Frameworks"))
        #expect(!DuoCompatibility.isBuildMacToolchainPath("/Applications/Xcode.app/Contents/Developer"))
    }

    @Test func stripsTheRpathOfARealFatBinary() throws {
        let url = try copy("duo-objc-fat")
        let size = try Data(contentsOf: url).count
        let removed = try MachOPatcher.removeRpaths(from: url, where: DuoCompatibility.isBuildMacToolchainPath)
        #expect(removed.count == 1) // the arm64 slice's; the arm64e one has none
        #expect(try Data(contentsOf: url).count == size)
        #expect(try MachOPatcher.rpaths(in: url) == ["@executable_path/Frameworks"])
        #expect(try MachOBuildInfo.slices(of: url).count == 2)
    }

    // MARK: Scene delegate scan

    @Test func findsTheObjCSceneDelegate() throws {
        // FXBaseSceneDelegate conforms; FXHelper conforms but isn't named so; FXNotASceneDelegate
        // doesn't conform. Both slices (arm64 and arm64e pointers) give the same answer.
        let classes = try ObjCClassScanner.classes(in: machO("duo-objc-fat"))
        #expect(classes.contains { $0.name == "FXBaseSceneDelegate" && $0.conformsToWindowSceneDelegate })
        #expect(classes.contains { $0.name == "FXHelper" && $0.conformsToWindowSceneDelegate })
        #expect(classes.contains { $0.name == "FXAppDelegate" && !$0.conformsToWindowSceneDelegate })
        #expect(ObjCClassScanner.sceneDelegateClass(in: machO("duo-objc-fat")) == "FXBaseSceneDelegate")
        for arch in ["arm64", "arm64e"] {
            #expect(try ObjCClassScanner.classes(in: machO("duo-objc-fat"), arch: arch).map(\.name).sorted()
                    == ["FXAppDelegate", "FXBaseSceneDelegate", "FXHelper", "FXNotASceneDelegate"])
        }
    }

    @Test func findsTheSwiftSceneDelegateByItsRuntimeName() throws {
        // A Swift class without @objc(name) is known to the runtime by its mangled name, which
        // NSClassFromString (and so the manifest) accepts. FXOtherSceneDelegate doesn't conform.
        #expect(ObjCClassScanner.sceneDelegateClass(in: machO("duo-swift-arm64")) == "_TtC4main16AppSceneDelegate")
        let classes = try ObjCClassScanner.classes(in: machO("duo-swift-arm64"))
        #expect(classes.contains { $0.name == "FXOtherSceneDelegate" && !$0.conformsToWindowSceneDelegate })
    }

    @Test func theAnswerMustHoldInEverySlice() throws {
        // A fat file whose arm64 slice has FXBaseSceneDelegate and whose other slice (the Swift
        // fixture, labelled arm64e) has another one: the device may run either, no common answer.
        func be32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        let objc = try Data(contentsOf: machO("duo-objc-fat"))
        let arm64 = try IPAInspector.sliceOffsets(objc).first { MachOPatcher.u32(objc, $0 + 8) & 0xFF == 0 }!
        // The slice's size: the fat entry's (big-endian) at +12 of its arch record.
        let n = Int(objc[4..<8].reduce(0) { $0 << 8 | UInt32($1) })
        let entry = (0..<n).map { 8 + $0 * 20 }.first { e in objc[e + 8..<e + 12].reduce(0) { $0 << 8 | Int($1) } == arm64 }!
        let size = objc[entry + 12..<entry + 16].reduce(0) { $0 << 8 | Int($1) }
        let first = objc.subdata(in: arm64..<arm64 + size)
        var second = try Data(contentsOf: machO("duo-swift-arm64"))
        second[8] = 2 // its own header says arm64e too
        let align = 16384
        let firstAt = align, secondAt = (firstAt + first.count + align - 1) / align * align
        var fat = Data()
        be32(0xCAFE_BABE, &fat); be32(2, &fat)
        for (at, d, subtype) in [(firstAt, first, UInt32(0)), (secondAt, second, UInt32(2))] {
            be32(0x0100_000C, &fat); be32(subtype, &fat); be32(UInt32(at), &fat); be32(UInt32(d.count), &fat); be32(14, &fat)
        }
        fat.append(Data(count: firstAt - fat.count)); fat.append(first)
        fat.append(Data(count: secondAt - fat.count)); fat.append(second)
        let url = try write(fat)
        #expect(try ObjCClassScanner.classes(in: url, arch: "arm64").contains { $0.name == "FXBaseSceneDelegate" })
        #expect(try ObjCClassScanner.classes(in: url, arch: "arm64e").contains { $0.name == "_TtC4main16AppSceneDelegate" })
        #expect(ObjCClassScanner.sceneDelegateClass(in: url) == nil)
        // The same slice twice: one answer.
        var twice = Data()
        be32(0xCAFE_BABE, &twice); be32(2, &twice)
        for subtype in [UInt32(0), 2] {
            be32(0x0100_000C, &twice); be32(subtype, &twice); be32(UInt32(firstAt), &twice); be32(UInt32(first.count), &twice); be32(14, &twice)
        }
        twice.append(Data(count: firstAt - twice.count)); twice.append(first)
        #expect(ObjCClassScanner.sceneDelegateClass(in: try write(twice)) == "FXBaseSceneDelegate")
    }

    @Test func noSceneDelegateInABinaryWithoutClasses() throws {
        let url = try write(versionedMachO(buildVersion: (2, packed(15, 0), packed(26, 4))))
        #expect(ObjCClassScanner.sceneDelegateClass(in: url) == nil)
        #expect(ObjCClassScanner.sceneDelegateClass(in: try write(Data("not a binary".utf8))) == nil)
    }

    @Test func choosesAmongCandidates() {
        typealias C = ObjCClassScanner.ClassInfo
        let pick = ObjCClassScanner.choose
        #expect(pick([C(name: "Helper", conformsToWindowSceneDelegate: true, declaresItself: true)]) == nil)
        #expect(pick([C(name: "FooSceneDelegate", conformsToWindowSceneDelegate: false, declaresItself: false)]) == nil)
        // Its own declaration first, then the shortest name, then alphabetical.
        #expect(pick([C(name: "AppSubSceneDelegate", conformsToWindowSceneDelegate: true, declaresItself: false),
                      C(name: "AppLongerSceneDelegate", conformsToWindowSceneDelegate: true, declaresItself: true)])
                == "AppLongerSceneDelegate")
        #expect(pick([C(name: "BSceneDelegate", conformsToWindowSceneDelegate: true, declaresItself: true),
                      C(name: "ASceneDelegate", conformsToWindowSceneDelegate: true, declaresItself: true),
                      C(name: "LongSceneDelegate", conformsToWindowSceneDelegate: true, declaresItself: true)])
                == "ASceneDelegate")
    }

    @Test func appInfoReadsTheDuoFacts() throws {
        let info = DuoAppInfo.read(executable: machO("duo-objc-fat"), plist: [:])
        #expect(info == DuoAppInfo(sdkVersion: "26.4", adoptsScenes: false, sceneDelegateClass: "FXBaseSceneDelegate"))
        let scenes = DuoAppInfo.read(executable: machO("duo-swift-arm64"),
                                     plist: ["UIApplicationSceneManifest": ["UIApplicationSupportsMultipleScenes": false]])
        #expect(scenes.adoptsScenes)
    }

    // MARK: Real vtool (skipped without Xcode)

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/usr/bin/xcrun") && DuoCompatibilityTests.hasVtool))
    func realVtoolRaisesTheSDK() async throws {
        let url = try copy("duo-objc-fat")
        let out = url.appendingPathExtension("duo")
        let slices = try MachOBuildInfo.slices(of: url)
        let calls = try #require(DuoCompatibility.vtoolCalls(input: url.path, output: out.path, slices: slices,
                                                             temp: { url.path + ".t\($0)" }))
        for call in calls {
            let r = try await ProcessRunner().run("/usr/bin/xcrun", call, cwd: nil)
            #expect(r.status == 0)
        }
        let after = try MachOBuildInfo.slices(of: out)
        #expect(after.map(\.sdk) == ["27.1", "27.1"])
        #expect(after.map(\.minOS) == ["15.0", "15.0"])
        #expect(ObjCClassScanner.sceneDelegateClass(in: out) == "FXBaseSceneDelegate")
    }

    static var hasVtool: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["-f", "vtool"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }
}
