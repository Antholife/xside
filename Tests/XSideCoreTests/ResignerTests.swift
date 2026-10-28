import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import XSideCore

private let team = "TEAM123456"
private let ok = CommandResult(status: 0, stdout: Data(), stderr: "")

private func tempDir(_ name: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("xside-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func makeProfile() -> ProvisioningProfile {
    let ents: [String: Any] = ["application-identifier": "\(team).com.example.new",
                               "com.apple.security.application-groups": ["group.x"]]
    let data = try! PropertyListSerialization.data(fromPropertyList: ents, format: .xml, options: 0)
    return ProvisioningProfile(uuid: "U-1", teamID: team, bundleID: "com.example.new",
                               creationDate: Date(), expirationDate: Date().addingTimeInterval(1000),
                               deviceUDIDs: [], entitlements: data)
}

private struct Fixture {
    let work: URL, ipa: URL, profileURL: URL
    let fake: FakeRunner
    var resigner: Resigner { Resigner(runner: RoutingRunner(fake: fake)) }
}

private func fixture(encrypted: Bool = false, extensions: [String] = ["PlugIns", "Extensions", "Watch"],
                     withIcons: Bool = false, appName: String = "Demo", work: URL? = nil,
                     prepare: (URL) throws -> Void = { _ in }) async throws -> Fixture {
    let src = try tempDir("src")
    let app = try FakeIPA.makeApp(at: src, name: appName, extensions: extensions, encrypted: encrypted)
    try prepare(app)
    if withIcons { try addAssetCatalogIcons(app) }
    // stale signatures
    for dir in [app, app.appendingPathComponent("Frameworks/X.framework")] {
        let cs = dir.appendingPathComponent("_CodeSignature")
        try FileManager.default.createDirectory(at: cs, withIntermediateDirectories: true)
        try Data("sig".utf8).write(to: cs.appendingPathComponent("CodeResources"))
    }
    try Data("dylib".utf8).write(to: app.appendingPathComponent("Frameworks/X.framework/inner.dylib"))
    try Data("dylib".utf8).write(to: app.appendingPathComponent("libtop.dylib"))
    let out = try tempDir("ipa")
    let ipa = out.appendingPathComponent("Demo.ipa")
    let r = try await ProcessRunner().run("/usr/bin/ditto",
        ["-c", "-k", "--sequesterRsrc", "--keepParent", src.appendingPathComponent("Payload").path, ipa.path], cwd: nil)
    #expect(r.status == 0)
    let profileURL = out.appendingPathComponent("p.mobileprovision")
    try Data("PROFILE-BYTES".utf8).write(to: profileURL)
    let fake = FakeRunner()
    fake.stub("/usr/bin/codesign", result: ok)
    return Fixture(work: try work ?? tempDir("work"), ipa: ipa, profileURL: profileURL, fake: fake)
}

private func run(_ f: Fixture, options: InstallOptions = InstallOptions(), iconURL: URL? = nil) async throws -> URL {
    try await f.resigner.resign(ipa: f.ipa, workDir: f.work, bundleID: "com.example.new", options: options,
                                iconURL: iconURL, profileURL: f.profileURL, profile: makeProfile(), identitySHA1: "FAKESHA1")
}

private func plist(_ app: URL) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(
        from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as! [String: Any]
}

@Suite struct ResignerTests {
    @Test func stripsExtensions() async throws {
        let f = try await fixture()
        let app = try await run(f)
        for d in ["PlugIns", "Extensions", "Watch"] {
            #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent(d).path))
        }
    }

    @Test func rewritesBundleID() async throws {
        let app = try await run(try await fixture())
        #expect(try plist(app)["CFBundleIdentifier"] as? String == "com.example.new")
    }

    @Test func keepsBinaryPlistFormat() async throws {
        let app = try await run(try await fixture())
        let head = try Data(contentsOf: app.appendingPathComponent("Info.plist")).prefix(6)
        #expect(String(decoding: head, as: UTF8.self) == "bplist")
    }

    @Test func embedsProfile() async throws {
        let f = try await fixture()
        let app = try await run(f)
        #expect(try Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision"))
                == Data(contentsOf: f.profileURL))
    }

    @Test func removesOldSignatures() async throws {
        let app = try await run(try await fixture())
        let en = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)!
        let left = en.compactMap { ($0 as! URL).lastPathComponent }.filter { $0 == "_CodeSignature" }
        #expect(left.isEmpty)
    }

    @Test func signsInsideOut() async throws {
        let f = try await fixture()
        let app = try await run(f)
        let calls = f.fake.calls
        #expect(calls.count == 4)
        let targets = calls.map { $0.last! }
        let fw = app.appendingPathComponent("Frameworks/X.framework").path
        let inner = app.appendingPathComponent("Frameworks/X.framework/inner.dylib").path
        #expect(targets.last == app.path)
        #expect(targets.firstIndex(of: inner)! < targets.firstIndex(of: fw)!)
        #expect(targets.firstIndex(of: fw)! < targets.count - 1)
        for c in calls {
            #expect(c.starts(with: ["/usr/bin/codesign", "-f", "-s", "FAKESHA1", "--timestamp=none"]))
        }
        #expect(calls.dropLast().allSatisfy { !$0.contains("--entitlements") })
        #expect(calls.last!.contains("--entitlements"))
    }

    @Test func entitlementsComeFromProfile() async throws {
        let f = try await fixture()
        let captured = Captured()
        f.fake.stub("/usr/bin/codesign", result: ok) { args in
            if let i = args.firstIndex(of: "--entitlements") {
                captured.value = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1]))
            }
        }
        _ = try await run(f)
        let d = try #require(captured.value)
        let ents = try #require(try PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any])
        #expect(ents["application-identifier"] as? String == "\(team).com.example.new")
        #expect(ents["com.apple.security.application-groups"] != nil)
    }

    @Test func appliesOptions() async throws {
        let opts = InstallOptions(displayName: "Tube", version: "9.9", fileSharing: true,
                                  iPadFullScreen: true, proMotion: true, minimumOSVersion: "15.0")
        let p = try plist(try await run(try await fixture(), options: opts))
        #expect(p["CFBundleDisplayName"] as? String == "Tube")
        #expect(p["CFBundleName"] as? String == "Tube")
        #expect(p["CFBundleShortVersionString"] as? String == "9.9")
        #expect(p["UIFileSharingEnabled"] as? Bool == true)
        #expect(p["LSSupportsOpeningDocumentsInPlace"] as? Bool == true)
        #expect(p["UIRequiresFullScreen"] as? Bool == true)
        #expect(p["CADisableMinimumFrameDurationOnPhone"] as? Bool == true)
        #expect(p["MinimumOSVersion"] as? String == "15.0")
    }

    @Test func defaultOptionsLeaveKeysAlone() async throws {
        let p = try plist(try await run(try await fixture()))
        for k in ["CFBundleDisplayName", "CFBundleShortVersionString", "UIFileSharingEnabled",
                  "LSSupportsOpeningDocumentsInPlace", "UIRequiresFullScreen",
                  "CADisableMinimumFrameDurationOnPhone", "MinimumOSVersion", "CFBundleIcons"] {
            #expect(p[k] == nil)
        }
        #expect(p["CFBundleName"] as? String == "Demo")
    }

    @Test func appliesCustomIcon() async throws {
        let f = try await fixture(withIcons: true)
        let png = try tempDir("icon").appendingPathComponent("big.png")
        try writePNG(size: 1024, to: png)
        let app = try await run(f, iconURL: png)
        #expect(try pixelWidth(app.appendingPathComponent("XSideIcon60x60@2x.png")) == 120)
        #expect(try pixelWidth(app.appendingPathComponent("XSideIcon76x76@2x~ipad.png")) == 152)
        let p = try plist(app)
        let icons = try #require(p["CFBundleIcons"] as? [String: Any])
        let primary = try #require(icons["CFBundlePrimaryIcon"] as? [String: Any])
        #expect(primary["CFBundleIconFiles"] as? [String] == ["XSideIcon60x60"])
        #expect(primary["CFBundleIconName"] == nil)
        let ipad = try #require(p["CFBundleIcons~ipad"] as? [String: Any])
        let ipadPrimary = try #require(ipad["CFBundlePrimaryIcon"] as? [String: Any])
        #expect(ipadPrimary["CFBundleIconFiles"] as? [String] == ["XSideIcon60x60", "XSideIcon76x76"])
    }

    @Test func reusedWorkDirStartsClean() async throws {
        let first = try await fixture(appName: "Old") { app in
            try Data("x".utf8).write(to: app.appendingPathComponent("stale.txt"))
        }
        let a1 = try await run(first)
        #expect(a1.lastPathComponent == "Old.app")
        let second = try await fixture(appName: "New", work: first.work)
        let a2 = try await run(second)
        #expect(a2.lastPathComponent == "New.app")
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: first.work.appendingPathComponent("Payload/Old.app").path))
        #expect(!fm.fileExists(atPath: a2.appendingPathComponent("stale.txt").path))
        let leftovers = try fm.contentsOfDirectory(atPath: first.work.path).filter { $0.hasPrefix("entitlements-") }
        #expect(leftovers.count == 1)
    }

    @Test func sameAppNameDropsFilesMissingFromNewIPA() async throws {
        let first = try await fixture { app in
            try Data("x".utf8).write(to: app.appendingPathComponent("stale.txt"))
        }
        _ = try await run(first)
        let second = try await fixture(work: first.work)
        let app = try await run(second)
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("stale.txt").path))
    }

    @Test func rejectsInfoPlistSymlinkOutsideWorkDir() async throws {
        let outside = try tempDir("outside").appendingPathComponent("victim.plist")
        let original = Data("precious".utf8)
        try original.write(to: outside)
        let f = try await fixture { app in
            let info = app.appendingPathComponent("Info.plist")
            try FileManager.default.removeItem(at: info)
            try FileManager.default.createSymbolicLink(at: info, withDestinationURL: outside)
        }
        await #expect(throws: (any Error).self) { _ = try await run(f) }
        do { _ = try await run(f) } catch let e as XSideError {
            guard case .invalidIPA = e else { Issue.record("wrong error \(e)"); return }
        }
        #expect(try Data(contentsOf: outside) == original)
        #expect(f.fake.calls.isEmpty)
    }

    @Test func rejectsDirectorySymlinkOutsideBundle() async throws {
        let outsideDir = try tempDir("outsidedir")
        let f = try await fixture(extensions: []) { app in
            try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("PlugIns"),
                                                       withDestinationURL: outsideDir)
        }
        do { _ = try await run(f); Issue.record("expected failure") } catch let e as XSideError {
            guard case .invalidIPA = e else { Issue.record("wrong error \(e)"); return }
        }
        #expect(FileManager.default.fileExists(atPath: outsideDir.path))
    }

    @Test func allowsInBundleFrameworkSymlinks() async throws {
        let f = try await fixture { app in
            let fm = FileManager.default
            let fw = app.appendingPathComponent("Frameworks/Y.framework")
            try fm.createDirectory(at: fw.appendingPathComponent("Versions/A"), withIntermediateDirectories: true)
            try FakeIPA.thinMachO(cryptid: 0).write(to: fw.appendingPathComponent("Versions/A/Y"))
            try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
            try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Y").path, withDestinationPath: "Versions/Current/Y")
        }
        let app = try await run(f)
        let targets = f.fake.calls.map { $0.last! }
        #expect(targets.contains(app.appendingPathComponent("Frameworks/Y.framework").path))
        #expect(targets.last == app.path)
    }

    @Test func iconOutputSymlinkDoesNotWriteThrough() async throws {
        let outside = try tempDir("outside").appendingPathComponent("victim.png")
        let original = Data("precious".utf8)
        try original.write(to: outside)
        let f = try await fixture { app in
            // In-bundle link (an outside link is rejected earlier): sips must not write through it.
            try Data("inbundle".utf8).write(to: app.appendingPathComponent("target.bin"))
            try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("XSideIcon60x60@2x.png").path,
                                                       withDestinationPath: "target.bin")
        }
        let png = try tempDir("icon").appendingPathComponent("big.png")
        try writePNG(size: 1024, to: png)
        let app = try await run(f, iconURL: png)
        let icon = app.appendingPathComponent("XSideIcon60x60@2x.png")
        #expect(!isLink(icon))
        #expect(try pixelWidth(icon) == 120)
        #expect(try Data(contentsOf: app.appendingPathComponent("target.bin")) == Data("inbundle".utf8))
        #expect(try Data(contentsOf: outside) == original)
    }

    @Test func rejectsEncryptedBinary() async throws {
        let f = try await fixture(encrypted: true)
        await #expect(throws: XSideError.encryptedIPA) { _ = try await run(f) }
        #expect(f.fake.calls.isEmpty)
    }

    @Test func codesignFailureIsReported() async throws {
        let f = try await fixture()
        f.fake.stub("/usr/bin/codesign", result: CommandResult(status: 1, stdout: Data(), stderr: "boom"))
        await #expect(throws: XSideError.commandFailed(tool: "codesign", status: 1)) { _ = try await run(f) }
    }

    @Test func unzippableIPAIsInvalid() async throws {
        let f = try await fixture()
        try Data("not a zip".utf8).write(to: f.ipa)
        await #expect(throws: XSideError.self) { _ = try await run(f) }
    }
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: Data?
    var value: Data? { get { lock.withLock { _v } } set { lock.withLock { _v = newValue } } }
}

private func writePNG(size: Int, to url: URL) throws {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
}

private func pixelWidth(_ url: URL) throws -> Int {
    let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    return props[kCGImagePropertyPixelWidth] as? Int ?? 0
}

/// Simulates an asset-catalog icon declaration (CFBundleIconName) that the Resigner must drop.
private func addAssetCatalogIcons(_ app: URL) throws {
    let url = app.appendingPathComponent("Info.plist")
    var p = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
    let icons: [String: Any] = ["CFBundlePrimaryIcon": ["CFBundleIconName": "AppIcon", "CFBundleIconFiles": ["Old"]]]
    p["CFBundleIcons"] = icons
    p["CFBundleIcons~ipad"] = icons
    try PropertyListSerialization.data(fromPropertyList: p, format: .binary, options: 0).write(to: url)
}

private func isLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
}
