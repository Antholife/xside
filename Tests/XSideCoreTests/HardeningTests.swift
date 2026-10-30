import Testing
import Foundation
@testable import XSideCore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A zip made of a central directory only (the scanner never reads entry data): one header per
/// `(compressed, uncompressed)` pair, ZIP64 extra fields when a size needs them.
private func syntheticZip(_ entries: [(compressed: UInt64, uncompressed: UInt64)], declaredCount: Int? = nil) -> Data {
    var d = Data()
    func le16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func le64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    for (i, e) in entries.enumerated() {
        let name = Array("f\(i)".utf8)
        let big = e.compressed >= 0xFFFF_FFFF || e.uncompressed >= 0xFFFF_FFFF
        le32(0x0201_4B50); le16(45); le16(45); le16(0); le16(8); le16(0); le16(0); le32(0)
        le32(big ? 0xFFFF_FFFF : UInt32(e.compressed)); le32(big ? 0xFFFF_FFFF : UInt32(e.uncompressed))
        le16(name.count); le16(big ? 20 : 0); le16(0); le16(0); le16(0); le32(0); le32(0)
        d.append(contentsOf: name)
        if big { le16(1); le16(16); le64(e.uncompressed); le64(e.compressed) }
    }
    let size = d.count
    le32(0x0605_4B50); le16(0); le16(0)
    le16(declaredCount ?? entries.count); le16(declaredCount ?? entries.count)
    le32(UInt32(size)); le32(0); le16(0)
    return d
}

private func write(_ data: Data) throws -> URL {
    let url = try tempDir().appendingPathComponent("a.ipa")
    try data.write(to: url)
    return url
}

struct ZipLimitsTests {
    @Test func acceptsARealArchive() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        try FakeIPA.makeApp(at: root)
        let ipa = root.appendingPathComponent("T.ipa")
        _ = try await ProcessRunner().run("/usr/bin/ditto",
            ["-c", "-k", "--keepParent", root.appendingPathComponent("Payload").path, ipa.path], cwd: nil)
        let totals = try ZipLimits.scan(ipa)
        #expect(totals.entries > 3)
        #expect(totals.uncompressed > 0)
        try ZipLimits.check(ipa)
    }

    @Test func readsDeclaredSizesIncludingZIP64() throws {
        let url = try write(syntheticZip([(10, 20), (5_000_000_000, 6_000_000_000)]))
        #expect(try ZipLimits.scan(url) == ZipLimits.Totals(entries: 2, compressed: 5_000_000_010,
                                                             uncompressed: 6_000_000_020))
    }

    @Test func refusesBombs() throws {
        // More than 4 GB once unpacked.
        #expect(throws: XSideError.self) { try ZipLimits.check(try write(syntheticZip([(4_000_000_000, 4_300_000_000)]))) }
        // A suspicious ratio past the floor: 1 MB expanding to 200 MB.
        #expect(throws: XSideError.self) { try ZipLimits.check(try write(syntheticZip([(1_000_000, 200_000_000)]))) }
        // A high ratio on a small archive is fine.
        try ZipLimits.check(try write(syntheticZip([(1_000, 10_000_000)])))
    }

    @Test func refusesTooManyEntries() throws {
        let many = Array(repeating: (compressed: UInt64(1), uncompressed: UInt64(1)), count: ZipLimits.maxEntries + 1)
        // The 16-bit count wraps; the directory itself is what's counted.
        #expect(throws: XSideError.self) {
            try ZipLimits.check(try write(syntheticZip(many, declaredCount: 0xFFFF)))
        }
    }

    @Test func acceptsExactly65535EntriesWithoutZIP64() throws {
        let entries = Array(repeating: (compressed: UInt64(1), uncompressed: UInt64(1)), count: 0xFFFF)
        #expect(try ZipLimits.scan(try write(syntheticZip(entries))).entries == 0xFFFF)
    }

    @Test func unreadableArchivesAreInvalidIPA() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for url in [dir, dir.appendingPathComponent("missing.ipa")] {
            do { try ZipLimits.check(url); Issue.record("expected invalidIPA") }
            catch let error as XSideError { #expect(error.key == "invalidIPA") }
        }
    }

    @Test func refusesNonZipAndInconsistentDirectory() throws {
        #expect(throws: XSideError.self) { try ZipLimits.check(try write(Data("not a zip".utf8))) }
        #expect(throws: XSideError.self) { try ZipLimits.check(try write(Data())) }
        #expect(throws: XSideError.self) { try ZipLimits.check(try write(syntheticZip([(1, 1)], declaredCount: 3))) }
    }
}

struct MachOBoundsTests {
    private func file(_ data: Data) throws -> URL { try write(data) }

    @Test func refusesTooManyFatSlices() throws {
        var fat = Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 17])
        fat.append(Data(count: 17 * 20))
        #expect(throws: XSideError.self) { try IPAInspector.isEncrypted(try file(fat)) }
    }

    @Test func refusesInconsistentCommandSizes() throws {
        func patched(_ offset: Int, _ value: UInt32) -> Data {
            var d = FakeIPA.thinMachO(cryptid: 0)
            withUnsafeBytes(of: value.littleEndian) { d.replaceSubrange(offset..<offset + 4, with: $0) }
            return d
        }
        #expect(throws: XSideError.self) { try IPAInspector.isEncrypted(try file(patched(16, 1_000_000))) } // ncmds*8 > sizeofcmds
        #expect(throws: XSideError.self) { try IPAInspector.isEncrypted(try file(patched(20, 4096))) } // past the file
        #expect(throws: XSideError.self) { try IPAInspector.isEncrypted(try file(patched(36, 64))) } // command past sizeofcmds
        #expect(try IPAInspector.isEncrypted(try file(FakeIPA.thinMachO(cryptid: 1))))
    }
}

struct BundleIdentifierTests {
    @Test(arguments: ["com.example.app", "a", "com.ex-ample.App2", "io.github.x.TEAM123456"])
    func accepts(id: String) { #expect(BundleIdentifier.isValid(id)) }

    @Test(arguments: ["", ".com", "com.", "com..x", "com.ex ample", "com/x", "com.é", "com.x_y", "com.x*",
                      String(repeating: "a", count: 156)])
    func refuses(id: String) { #expect(!BundleIdentifier.isValid(id)) }

    @Test func originalMayHoldUnderscoresButNotTheSignedDefault() {
        #expect(BundleIdentifier.isValidOriginal("com.vendor.my_app"))
        #expect(!BundleIdentifier.isValidOriginal("com.vendor.my app"))
        #expect(BundleIdentifier.defaultSigned(original: "com.vendor.my_app", teamID: "T1") == "com.vendor.my-app.T1")
        #expect(BundleIdentifier.isValid(BundleIdentifier.defaultSigned(original: "com.vendor.my_app", teamID: "T1")))
    }

    @Test func importRefusesATooLongSignedIdentifier() async throws {
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = AppLibrary(root: tmp.appendingPathComponent("lib"))
        let src = tmp.appendingPathComponent("a.ipa")
        try Data("ipa".utf8).write(to: src)
        let long = "com." + String(repeating: "a", count: 145) // 149: valid itself, not with ".TEAM123456"
        #expect(BundleIdentifier.isValidOriginal(long))
        let info = AppInfo(bundleID: long, name: "A", version: nil, executable: "A")
        await #expect(throws: XSideError.invalidBundleID("\(long).TEAM123456")) {
            _ = try await lib.importIPA(src, info: info, teamID: "TEAM123456")
        }
        #expect(await lib.records().isEmpty)
        let underscored = AppInfo(bundleID: "com.vendor.my_app", name: "B", version: nil, executable: "B")
        #expect(try await lib.importIPA(src, info: underscored, teamID: "T1").signedBundleID == "com.vendor.my-app.T1")
    }

    @Test func importRefusesInvalidIdentifier() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try FakeIPA.makeApp(at: root, bundleID: "com.bad id")
        #expect(throws: XSideError.invalidIPA("CFBundleIdentifier invalide")) { try IPAInspector.info(of: app) }
    }

    @Test func refusesHugeInfoPlist() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try FakeIPA.makeApp(at: root, plistExtras: ["Padding": String(repeating: "x", count: 1_100_000)])
        #expect(throws: XSideError.invalidIPA("Info.plist trop volumineux")) { try IPAInspector.info(of: app) }
    }
}

struct IconHelperTests {
    @Test func subprocessResultDecidesTheIcon() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("icon.png")
        let helper = URL(fileURLWithPath: "/Applications/XSide.app/Contents/MacOS/XSide")
        let runner = FakeRunner()
        runner.stub(helper.path, result: CommandResult(status: 0, stdout: Data(), stderr: "")) { args in
            try? Data("png".utf8).write(to: URL(fileURLWithPath: args[2]))
        }
        #expect(await AppIconExtractor.extractInSubprocess(helper: helper, app: dir, destination: out, runner: runner))
        #expect(runner.calls.last == [helper.path, "--extract-icon", dir.path, out.path])
        #expect(runner.timeouts.last == CommandTimeout.iconHelper)

        // A crash (or any failure) leaves no icon, not even a partial file.
        runner.stub(helper.path, result: CommandResult(status: 139, stdout: Data(), stderr: ""))
        #expect(!(await AppIconExtractor.extractInSubprocess(helper: helper, app: dir, destination: out, runner: runner)))
        #expect(!FileManager.default.fileExists(atPath: out.path))
        // A timeout too (the runner throws).
        let none = FakeRunner()
        #expect(!(await AppIconExtractor.extractInSubprocess(helper: helper, app: dir, destination: out, runner: none)))
    }

    @Test func helperRefusesBadArguments() {
        #expect(AppIconExtractor.runHelper(arguments: []) == 64)
        #expect(AppIconExtractor.runHelper(arguments: ["a", "b", "c"]) == 64)
    }
}

/// Thin 64-bit Mach-O whose LC_CODE_SIGNATURE points at a super blob holding `entitlements`.
private func signedMachO(entitlements: [String: Any]) throws -> Data {
    let xml = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
    var d = Data()
    func le(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func be(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
    let dataoff: UInt32 = 32 + 16
    let entBlobSize = UInt32(8 + xml.count)
    let superSize = 12 + 2 * 8 + 12 + entBlobSize
    le(0xFEEDFACF); le(0x0100000C); le(0); le(2); le(1); le(16); le(0); le(0)
    le(0x1D); le(16); le(dataoff); le(superSize)            // LC_CODE_SIGNATURE
    be(0xFADE_0CC0); be(superSize); be(2)                    // super blob, 2 slots
    be(0); be(12 + 16)                                       // code directory slot (a dummy blob)
    be(5); be(12 + 16 + 12)                                  // entitlements slot
    be(0xFADE_0C02); be(12); be(0)                           // dummy blob
    be(0xFADE_7171); be(entBlobSize); d.append(xml)
    return d
}

struct EntitlementsTests {
    @Test func readsEmbeddedEntitlements() throws {
        let declared: [String: Any] = ["application-identifier": "OLDTEAM123.com.vendor.app",
                                       "keychain-access-groups": ["OLDTEAM123.com.vendor.shared"]]
        let url = try write(try signedMachO(entitlements: declared))
        let read = try #require(IPAInspector.embeddedEntitlements(url))
        #expect(read["keychain-access-groups"] as? [String] == ["OLDTEAM123.com.vendor.shared"])
        // Inside a fat binary too (first slice).
        let fat = try write(FakeIPA.fatMachO(slices: [try signedMachO(entitlements: declared)]))
        #expect(IPAInspector.embeddedEntitlements(fat)?["application-identifier"] as? String == "OLDTEAM123.com.vendor.app")
        // Unsigned or truncated: nothing.
        #expect(IPAInspector.embeddedEntitlements(try write(FakeIPA.thinMachO(cryptid: 0))) == nil)
        #expect(IPAInspector.embeddedEntitlements(try write(try signedMachO(entitlements: declared).dropLast(40))) == nil)
    }

    @Test func remapsDeclaredKeychainGroupsToTheNewTeam() {
        let original: [String: Any] = [
            "application-identifier": "OLDTEAM123.com.vendor.app",
            "keychain-access-groups": ["OLDTEAM123.com.vendor.app", "OLDTEAM123.com.vendor.shared",
                                       "$(AppIdentifierPrefix)com.vendor.other", "OTHERTEAM9.com.partner",
                                       "OLDTEAM123.*", "com.apple.token", "group.not-prefixed",
                                       "NEWTEAM456.com.vendor.app.NEWTEAM456"],
        ]
        let groups = Resigner.keychainGroups(original, team: "NEWTEAM456", appID: "NEWTEAM456.com.vendor.app.NEWTEAM456")
        #expect(groups == ["NEWTEAM456.com.vendor.app.NEWTEAM456", "NEWTEAM456.com.vendor.app",
                           "NEWTEAM456.com.vendor.shared", "NEWTEAM456.com.vendor.other", "NEWTEAM456.com.partner",
                           "com.apple.token"])
        #expect(Resigner.keychainGroups(nil, team: "T", appID: "T.b") == ["T.b"])
    }

    @Test func signingEntitlementsUseTheRemappedGroups() throws {
        let granted = try PropertyListSerialization.data(
            fromPropertyList: ["keychain-access-groups": ["NEWTEAM456.*"]], format: .xml, options: 0)
        let profile = ProvisioningProfile(uuid: "U", teamID: "NEWTEAM456", bundleID: "*", creationDate: Date(),
                                          expirationDate: Date(), deviceUDIDs: [], entitlements: granted)
        let data = try Resigner.signingEntitlements(
            profile: profile, bundleID: "com.vendor.app.NEWTEAM456",
            original: ["com.apple.developer.team-identifier": "OLDTEAM123",
                       "keychain-access-groups": ["OLDTEAM123.com.vendor.shared", "*"]])
        let signed = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(signed["keychain-access-groups"] as? [String]
                == ["NEWTEAM456.com.vendor.app.NEWTEAM456", "NEWTEAM456.com.vendor.shared"])
    }
}
