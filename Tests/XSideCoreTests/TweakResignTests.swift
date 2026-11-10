import Foundation
import Testing
@testable import XSideCore

private let ok = CommandResult(status: 0, stdout: Data(), stderr: "")
private let team = "TEAM123456"
private let substrate = "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
private let cephei = "/Library/Frameworks/Cephei.framework/Cephei"
private let cepheiFile = "Library/Frameworks/Cephei.framework/Cephei"
private let dylibFolder = "Library/MobileSubstrate/DynamicLibraries/"
private let appID = "com.example.app"

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

private func plist(_ app: URL) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")),
                                               format: nil) as! [String: Any]
}

private func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }

/// Thin arm64 executable: a `__TEXT` segment whose section starts `padding` bytes after the load
/// commands, and one `LC_LOAD_WEAK_DYLIB` per path in `loading` (an earlier signing's).
private func executable(padding: Int = 4096, loading: [String] = [], versionMin: Bool = false) -> Data {
    var commands = Data()
    func le(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    // LC_VERSION_MIN_IPHONEOS: iOS 15.0, SDK 17.0 (16 bytes; the Duo patch's LC_BUILD_VERSION takes 24).
    if versionMin { for v in [UInt32(0x25), 16, packed(15, 0), packed(17, 0)] { le(v, &commands) } }
    for path in loading { commands.append(MachOPatcher.dylibCommand(path)) }
    let segmentSize = 72 + 80
    let sizeofcmds = segmentSize + commands.count
    let sectionOffset = 32 + sizeofcmds + padding
    var d = Data()
    func h32(_ v: UInt32) { le(v, &d) }
    func h64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func name16(_ s: String) { var b = Array(s.utf8); b += Array(repeating: 0, count: 16 - b.count); d.append(contentsOf: b) }
    h32(0xFEEDFACF); h32(0x0100000C); h32(0); h32(2)
    h32(UInt32(1 + loading.count + (versionMin ? 1 : 0))); h32(UInt32(sizeofcmds)); h32(0); h32(0)
    h32(0x19); h32(UInt32(segmentSize)); name16("__TEXT")
    h64(0x100000000); h64(UInt64(sectionOffset + 16)); h64(0); h64(UInt64(sectionOffset + 16))
    h32(5); h32(5); h32(1); h32(0)
    name16("__text"); name16("__TEXT"); h64(0x100000000 + UInt64(sectionOffset)); h64(16)
    h32(UInt32(sectionOffset)); h32(2); for _ in 0..<6 { h32(0) }
    d.append(commands)
    d.append(Data(count: sectionOffset - d.count))
    d.append(Data(repeating: 0xAB, count: 16))
    return d
}

private func realExecutable(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/macho/\(name)"))
}

private func arm64(_ minOS: String = "15.0") -> TweakSlice { TweakSlice(arch: "arm64", platform: 2, minOS: minOS) }

/// A stored package and its files' bytes.
private struct Stored {
    var package: TweakPackage
    var files: [String: Data]
}

/// A `.deb` tweak with one entry `<name>.dylib` (and its filter plist), linking `linked`.
private func tweak(_ id: String, name: String = "Example", linked: [String] = ["/usr/lib/libobjc.A.dylib"],
                   filter: TweakFilter? = TweakFilter(bundles: [appID]), depends: [[DebDependency]] = [],
                   mentions: Bool = false, slices: [TweakSlice] = [arm64()], binary: Data? = nil,
                   extraFiles: [String: Data] = [:]) -> Stored {
    let path = dylibFolder + name + ".dylib"
    let entry = TweakBinary(path: path, isEntry: true, filter: filter, slices: slices, linked: linked,
                            mentionsJailbreakPaths: mentions, imageName: name + ".dylib")
    var files: [String: Data] = [path: binary ?? FakeIPA.dylibMachO(linking: linked, padding: 512)]
    files[dylibFolder + name + ".plist"] = Data("{ Filter = { Bundles = ( \"\(appID)\" ); }; }".utf8)
    files.merge(extraFiles) { _, new in new }
    let package = TweakPackage(id: id, kind: .deb, origin: .added, packageID: "com.example." + name.lowercased(),
                               name: name, version: "1.0", depends: depends, files: files.keys.sorted(),
                               binaries: [entry], addedAt: Date(timeIntervalSince1970: 1_800_000_000))
    return Stored(package: package, files: files)
}

/// Cephei as a library package: XSide's (`origin: .embedded`) or one the person added.
private func cepheiPackage(id: String = "ws.hbang.common", origin: TweakOrigin = .embedded, version: String = "2.0") -> Stored {
    let bin = TweakBinary(path: cepheiFile, isEntry: false, filter: nil, slices: [arm64()],
                          linked: ["/System/Library/Frameworks/Foundation.framework/Foundation"],
                          mentionsJailbreakPaths: false, imageName: "Cephei")
    let package = TweakPackage(id: id, kind: .deb, origin: origin, packageID: "ws.hbang.common", name: "Cephei",
                               version: version, files: [cepheiFile], binaries: [bin],
                               addedAt: Date(timeIntervalSince1970: 1_800_000_000))
    return Stored(package: package, files: [cepheiFile: FakeIPA.dylibMachO(linking: bin.linked, padding: 512)])
}

private actor Reports {
    var all: [TweakSigningReport?] = []
    func add(_ r: TweakSigningReport?) { all.append(r) }
    var last: TweakSigningReport? { all.last ?? nil }
}

private actor Outcomes {
    var all: [DuoOutcome] = []
    func add(_ o: DuoOutcome) { all.append(o) }
}

private actor Order {
    var items: [String] = []
    func add(_ s: String) { items.append(s) }
}

/// A runner that fails `codesign` for a path containing `failing`, recording every call.
private struct FailingSigner: CommandRunning {
    let fake: FakeRunner
    let failing: String
    func run(_ executable: String, _ arguments: [String], cwd: URL?, timeout: Duration) async throws -> CommandResult {
        if executable == "/usr/bin/codesign", arguments.last?.contains(failing) == true {
            _ = try await fake.run(executable, arguments, cwd: cwd, timeout: timeout)
            return CommandResult(status: 1, stdout: Data(), stderr: "bad")
        }
        return try await RoutingRunner(fake: fake).run(executable, arguments, cwd: cwd, timeout: timeout)
    }
}

/// `codesign` for real (ad hoc with identity "-"), `xcrun` to the fake.
private struct RealSigner: CommandRunning {
    let fake: FakeRunner
    func run(_ executable: String, _ arguments: [String], cwd: URL?, timeout: Duration) async throws -> CommandResult {
        if executable == "/usr/bin/codesign" {
            _ = try await fake.run(executable, arguments, cwd: cwd, timeout: timeout)
            return try await ProcessRunner().run(executable, arguments, cwd: cwd, timeout: timeout)
        }
        return try await RoutingRunner(fake: fake).run(executable, arguments, cwd: cwd, timeout: timeout)
    }
}

/// An IPA, XSide's libraries, a folder of stored tweaks and the catalog of embedded dependencies.
private struct TweakFixture {
    let ipa: URL, work: URL, profileURL: URL, store: URL, deps: URL
    let fake = FakeRunner()
    let welcome: URL?, iCloud: URL?, elleKit: URL?, license: URL?, support: URL?, legacy: URL?
    var failingSign: String?
    var realSigning = false
    /// Gives the resigner a Settings section and a payload, as XSide.app does.
    var settings = false

    init(executable exe: Data = executable(), withModule: Bool = true, withICloud: Bool = false,
         withElleKit: Bool = true, withSupport: Bool = true, embedded: [Stored] = [cepheiPackage()],
         appFiles: [String: Data] = [:], plistExtras: [String: Any] = ["CFBundleName": "Demo"]) async throws {
        let src = try tempDir("tweak-src")
        let made = try FakeIPA.makeApp(at: src, bundleID: appID, extensions: [], executableData: exe, plistExtras: plistExtras)
        for (path, data) in appFiles {
            let url = made.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let out = try tempDir("tweak-ipa")
        ipa = out.appendingPathComponent("Demo.ipa")
        let r = try await ProcessRunner().run("/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", "--keepParent", src.appendingPathComponent("Payload").path, ipa.path], cwd: nil)
        #expect(r.status == 0)
        profileURL = out.appendingPathComponent("p.mobileprovision")
        try Data("PROFILE".utf8).write(to: profileURL)
        work = try tempDir("tweak-work")
        store = try tempDir("tweak-store")
        deps = try tempDir("tweak-deps")
        fake.stub("/usr/bin/codesign", result: ok)
        fake.stub("/usr/bin/xcrun", firstArg: "vtool", result: ok) { args in
            guard let i = args.firstIndex(of: "-output"), i + 2 < args.count else { return }
            var data = try! Data(contentsOf: URL(fileURLWithPath: args[i + 2]))
            raiseSDK(&data)
            if !data.isEmpty { try! data.write(to: URL(fileURLWithPath: args[i + 1])) }
        }
        let libs = try tempDir("tweak-libs")
        func lib(_ name: String, _ on: Bool) throws -> URL? {
            guard on else { return nil }
            let url = libs.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return url
        }
        welcome = try lib("XSideWelcome.dylib", withModule)
        iCloud = try lib("XSideICloud.dylib", withICloud)
        elleKit = try lib("ElleKit.dylib", withElleKit)
        license = try lib("ElleKit-LICENSE.txt", withElleKit)
        support = try lib("XSideTweakSupport.dylib", withSupport)
        legacy = try lib("XSideDuoLegacy.dylib", true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for s in embedded {
            let dir = deps.appendingPathComponent(s.package.packageID)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encoder.encode(s.package).write(to: dir.appendingPathComponent("package.json"))
            try write(s.files, in: dir)
        }
    }

    private func write(_ files: [String: Data], in dir: URL) throws {
        for (path, data) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    /// Stores `s` like the library does and returns its signing item.
    func item(_ s: Stored, force: Bool = false) throws -> TweakSigningItem {
        let dir = store.appendingPathComponent(s.package.id)
        try write(s.files, in: dir)
        return TweakSigningItem(package: s.package, directory: dir.path, force: force)
    }

    var resigner: Resigner {
        var section: (@Sendable (ProvisioningProfile, InstallationFacts?) -> SettingsSection)?
        var payload: @Sendable (ProvisioningProfile) -> WelcomePayload? = { _ in nil }
        if settings {
            section = fixtureSection
            payload = fixturePayload
        }
        return Resigner(runner: realSigning ? RealSigner(fake: fake)
                    : failingSign.map { FailingSigner(fake: fake, failing: $0) } ?? RoutingRunner(fake: fake),
                 welcomeDylib: welcome, settingsSection: section, welcome: payload,
                 iCloudLibrary: iCloud, duoLegacyLibrary: legacy,
                 elleKitLibrary: elleKit, elleKitLicense: license, tweakSupportLibrary: support, tweakDependencies: deps)
    }

    func run(_ items: [TweakSigningItem], options: InstallOptions = InstallOptions(), deviceOS: String? = "17.5",
             offHere: [TweakPackage]? = nil,
             reports: Reports? = nil, order: Order? = nil, duo: Outcomes? = nil) async throws -> URL {
        var options = options
        options.tweaks = TweakJob(items: items, deviceOS: deviceOS, offHere: offHere)
        return try await resigner.resign(
            ipa: ipa, workDir: work, bundleID: "com.example.new", options: options, iconURL: nil,
            profileURL: profileURL, profile: profile(), identitySHA1: realSigning ? "-" : "SHA", facts: nil,
            onDuo: { outcome in
                if let outcome { await duo?.add(outcome) } else { await order?.add("duo") }
            },
            onICloud: { await order?.add("icloud") },
            onThinning: { await order?.add("thinning") },
            onSigning: { await order?.add("signing") },
            onTweaks: { report in
                await order?.add(report == nil ? "tweaks" : "tweaks-report")
                await reports?.add(report)
            })
    }
}

private let fixtureSection: @Sendable (ProvisioningProfile, InstallationFacts?) -> SettingsSection = { _, _ in
    SettingsSection.xside(validUntil: "12 nov.", refreshedOn: "5 nov.", version: "1.0", installedOn: "1 nov.")
}

private let fixturePayload: @Sendable (ProvisioningProfile) -> WelcomePayload? = { _ in
    WelcomePayload(thresholdHours: 48, reminderLeadHours: 24,
                   inApp: InAppSettings.defaults(reminder: true, at: Date(timeIntervalSince1970: 0)))
}

/// Sets the SDK of every LC_BUILD_VERSION of a thin or fat binary to 27.1 (what the fake vtool does).
private func raiseSDK(_ data: inout Data) {
    guard let starts = try? IPAInspector.sliceOffsets(data) else { return }
    for start in starts {
        guard let commands = try? MachOPatcher.loadCommands(data, at: start) else { continue }
        // LC_VERSION_MIN_IPHONEOS → LC_BUILD_VERSION: 8 more bytes, taken from the free space
        // (vtool fails without them: nothing is written).
        if let c = commands.first(where: { $0.cmd == 0x25 }) {
            let end = start + 32 + Int(MachOPatcher.u32(data, start + 20))
            guard let first = MachOPatcher.firstSectionOffset(data, start: start, commands: commands),
                  start + first - end >= 8 else { data = Data(); return }
            var build = Data()
            for v in [UInt32(0x32), 24, 2, MachOPatcher.u32(data, c.pos + 8), packed(27, 1), 0] {
                withUnsafeBytes(of: v.littleEndian) { build.append(contentsOf: $0) }
            }
            let tail = data.subdata(in: c.pos + 16..<end)
            data.replaceSubrange(c.pos..<end + 8, with: build + tail)
            withUnsafeBytes(of: (MachOPatcher.u32(data, start + 20) + 8).littleEndian) { data.replaceSubrange(start + 20..<start + 24, with: $0) }
            continue
        }
        for c in commands where c.cmd == 0x32 {
            withUnsafeBytes(of: packed(27, 1).littleEndian) { data.replaceSubrange(c.pos + 16..<c.pos + 20, with: $0) }
        }
    }
}

private func loads(_ app: URL) throws -> [String] {
    try MachOPatcher.linkedDylibs(in: app.appendingPathComponent("Demo"))
}

private func tweakFile(_ app: URL, _ s: Stored, _ path: String? = nil) -> URL {
    app.appendingPathComponent(TweakLayout.folder + "/" + TweakLayout.directory(s.package) + "/"
                               + (path ?? s.package.binaries[0].path))
}

private func entryPath(_ s: Stored) -> String { TweakLayout.loadPath(s.package, s.package.binaries[0]) }

private let idA = "aaaaaaaaaaaaaaa1", idB = "bbbbbbbbbbbbbbb2", idC = "ccccccccccccccc3"

struct TweakResignTests {
    @Test func orderIsThinningDuoICloudTweaksModule() async throws {
        let f = try await TweakFixture(withICloud: true)
        let a = tweak(idA, name: "Alpha", mentions: true), b = tweak(idB, name: "Beta")
        let reports = Reports()
        let app = try await f.run([try f.item(a), try f.item(b)], options: InstallOptions(iCloudSignedOut: true), reports: reports)
        let names = try loads(app)
        #expect(Array(names.suffix(5)) == [ICloudSignedOut.loadPath, TweakLayout.supportLoadPath, entryPath(a), entryPath(b),
                                           Resigner.welcomeLoadPath])
        let r = await reports.all
        #expect(r.count == 2 && r[0] == nil)
        #expect(r.last??.results == [idA: .injected(converted: true), idB: .injected(converted: false)])
    }

    @Test func withDuoEachIsPresentOnceAndTheStepsRunInOrder() async throws {
        let thin = try realExecutable("duo-swift-arm64")
        let fat = FakeIPA.fat([(12, 9, FakeIPA.machO(cpuType: 12, cryptid: 0)), (0x0100000C, 0, thin)])
        let f = try await TweakFixture(executable: fat, withICloud: true,
                                       plistExtras: ["CFBundleName": "Demo", "DTPlatformVersion": "26.4"])
        let a = tweak(idA, name: "Alpha", linked: [substrate], mentions: true)
        let order = Order()
        let app = try await f.run([try f.item(a)], options: InstallOptions(duoCompatibility: true, iCloudSignedOut: true),
                                  order: order)
        #expect(MachOBuildInfo.sdkVersion(of: app.appendingPathComponent("Demo")) == "27.1")
        let names = try loads(app)
        for path in [Resigner.welcomeLoadPath, ICloudSignedOut.loadPath, TweakLayout.elleKitLoadPath,
                     TweakLayout.supportLoadPath, entryPath(a)] {
            #expect(names.filter { $0 == path }.count == 1, "\(path)")
        }
        #expect(await order.items == ["thinning", "duo", "icloud", "tweaks", "tweaks-report", "signing"])
    }

    @Test func aCompatibleTweakIsCopiedAndLoadedWeakly() async throws {
        let f = try await TweakFixture()
        let a = tweak(idA)
        let reports = Reports()
        let app = try await f.run([try f.item(a)], reports: reports)
        #expect(FileManager.default.contents(atPath: tweakFile(app, a).path) == a.files[a.package.binaries[0].path])
        #expect(exists(tweakFile(app, a, dylibFolder + "Example.plist")))
        let data = try Data(contentsOf: app.appendingPathComponent("Demo"))
        let commands = try MachOPatcher.loadCommands(data, at: 0)
        let tweakCommand = commands.first { MachOPatcher.dylibName(data, $0) == entryPath(a) }
        #expect(tweakCommand?.cmd == MachOPatcher.loadWeakDylib)
        #expect(await reports.last == TweakSigningReport(results: [idA: .injected(converted: false)], embedded: [],
                                                         injected: [InjectedTweak(a.package, conversions: nil)]))
        // Nothing needs ElleKit or the support library: neither is there.
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder + "/" + TweakLayout.elleKitName)))
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder + "/" + TweakLayout.supportName)))
        #expect(try plist(app)[TweakLayout.pathsKey] == nil)
        // The tweak is signed, and the app last.
        #expect(f.fake.calls.contains { $0.first == "/usr/bin/codesign" && $0.last == tweakFile(app, a).path })
        #expect(f.fake.calls.last?.last == app.path)
    }

    @Test func substrateIsRewrittenToElleKit() async throws {
        let f = try await TweakFixture()
        let a = tweak(idA, linked: [substrate, "/usr/lib/libobjc.A.dylib"])
        let reports = Reports()
        let app = try await f.run([try f.item(a)], reports: reports)
        let linked = try MachOPatcher.linkedDylibs(in: tweakFile(app, a))
        #expect(linked == [TweakLayout.elleKitLoadPath, "/usr/lib/libobjc.A.dylib"])
        let folder = app.appendingPathComponent(TweakLayout.folder)
        #expect(FileManager.default.contents(atPath: folder.appendingPathComponent(TweakLayout.elleKitName).path)
                == Data("ElleKit.dylib".utf8))
        #expect(FileManager.default.contents(atPath: folder.appendingPathComponent(TweakLayout.elleKitLicenseName).path)
                == Data("ElleKit-LICENSE.txt".utf8))
        // C8: ElleKit has its own weak load command, once, before the tweak's.
        let names = try loads(app)
        #expect(names.filter { $0 == TweakLayout.elleKitLoadPath }.count == 1)
        #expect(names.firstIndex(of: TweakLayout.elleKitLoadPath)! < names.firstIndex(of: entryPath(a))!)
        #expect(await reports.last?.results == [idA: .injected(converted: true)])
        #expect(await reports.last?.supportImages == [TweakLayout.elleKitName])
        #expect(await reports.last?.injected.first?.conversions == [.hookingLibrary])
    }

    @Test func noElleKitInThisBuildSkipsTheSubstrateTweakOnly() async throws {
        let f = try await TweakFixture(withElleKit: false)
        let a = tweak(idA, linked: [substrate]), b = tweak(idB, name: "Beta")
        let reports = Reports()
        let app = try await f.run([try f.item(a), try f.item(b)], reports: reports)
        #expect(await reports.last?.results == [idA: .skipped(.incompatible(.missingDependency("ElleKit"))),
                                                idB: .injected(converted: false)])
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder + "/" + idA)))
        #expect(try !loads(app).contains(entryPath(a)))
    }

    @Test func aNeededEmbeddedDependencyIsCopiedAndLinked() async throws {
        let f = try await TweakFixture()
        let a = tweak(idA, linked: [cephei], depends: [[DebDependency(package: "ws.hbang.common")]])
        let reports = Reports()
        let app = try await f.run([try f.item(a)], reports: reports)
        let copied = app.appendingPathComponent(TweakLayout.folder + "/deps/ws.hbang.common/" + cepheiFile)
        #expect(exists(copied))
        let expected = TweakLayout.loadPrefix + "deps/ws.hbang.common/" + cepheiFile
        #expect(try MachOPatcher.linkedDylibs(in: tweakFile(app, a)) == [expected])
        // Only the tweak gets a load command: the dependency is loaded through it.
        #expect(try !loads(app).contains(expected))
        let report = await reports.last
        #expect(report?.embedded == ["ws.hbang.common"])
        #expect(report?.results == [idA: .injected(converted: true)])
        // Named for a crash: the tweak with what was converted, and the dependency's image.
        #expect(report?.injected.map(\.id) == [idA])
        #expect(report?.injected.first?.converted == true)
        #expect(report?.injected.first?.conversions?.contains { if case .dependencyAdded = $0 { true } else { false } } == true)
        #expect(report?.supportImages.contains("Cephei") == true)
    }

    @Test func notCopiedWhenNoTweakNeedsIt() async throws {
        let f = try await TweakFixture()
        let reports = Reports()
        let app = try await f.run([try f.item(tweak(idA))], reports: reports)
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder + "/deps")))
        #expect(await reports.last?.embedded == [])
    }

    @Test func theOnesCopyIsUsedInsteadOfTheEmbeddedOne() async throws {
        let f = try await TweakFixture()
        let a = tweak(idA, linked: [cephei], depends: [[DebDependency(package: "ws.hbang.common")]])
        let theirs = cepheiPackage(id: idB, origin: .added, version: "1.9")
        let reports = Reports()
        let app = try await f.run([try f.item(a), try f.item(theirs)], reports: reports)
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder + "/deps")))
        #expect(exists(tweakFile(app, theirs)))
        #expect(try MachOPatcher.linkedDylibs(in: tweakFile(app, a)) == [TweakLayout.loadPrefix + idB + "/" + cepheiFile])
        let report = await reports.last
        // The person's copy, taken from the pool, is in the app: reported injected (kept by the library).
        #expect(report?.results == [idA: .injected(converted: true), idB: .injected(converted: false)])
        #expect(report?.embedded == [])
    }

    /// Device round 2, item 16: cephei-user (≥ 1.0, links /Library/Frameworks/Cephei…) and
    /// needs-cephei-old (< 2.0) with XSide's 2.0 and the downloaded rootful 1.17.1 (files in
    /// usr/lib) on the device: both use 1.17.1 (it satisfies both; one copy per app), cephei-user
    /// is no longer left out « missing Cephei », and XSide's 2.0 isn't copied.
    @Test func cepheiUserAndNeedsCepheiOldBothUseTheDownloadedCepheiInUsrLib() async throws {
        let f = try await TweakFixture()
        let user = tweak(idA, name: "CepheiUser", linked: [cephei],
                         depends: [[DebDependency(package: "ws.hbang.common", relation: ">=", version: "1.0")]])
        let old = tweak(idB, name: "NeedsOld", depends: [[DebDependency(package: "ws.hbang.common", relation: "<<", version: "2.0")]])
        let usrLib = "usr/lib/Cephei.framework/Cephei"
        let bin = TweakBinary(path: usrLib, isEntry: false, filter: nil, slices: [arm64()],
                              linked: ["/System/Library/Frameworks/Foundation.framework/Foundation"],
                              mentionsJailbreakPaths: false, imageName: "Cephei")
        let c117 = Stored(package: TweakPackage(id: idC, kind: .deb, origin: .added, packageID: "ws.hbang.common",
                                                name: "Cephei Tweak Support", version: "1.17.1", files: [usrLib], binaries: [bin],
                                                addedAt: Date(timeIntervalSince1970: 1_800_000_000)),
                          files: [usrLib: FakeIPA.dylibMachO(linking: bin.linked, padding: 512)])
        let reports = Reports()
        let app = try await f.run([try f.item(user), try f.item(old), try f.item(c117)], reports: reports)
        let report = await reports.last
        #expect(report?.results[idA] == .injected(converted: true))
        #expect(report?.results[idB] == .injected(converted: true))
        #expect(report?.results[idC] == .injected(converted: false))
        #expect(report?.embedded == [])
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder + "/deps")))
        #expect(try MachOPatcher.linkedDylibs(in: tweakFile(app, user)) == [TweakLayout.loadPrefix + idC + "/" + usrLib])
    }

    @Test func whenTheOnesCopyCantBeUsedTheTweakDependingOnItIsSkippedToo() async throws {
        let f = try await TweakFixture(embedded: [])
        let a = tweak(idA, linked: [cephei], depends: [[DebDependency(package: "ws.hbang.common")]])
        let theirs = cepheiPackage(id: idB, origin: .added)
        var broken = try f.item(theirs)
        broken.directory = f.store.appendingPathComponent("gone").path
        let reports = Reports()
        let app = try await f.run([try f.item(a), broken], reports: reports)
        let results = await reports.last?.results
        #expect(results?[idB] == .skipped(.failed))
        if case .injected = results?[idA] { Issue.record("injected without its dependency") }
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder + "/" + idA)))
        #expect(try !loads(app).contains(entryPath(a)))
    }

    @Test func aTweakWhoseProviderFailsToCopyIsLeftOutWithIt() async throws {
        let f = try await TweakFixture(embedded: [])
        let theirs = cepheiPackage(id: idB, origin: .added)
        let a = tweak(idA, linked: [cephei], depends: [[DebDependency(package: "ws.hbang.common")]])
        // The provider's folder is there, its binary is not: found only when copying.
        let damaged = try f.item(theirs)
        try FileManager.default.removeItem(atPath: damaged.directory + "/" + cepheiFile)
        let fine = tweak(idC, name: "Gamma")
        let reports = Reports()
        let app = try await f.run([try f.item(a), damaged, try f.item(fine)], reports: reports)
        #expect(await reports.last?.results == [idA: .skipped(.failed), idB: .skipped(.failed), idC: .injected(converted: false)])
        #expect(try loads(app) == [entryPath(fine), Resigner.welcomeLoadPath])
        #expect(try FileManager.default.contentsOfDirectory(atPath: app.appendingPathComponent(TweakLayout.folder).path) == [idC])
    }

    @Test func theDuoCopysCommandsForLeftOutTweaksAreRemoved() async throws {
        let f = try await TweakFixture(executable: try realExecutable("duo-swift-arm64"),
                                       plistExtras: ["CFBundleName": "Demo", "DTPlatformVersion": "26.4"])
        let a = tweak(idA, name: "Alpha", linked: [substrate]), b = tweak(idB, name: "Beta")
        let broken = try f.item(a)
        try FileManager.default.removeItem(atPath: broken.directory + "/" + a.package.binaries[0].path)
        let reports = Reports()
        let app = try await f.run([broken, try f.item(b)], options: InstallOptions(duoCompatibility: true), reports: reports)
        #expect(MachOBuildInfo.sdkVersion(of: app.appendingPathComponent("Demo")) == "27.1")
        let names = try loads(app)
        #expect(!names.contains(entryPath(a)) && !names.contains(TweakLayout.elleKitLoadPath))
        #expect(names.filter { $0 == entryPath(b) }.count == 1)
        #expect(await reports.last?.results == [idA: .skipped(.failed), idB: .injected(converted: false)])
    }

    @Test func pathConvertedTweakBringsTheSupportFirstAndTheInfoPlistKey() async throws {
        let f = try await TweakFixture()
        let a = tweak(idA, name: "Alpha"), b = tweak(idB, name: "Beta", mentions: true)
        let reports = Reports()
        let app = try await f.run([try f.item(a), try f.item(b)], reports: reports)
        let names = try loads(app)
        let support = try #require(names.firstIndex(of: TweakLayout.supportLoadPath))
        #expect(support < names.firstIndex(of: entryPath(a))!)
        #expect(FileManager.default.contents(atPath: app.appendingPathComponent(TweakLayout.folder + "/" + TweakLayout.supportName).path)
                == Data("XSideTweakSupport.dylib".utf8))
        #expect(try plist(app)[TweakLayout.pathsKey] as? Bool == true)
        #expect(await reports.last?.results == [idA: .injected(converted: false), idB: .injected(converted: true)])
    }

    @Test func noSupportLibraryInThisBuildSkipsThePathTweak() async throws {
        let f = try await TweakFixture(withSupport: false)
        let reports = Reports()
        let app = try await f.run([try f.item(tweak(idA, mentions: true))], reports: reports)
        #expect(await reports.last?.results == [idA: .skipped(.incompatible(.missingDependency("XSideTweakSupport")))])
        #expect(try plist(app)[TweakLayout.pathsKey] == nil)
    }

    @Test func roomRunsOutTweaksLoseFirstAndAreNamed() async throws {
        let a = tweak(idA, name: "Alpha"), b = tweak(idB, name: "Beta1"), c = tweak(idC, name: "Gamma")
        let module = MachOPatcher.dylibCommand(Resigner.welcomeLoadPath).count
        let iCloud = MachOPatcher.dylibCommand(ICloudSignedOut.loadPath).count
        let one = MachOPatcher.dylibCommand(entryPath(a)).count
        // Room for iCloud, XSide's module and one tweak.
        let f = try await TweakFixture(executable: executable(padding: iCloud + module + one + 8), withICloud: true)
        let reports = Reports()
        let app = try await f.run([try f.item(a), try f.item(b), try f.item(c)],
                                  options: InstallOptions(iCloudSignedOut: true), reports: reports)
        let names = try loads(app)
        #expect(names.contains(Resigner.welcomeLoadPath) && names.contains(ICloudSignedOut.loadPath))
        #expect(names.contains(entryPath(a)) && !names.contains(entryPath(b)) && !names.contains(entryPath(c)))
        #expect(await reports.last?.results == [idA: .injected(converted: false), idB: .skipped(.noRoom), idC: .skipped(.noRoom)])
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder + "/" + idB)))
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder + "/" + idC)))
    }

    @Test func roomForTheModuleOnlyKeepsTheModule() async throws {
        let module = MachOPatcher.dylibCommand(Resigner.welcomeLoadPath).count
        let f = try await TweakFixture(executable: executable(padding: module + 8))
        let reports = Reports()
        let a = tweak(idA, linked: [substrate])
        let app = try await f.run([try f.item(a)], reports: reports)
        #expect(try loads(app) == [Resigner.welcomeLoadPath])
        #expect(await reports.last?.results == [idA: .skipped(.noRoom)])
        // Nothing of the tweak step is left: no ElleKit either.
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder)))
    }

    @Test func theSupportLibraryMustFitBeforeAConvertedTweak() async throws {
        let a = tweak(idA, name: "Alpha", mentions: true), b = tweak(idB, name: "Beta1")
        let module = MachOPatcher.dylibCommand(Resigner.welcomeLoadPath).count
        let one = MachOPatcher.dylibCommand(entryPath(a)).count
        // Room for the module and one tweak, not for the support library too.
        let f = try await TweakFixture(executable: executable(padding: module + one + 8))
        let reports = Reports()
        let app = try await f.run([try f.item(a), try f.item(b)], reports: reports)
        #expect(await reports.last?.results == [idA: .skipped(.noRoom), idB: .injected(converted: false)])
        #expect(try !loads(app).contains(TweakLayout.supportLoadPath))
        #expect(try plist(app)[TweakLayout.pathsKey] == nil)
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder + "/" + TweakLayout.supportName)))
    }

    @Test func madeForAnotherAppIsSkippedUnlessForced() async throws {
        let f = try await TweakFixture()
        let other = tweak(idA, filter: TweakFilter(bundles: ["com.other.app"]))
        let reports = Reports()
        let app = try await f.run([try f.item(other)], reports: reports)
        #expect(await reports.last?.results == [idA: .skipped(.incompatible(.madeForAnotherApp(["com.other.app"])))])
        #expect(try !loads(app).contains(entryPath(other)))
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder)))

        let forced = Reports()
        let app2 = try await f.run([try f.item(other, force: true)], reports: forced)
        #expect(await forced.last?.results == [idA: .injected(converted: false)])
        #expect(try loads(app2).contains(entryPath(other)))
    }

    @Test func forceNeverOverridesAJailbreakProblem() async throws {
        let f = try await TweakFixture()
        let sb = tweak(idA, filter: TweakFilter(bundles: ["com.apple.springboard"]))
        let reports = Reports()
        _ = try await f.run([try f.item(sb, force: true)], reports: reports)
        #expect(await reports.last?.results == [idA: .skipped(.incompatible(.needsJailbreak("com.apple.springboard")))])
    }

    @Test func becameIncompatibleIsSkippedAndTheAppStillSigns() async throws {
        let f = try await TweakFixture()
        let newer = tweak(idA, slices: [arm64("18.0")]), fine = tweak(idB, name: "Beta")
        let reports = Reports()
        let app = try await f.run([try f.item(newer), try f.item(fine)], deviceOS: "17.5", reports: reports)
        #expect(await reports.last?.results == [idA: .skipped(.incompatible(.iOSVersion(required: "18.0", device: "17.5"))),
                                                idB: .injected(converted: false)])
        #expect(f.fake.calls.last?.last == app.path)
    }

    @Test func staleTweaksFromAnEarlierSigningGo() async throws {
        let old = TweakLayout.loadPrefix + "0123456789abcdef/" + dylibFolder + "Old.dylib"
        let f = try await TweakFixture(executable: executable(loading: [TweakLayout.elleKitLoadPath, old]),
                                       appFiles: ["Frameworks/XSideTweaks/0123456789abcdef/\(dylibFolder)Old.dylib": Data("OLD".utf8),
                                                  "Frameworks/XSideTweaks/ElleKit.dylib": Data("OLDELLE".utf8)],
                                       plistExtras: ["CFBundleName": "Demo", TweakLayout.pathsKey: true,
                                                     TweakLayout.bundlesKey: ["Old.bundle"]])
        // Without any tweak.
        let app = try await f.resigner.resign(ipa: f.ipa, workDir: f.work, bundleID: "com.example.new", options: InstallOptions(),
                                              iconURL: nil, profileURL: f.profileURL, profile: profile(), identitySHA1: "SHA", facts: nil)
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder)))
        #expect(try loads(app) == [Resigner.welcomeLoadPath])
        let info = try plist(app)
        #expect(info[TweakLayout.pathsKey] == nil && info[TweakLayout.bundlesKey] == nil)

        // With one: only the new one is there.
        let a = tweak(idA)
        let app2 = try await f.run([try f.item(a)])
        #expect(try loads(app2) == [entryPath(a), Resigner.welcomeLoadPath])
        #expect(try FileManager.default.contentsOfDirectory(atPath: app2.appendingPathComponent(TweakLayout.folder).path) == [idA])
    }

    @Test func fatTweakWithArmv7AndX86IsThinnedAndRewritten() async throws {
        let f = try await TweakFixture()
        let arm = FakeIPA.dylibMachO(linking: [substrate], padding: 512)
        var x86 = arm
        withUnsafeBytes(of: UInt32(0x0100_0007).littleEndian) { x86.replaceSubrange(4..<8, with: $0) }
        let fat = FakeIPA.fat([(12, 9, FakeIPA.machO(cpuType: 12, cryptid: 0)), (0x0100_0007, 3, x86), (0x0100_000C, 0, arm)])
        let a = tweak(idA, linked: [substrate], slices: [TweakSlice(arch: "armv7", platform: 2, minOS: "9.0"),
                                                          TweakSlice(arch: "x86_64", platform: 7, minOS: "15.0"), arm64()],
                      binary: fat)
        let reports = Reports()
        let app = try await f.run([try f.item(a)], reports: reports)
        let copied = try Data(contentsOf: tweakFile(app, a))
        #expect(!MachOThinner.headerHasARM32(copied.prefix(8 + 64 * 32)))
        // The x86_64 slice (built for the simulator) goes too: only arm64 is left.
        let starts = try IPAInspector.sliceOffsets(copied)
        #expect(starts == [0] && MachOPatcher.u32(copied, 4) == 0x0100_000C)
        for start in Set(starts) {
            let names = try MachOPatcher.loadCommands(copied, at: start).compactMap { MachOPatcher.dylibName(copied, $0) }
            #expect(names == [TweakLayout.elleKitLoadPath])
        }
        #expect(await reports.last?.results == [idA: .injected(converted: true)])
    }

    @Test func aTweakWhoseRewriteHasNoRoomIsSkippedAsFailed() async throws {
        let f = try await TweakFixture()
        // A short hooking library name and no free space: ElleKit's longer load path can't fit.
        let short = "/usr/lib/libsubstrate.dylib"
        let b = tweak(idB, name: "Beta", linked: [short], binary: FakeIPA.dylibMachO(linking: [short], padding: 0))
        let reports = Reports()
        let app = try await f.run([try f.item(b)], reports: reports)
        #expect(await reports.last?.results == [idB: .skipped(.failed)])
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder)))
        #expect(try loads(app) == [Resigner.welcomeLoadPath])
    }

    @Test func missingStoredFolderIsSkippedAsFailed() async throws {
        let f = try await TweakFixture()
        var gone = try f.item(tweak(idA))
        gone.directory = f.store.appendingPathComponent("nothing-here").path
        let damaged = tweak(idB, name: "Beta")
        let damagedItem = try f.item(damaged)
        try FileManager.default.removeItem(atPath: damagedItem.directory + "/" + damaged.package.binaries[0].path)
        let fine = tweak(idC, name: "Gamma")
        let reports = Reports()
        let app = try await f.run([gone, damagedItem, try f.item(fine)], reports: reports)
        #expect(await reports.last?.results == [idA: .skipped(.failed), idB: .skipped(.failed), idC: .injected(converted: false)])
        #expect(try loads(app) == [entryPath(fine), Resigner.welcomeLoadPath])
    }

    @Test func hostileStoredFilesAreRefused() async throws {
        let f = try await TweakFixture()
        // A file list escaping the folder.
        var escaping = tweak(idA)
        escaping.package.files.append("../../escape")
        let outside = f.store.appendingPathComponent("../escape")
        // A stored file that is a link to something outside.
        let linked = tweak(idB, name: "Beta")
        let linkedItem = try f.item(linked)
        let target = linkedItem.directory + "/" + linked.package.binaries[0].path
        try FileManager.default.removeItem(atPath: target)
        try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: "/etc/hosts")
        // A stored folder that is a link.
        let realDir = try tempDir("tweak-real")
        let c = tweak(idC, name: "Gamma")
        for (path, data) in c.files {
            let url = realDir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let linkDir = f.store.appendingPathComponent("link-\(idC)")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)
        let reports = Reports()
        let app = try await f.run([try f.item(escaping), linkedItem,
                                   TweakSigningItem(package: c.package, directory: linkDir.path, force: false)], reports: reports)
        #expect(await reports.last?.results == [idA: .skipped(.failed), idB: .skipped(.failed), idC: .skipped(.failed)])
        #expect(!exists(outside))
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder)))
        #expect(try loads(app) == [Resigner.welcomeLoadPath])
    }

    @Test func aTweakThatCantBeSignedIsLeftOut() async throws {
        var f = try await TweakFixture()
        f.failingSign = "Beta.dylib"
        let a = tweak(idA, name: "Alpha"), b = tweak(idB, name: "Beta")
        let reports = Reports()
        let app = try await f.run([try f.item(a), try f.item(b)], reports: reports)
        #expect(await reports.last?.results == [idA: .injected(converted: false), idB: .skipped(.failed)])
        #expect(try loads(app) == [entryPath(a), Resigner.welcomeLoadPath])
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder + "/" + idB)))
    }

    @Test func worksWithoutXSidesModule() async throws {
        let f = try await TweakFixture(withModule: false)
        let a = tweak(idA)
        let reports = Reports()
        let app = try await f.run([try f.item(a)], reports: reports)
        #expect(try loads(app) == [entryPath(a)])
        #expect(await reports.last?.results == [idA: .injected(converted: false)])

        // XSide's features off for this app: the tweak still goes in, and only it.
        let g = try await TweakFixture()
        let app2 = try await g.run([try g.item(a)], options: InstallOptions(withoutXSideFeatures: true))
        #expect(try loads(app2) == [entryPath(a)])
    }

    @Test func noTweaksNoStepNoReport() async throws {
        let f = try await TweakFixture()
        let reports = Reports()
        _ = try await f.run([], reports: reports)
        #expect(await reports.all.isEmpty)
    }

    @Test func aDuplicateItemIsInjectedOnce() async throws {
        let f = try await TweakFixture()
        let a = tweak(idA)
        let reports = Reports()
        let app = try await f.run([try f.item(a), try f.item(a)], reports: reports)
        #expect(try loads(app) == [entryPath(a), Resigner.welcomeLoadPath])
        #expect(await reports.last?.results == [idA: .injected(converted: false)])
    }

    @Test func oldOptionsDecodeWithoutTweaks() throws {
        let options = try JSONDecoder().decode(InstallOptions.self, from: Data(#"{"fileSharing":true}"#.utf8))
        #expect(options.tweaks == nil)
    }

    // MARK: fix round 1

    @Test func tweakBundlesAreSignedAsBundlesAfterTheSweep() async throws {
        let binary = try realExecutable("duo-swift-arm64")
        let fwInfo = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "X", "CFBundleIdentifier": "com.example.x"],
                                                        format: .xml, options: 0)
        // Real codesign: the app's own framework must be a real one too.
        var f = try await TweakFixture(executable: binary,
                                       appFiles: ["Frameworks/X.framework/X": binary, "Frameworks/X.framework/Info.plist": fwInfo])
        f.realSigning = true
        let plistData = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Res", "CFBundleIdentifier": "com.example.res"],
                                                       format: .xml, options: 0)
        let bin = TweakBinary(path: "Res.bundle/Res", isEntry: false, filter: nil, slices: [arm64()], linked: [],
                              mentionsJailbreakPaths: false, imageName: "Res")
        let files: [String: Data] = ["Res.bundle/Res": binary, "Res.bundle/Info.plist": plistData, "Res.bundle/a.txt": Data("A".utf8)]
        let bundle = Stored(package: TweakPackage(id: idA, kind: .bundle, origin: .added, packageID: "com.example.res", name: "Res",
                                                  files: files.keys.sorted(), binaries: [bin], addedAt: Date()),
                            files: files)
        let t = tweak(idB, name: "Beta", binary: binary)
        let reports = Reports()
        let app = try await f.run([try f.item(bundle), try f.item(t)], reports: reports)
        #expect(await reports.last?.results == [idA: .injected(converted: false), idB: .injected(converted: false)])
        let folder = app.appendingPathComponent(TweakLayout.folder + "/" + idA + "/Res.bundle")
        #expect(exists(folder.appendingPathComponent("_CodeSignature")))
        let verify = try await ProcessRunner().run("/usr/bin/codesign", ["--verify", "--strict", folder.path], cwd: nil)
        #expect(verify.status == 0, "\(verify.stderr)")
        let whole = try await ProcessRunner().run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], cwd: nil)
        #expect(whole.status == 0, "\(whole.stderr)")
        // The bundle is signed after the binaries in it, before the app.
        let calls = f.fake.calls.map { $0.last ?? "" }
        let last = try #require(calls.lastIndex(of: folder.path))
        #expect(calls.lastIndex(of: folder.appendingPathComponent("Res").path).map { $0 < last } ?? true)
        #expect(calls.last == app.path)
    }

    /// Many tweaks ship a resource-only `<Tweak>.bundle` (no Info.plist): codesign refuses to
    /// sign one as a bundle, so it is left to the app's seal and the tweak still goes in.
    @Test func aResourceOnlyBundleInATweakIsNotSignedAsABundle() async throws {
        let binary = try realExecutable("duo-swift-arm64")
        let fwInfo = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "X", "CFBundleIdentifier": "com.example.x"],
                                                        format: .xml, options: 0)
        var f = try await TweakFixture(executable: binary,
                                       appFiles: ["Frameworks/X.framework/X": binary, "Frameworks/X.framework/Info.plist": fwInfo])
        f.realSigning = true
        let res = tweak(idA, name: "Res", binary: binary,
                        extraFiles: ["Library/Application Support/Res.bundle/icon.png": Data("png".utf8),
                                     "Library/Application Support/Res.bundle/en.lproj/Root.strings": Data("x".utf8)])
        let reports = Reports()
        let app = try await f.run([try f.item(res)], reports: reports)
        let report = await reports.last
        #expect(report?.results == [idA: .injected(converted: true)], "\(String(describing: report))")
        let folder = app.appendingPathComponent(TweakLayout.folder + "/" + idA + "/Library/Application Support/Res.bundle")
        #expect(!f.fake.calls.contains { $0.last == folder.path })
        let whole = try await ProcessRunner().run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], cwd: nil)
        #expect(whole.status == 0, "\(whole.stderr)")
    }

    @Test func hostileIDsAndEmbeddedItemsAreRefused() async throws {
        let f = try await TweakFixture()
        let fine = tweak(idC, name: "Gamma")
        let fineItem = try f.item(fine)
        func renamed(_ id: String, origin: TweakOrigin = .added) -> TweakSigningItem {
            var p = fine.package
            p = TweakPackage(id: id, kind: p.kind, origin: origin, packageID: p.packageID, name: "Hostile", version: p.version,
                             files: p.files, binaries: p.binaries, addedAt: p.addedAt)
            return TweakSigningItem(package: p, directory: fineItem.directory, force: false)
        }
        var embeddedOrigin = cepheiPackage()
        embeddedOrigin.package = TweakPackage(id: "ws.hbang.common", kind: .deb, origin: .embedded, packageID: "ws.hbang.common",
                                              name: "Cephei", files: fine.package.files, binaries: fine.package.binaries,
                                              addedAt: Date())
        let a = tweak(idA, linked: [cephei], depends: [[DebDependency(package: "ws.hbang.common")]])
        let reports = Reports()
        let app = try await f.run([renamed(".."), renamed("deps"), renamed(""), renamed("../../x"),
                                   TweakSigningItem(package: embeddedOrigin.package, directory: fineItem.directory, force: false),
                                   try f.item(a), fineItem], reports: reports)
        let results = try #require(await reports.last?.results)
        for id in ["..", "deps", "", "../../x", "ws.hbang.common"] { #expect(results[id] == .skipped(.failed), "\(id)") }
        #expect(results[idA] == .injected(converted: true) && results[idC] == .injected(converted: false))
        // The app's own frameworks and XSide's dependency are untouched.
        #expect(exists(app.appendingPathComponent("Frameworks/X.framework/X")))
        #expect(exists(app.appendingPathComponent(TweakLayout.folder + "/deps/ws.hbang.common/" + cepheiFile)))
        #expect(await reports.last?.embedded == ["ws.hbang.common"])
    }

    @Test func underDuoTweaksNeverTakeTheRoomDuoNeeds() async throws {
        let module = MachOPatcher.dylibCommand(Resigner.welcomeLoadPath).count
        let legacy = MachOPatcher.dylibCommand(DuoCompatibility.legacyLoadPath).count
        let one = MachOPatcher.dylibCommand(entryPath(tweak(idA))).count
        // Room for Duo's compatibility module, XSide's and a tweak, but then not for Duo's own 8 bytes.
        let f = try await TweakFixture(executable: executable(padding: legacy + module + one + 4, versionMin: true),
                                       plistExtras: ["CFBundleName": "Demo", "DTPlatformVersion": "17.0"])
        let a = tweak(idA)
        let reports = Reports(), duo = Outcomes()
        let app = try await f.run([try f.item(a)], options: InstallOptions(duoCompatibility: true), reports: reports, duo: duo)
        #expect(await duo.all == [.addedWithModule])
        #expect(MachOBuildInfo.sdkVersion(of: app.appendingPathComponent("Demo")) == "27.1")
        #expect(await reports.last?.results == [idA: .skipped(.noRoom)])
        #expect(try !loads(app).contains(entryPath(a)))
    }

    @Test func reSigningKeepsTheModuleLast() async throws {
        let f = try await TweakFixture(executable: executable(loading: [Resigner.welcomeLoadPath]),
                                       appFiles: ["Frameworks/XSideWelcome.dylib": Data("OLD".utf8)])
        let a = tweak(idA)
        let app = try await f.run([try f.item(a)])
        #expect(try loads(app) == [entryPath(a), Resigner.welcomeLoadPath])
    }

    @Test func aLibraryNoTweakUsesIsNeitherCopiedNorReported() async throws {
        let f = try await TweakFixture()
        let lib = cepheiPackage(id: idB, origin: .added)
        let reports = Reports()
        let app = try await f.run([try f.item(tweak(idA)), try f.item(lib)], reports: reports)
        #expect(await reports.last?.results == [idA: .injected(converted: false)])
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder + "/" + idB)))
    }

    @Test func aBundleWithoutLoadCommandsGoesInEvenWithoutRoom() async throws {
        let module = MachOPatcher.dylibCommand(Resigner.welcomeLoadPath).count
        // Not even room for the module: the bundle needs none.
        let f = try await TweakFixture(executable: executable(padding: module - 8))
        let bin = TweakBinary(path: "Res.bundle/Res", isEntry: false, filter: nil, slices: [arm64()], linked: [],
                              mentionsJailbreakPaths: false, imageName: "Res")
        let files: [String: Data] = ["Res.bundle/Res": FakeIPA.dylibMachO(linking: [], padding: 64)]
        let bundle = Stored(package: TweakPackage(id: idA, kind: .bundle, origin: .added, packageID: "com.example.res", name: "Res",
                                                  files: files.keys.sorted(), binaries: [bin], addedAt: Date()),
                            files: files)
        let reports = Reports()
        _ = try await f.run([try f.item(bundle)], reports: reports)
        #expect(await reports.last?.results == [idA: .injected(converted: false)])
    }

    @Test func elleKitComesBeforeTheSupportLibrary() async throws {
        let f = try await TweakFixture()
        let a = tweak(idA, linked: [substrate], mentions: true)
        let app = try await f.run([try f.item(a)])
        #expect(try loads(app) == [TweakLayout.elleKitLoadPath, TweakLayout.supportLoadPath, entryPath(a), Resigner.welcomeLoadPath])
    }

    @Test func aProviderThatCantBeSignedLeavesItsTweaksOut() async throws {
        var f = try await TweakFixture()
        f.failingSign = "Cephei"
        let a = tweak(idA, linked: [cephei], depends: [[DebDependency(package: "ws.hbang.common")]])
        let fine = tweak(idB, name: "Beta")
        let reports = Reports()
        let app = try await f.run([try f.item(a), try f.item(fine)], reports: reports)
        let report = await reports.last
        #expect(report?.results == [idA: .skipped(.failed), idB: .injected(converted: false)])
        #expect(report?.embedded == [])
        #expect(!exists(app.appendingPathComponent(TweakLayout.folder + "/deps")))
        #expect(try loads(app) == [entryPath(fine), Resigner.welcomeLoadPath])
    }

    @Test func staleCleanupKeepsTheAppsOwnFrameworks() async throws {
        let old = TweakLayout.loadPrefix + "0123456789abcdef/" + dylibFolder + "Old.dylib"
        let f = try await TweakFixture(executable: executable(loading: ["@rpath/Own.framework/Own", old]),
                                       appFiles: ["Frameworks/Own.framework/Own": Data("OWN".utf8),
                                                  "Frameworks/libOwn.dylib": Data("LIB".utf8),
                                                  "Frameworks/XSideTweaks/0123456789abcdef/\(dylibFolder)Old.dylib": Data("OLD".utf8)])
        let app = try await f.run([])
        for path in ["Frameworks/Own.framework/Own", "Frameworks/libOwn.dylib", "Frameworks/X.framework/X"] {
            #expect(exists(app.appendingPathComponent(path)), "\(path)")
        }
        #expect(try loads(app) == ["@rpath/Own.framework/Own", Resigner.welcomeLoadPath])
    }

    // MARK: - The list the iPhone shows

    private func settingsItems(_ app: URL, _ file: String = "Root") throws -> [[String: Any]] {
        let data = try Data(contentsOf: app.appendingPathComponent("Settings.bundle/\(file).plist"))
        let page = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try #require(page["PreferenceSpecifiers"] as? [[String: Any]])
    }

    /// With XSide's module: the payload lists what went in (and what is off here), and XSide's
    /// page (« Réglages XSide ») ends with « Tweaks · N »; the app's page keeps only XSide's row.
    @Test func theIPhoneListsTheTweaksWithTheModule() async throws {
        var f = try await TweakFixture()
        f.settings = true
        var a = tweak(idA, name: "Alpha", mentions: true)
        a.package.author = "Anthony"
        a.package.summary = "Does alpha things."
        let b = tweak(idB, name: "Beta")
        var c = tweak(idC, name: "Gamma").package
        c.version = "2.0"
        let app = try await f.run([try f.item(a), try f.item(b)], offHere: [c])
        let payload = try #require(try plist(app)["XSideWelcome"] as? [String: Any])
        let tweaks = try #require(payload["tweaks"] as? [[String: Any]])
        #expect(tweaks.map { $0["name"] as? String } == ["Alpha", "Beta", "Gamma"])
        #expect(tweaks[0]["converted"] as? Bool == true && tweaks[0]["author"] as? String == "Anthony")
        #expect(tweaks[0]["summary"] as? String == "Does alpha things.")
        #expect(tweaks[1]["converted"] as? Bool == false && tweaks[1]["off"] as? Bool == false)
        #expect(tweaks[2]["off"] as? Bool == true && tweaks[2]["version"] as? String == "2.0")
        let root = try settingsItems(app)
        #expect(root.map { $0["Key"] as? String } == ["io.github.xside.settings.group", "io.github.xside.settings.pane"])
        let pane = try settingsItems(app, "XSide")
        #expect(pane.suffix(2).map { $0["Key"] as? String } == ["io.github.xside.settings.tweaks.group",
                                                                "io.github.xside.settings.tweaks"])
        #expect(pane.last?["Title"] as? String == "Tweaks · 2")
        let page = try settingsItems(app, "XSideTweaks")
        #expect(page.compactMap { $0["Type"] as? String == "PSGroupSpecifier" ? $0["Title"] as? String : nil }
                == ["Alpha · converted", "Beta"])
    }

    /// XSide's features off: no module, no payload, no « Réglages XSide », but the app's page still
    /// lists its tweaks (static rows, nothing to run).
    @Test func theIPhoneListsTheTweaksWithoutTheModule() async throws {
        var f = try await TweakFixture()
        f.settings = true
        let a = tweak(idA, name: "Alpha")
        let app = try await f.run([try f.item(a)], options: InstallOptions(withoutXSideFeatures: true))
        #expect(try plist(app)["XSideWelcome"] == nil)
        let root = try settingsItems(app)
        #expect(root.map { $0["Key"] as? String } == ["io.github.xside.settings.group", "io.github.xside.settings.tweaks"])
        #expect(root[1]["Title"] as? String == "Tweaks · 1")
        #expect(!exists(app.appendingPathComponent("Settings.bundle/XSide.plist")))
        #expect(try settingsItems(app, "XSideTweaks").count == 2)

        // A build without the module behaves the same.
        var g = try await TweakFixture(withModule: false)
        g.settings = true
        let app2 = try await g.run([try g.item(a)])
        #expect(try settingsItems(app2).count == 2)
    }

    /// No tweak in the app: no list in the payload, no row; nothing added without the module.
    @Test func noTweaksNoListNoRow() async throws {
        var f = try await TweakFixture()
        f.settings = true
        let skipped = tweak(idA, name: "Alpha", slices: [arm64("99.0")])
        let app = try await f.run([try f.item(skipped)], offHere: [tweak(idB).package])
        #expect((try plist(app)["XSideWelcome"] as? [String: Any])?["tweaks"] == nil)
        #expect(try settingsItems(app).count == 2)
        #expect(!exists(app.appendingPathComponent("Settings.bundle/XSideTweaks.plist")))
        var g = try await TweakFixture()
        g.settings = true
        let bare = try await g.run([], options: InstallOptions(withoutXSideFeatures: true))
        #expect(!exists(bare.appendingPathComponent("Settings.bundle")))
    }
}
