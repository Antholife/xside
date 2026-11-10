import Foundation
import Testing
@testable import XSideCore

/// Builds thin arm64 Mach-O files for the IPA content tests: dylib loads, rpaths, imported
/// symbols, strings in the file and an optional code signature with a Team ID.
enum ContentMachO {
    struct Load { var name: String; var weak = false }

    static func build(loads: [Load] = [], rpaths: [String] = [], imports: [String] = [], strings: [String] = [],
                      team: String? = nil, signed: Bool = true, filetype: UInt32 = 6) -> Data {
        func le(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func be(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
        func lcStr(_ cmd: UInt32, header: Data, _ s: String) -> Data {
            let size = (header.count + 8 + s.utf8.count + 1 + 7) & ~7
            var d = le(cmd) + le(UInt32(size)) + header
            d.append(contentsOf: Array(s.utf8) + [0])
            d.append(Data(count: size - d.count))
            return d
        }
        var commands: [Data] = []
        for l in loads {
            commands.append(lcStr(l.weak ? 0x8000_0018 : 0xC, header: le(24) + le(2) + le(0x0001_0000) + le(0x0001_0000), l.name))
        }
        for r in rpaths { commands.append(lcStr(0x8000_001C, header: le(12), r)) }
        let hasSymtab = !imports.isEmpty
        let hasSignature = signed
        let ncmds = commands.count + (hasSymtab ? 1 : 0) + (hasSignature ? 1 : 0)
        let sizeofcmds = commands.reduce(0) { $0 + $1.count } + (hasSymtab ? 24 : 0) + (hasSignature ? 16 : 0)
        let dataStart = 32 + sizeofcmds
        // Symbols then their names, then the strings, then the signature.
        var strtab = Data([0x20, 0x00])
        var nlist = Data()
        for name in imports {
            let strx = UInt32(strtab.count)
            strtab.append(contentsOf: Array(name.utf8) + [0])
            nlist += le(strx); nlist.append(0x01); nlist.append(0); nlist += Data([0, 0]); nlist += Data(count: 8)
        }
        var blob = Data([0])
        for s in strings { blob.append(contentsOf: Array(s.utf8) + [0]) }
        let symoff = dataStart, stroff = symoff + nlist.count
        let blobStart = stroff + strtab.count
        var signatureOffset = blobStart + blob.count
        signatureOffset = (signatureOffset + 15) & ~15
        var signature = Data()
        if hasSignature {
            let ident = Data("com.example.x".utf8) + Data([0])
            let teamBytes = team.map { Data($0.utf8) + Data([0]) } ?? Data()
            let cdHeader = 52
            let identOffset = cdHeader, teamOffset = team == nil ? 0 : cdHeader + ident.count
            let cdLength = cdHeader + ident.count + teamBytes.count
            var cd = be(0xFADE_0C02) + be(UInt32(cdLength)) + be(0x20200) + be(0)
            cd += be(UInt32(cdLength)) + be(UInt32(identOffset)) + be(0) + be(0) + be(0)
            cd += Data([32, 2, 0, 12]) + be(0) + be(0) + be(UInt32(teamOffset))
            cd += ident + teamBytes
            let superLength = 12 + 8 + cd.count
            signature = be(0xFADE_0CC0) + be(UInt32(superLength)) + be(1) + be(0) + be(20) + cd
        }
        var d = le(0xFEED_FACF) + le(0x0100_000C) + le(0) + le(filetype)
        d += le(UInt32(ncmds)) + le(UInt32(sizeofcmds)) + le(0) + le(0)
        for c in commands { d += c }
        if hasSymtab {
            d += le(0x2) + le(24) + le(UInt32(symoff)) + le(UInt32(imports.count)) + le(UInt32(stroff)) + le(UInt32(strtab.count))
        }
        if hasSignature { d += le(0x1D) + le(16) + le(UInt32(signatureOffset)) + le(UInt32(signature.count)) }
        d += nlist + strtab + blob
        d.append(Data(count: signatureOffset - d.count))
        d += signature
        return d
    }
}

/// An extracted app with the given files (path relative to the .app -> content).
private func makeApp(_ dir: URL, main: Data, files: [String: Data] = [:], plist: [String: Any] = [:]) throws -> URL {
    let app = dir.appendingPathComponent("Payload/Demo.app")
    let fm = FileManager.default
    try fm.createDirectory(at: app, withIntermediateDirectories: true)
    var info: [String: Any] = ["CFBundleIdentifier": "com.example.demo", "CFBundleExecutable": "Demo"]
    info.merge(plist) { _, new in new }
    try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        .write(to: app.appendingPathComponent("Info.plist"))
    try main.write(to: app.appendingPathComponent("Demo"))
    for (path, data) in files {
        let url = app.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    return app
}

private func scan(_ app: URL, entitlements: [String: Any]? = nil) -> IPAContent {
    let plist = (try? PropertyListSerialization.propertyList(
        from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil)) as? [String: Any] ?? [:]
    return IPAContentScanner.scan(app: app, executable: "Demo", plist: plist, entitlements: entitlements)
}

private typealias L = ContentMachO.Load

struct IPAContentTests {
    // MARK: Team ID

    @Test func readsTheTeamIDOfTheCodeDirectory() {
        #expect(IPAInspector.codeSigningTeamID(ContentMachO.build(team: "ABCDE12345")) == "ABCDE12345")
        #expect(IPAInspector.codeSigningTeamID(ContentMachO.build(team: nil)) == nil)
        #expect(IPAInspector.codeSigningTeamID(ContentMachO.build(signed: false)) == nil)
    }

    @Test func aDamagedSignatureHasNoTeamAndNeverTraps() {
        let good = ContentMachO.build(team: "ABCDE12345")
        // Every truncation and every single-byte corruption of the signature area.
        for n in stride(from: 0, to: good.count, by: 7) {
            _ = IPAInspector.codeSigningTeamID(good.prefix(n))
        }
        for i in stride(from: 32, to: good.count, by: 3) {
            var bad = good
            bad[i] = 0xFF
            _ = IPAInspector.codeSigningTeamID(bad)
        }
        #expect(IPAInspector.codeSigningTeamID(Data()) == nil)
        #expect(IPAInspector.codeSigningTeamID(Data(repeating: 0xFF, count: 64)) == nil)
    }

    @Test func aTeamIDThatIsNotPlainTextIsIgnored() {
        #expect(IPAInspector.codeSigningTeamID(ContentMachO.build(team: "AB/../x")) == nil)
        #expect(IPAInspector.codeSigningTeamID(ContentMachO.build(team: String(repeating: "A", count: 80))) == nil)
    }

    // MARK: imports

    @Test func readsWantedImportedSymbols() {
        let d = ContentMachO.build(imports: ["_SecItemCopyMatching", "_objc_msgSend", "_dlopen"])
        #expect(MachOImports.importedSymbols(in: d, wanted: ["_SecItemCopyMatching", "_dlopen", "_SecItemExport"])
                == ["_SecItemCopyMatching", "_dlopen"])
        #expect(MachOImports.importedSymbols(in: Data([1, 2, 3]), wanted: ["_dlopen"]).isEmpty)
    }

    // MARK: additions

    /// A normal app: its own frameworks (same team), Swift's libraries: nothing added.
    @Test func aCleanAppHasNoAdditions() throws {
        try withTempDir { dir in
            let main = ContentMachO.build(loads: [L(name: "@rpath/Firebase.framework/Firebase"),
                                                  L(name: "@rpath/libswiftCore.dylib"),
                                                  L(name: "@rpath/libswiftCompatibilitySpan.dylib"),
                                                  L(name: "/System/Library/Frameworks/UIKit.framework/UIKit")],
                                          rpaths: ["@executable_path/Frameworks"], team: "TEAM111111", filetype: 2)
            let app = try makeApp(dir, main: main, files: [
                "Frameworks/Firebase.framework/Firebase": ContentMachO.build(team: "TEAM111111"),
                "Frameworks/libswiftCore.dylib": ContentMachO.build(team: "TEAM111111"),
                "Frameworks/libswiftCompatibilitySpan.dylib": ContentMachO.build(team: "TEAM111111"),
            ])
            #expect(scan(app).additions.isEmpty)
        }
    }

    /// A decrypted app (no team anywhere) with a tweak, its hooking library and a helper the tweak
    /// loads: each found, with how it's loaded and its kind.
    @Test func findsATweakItsLibraryAndWhatItLoads() throws {
        try withTempDir { dir in
            let main = ContentMachO.build(loads: [L(name: "@rpath/widevine.framework/widevine"),
                                                  L(name: "@rpath/YTKACE.dylib"),
                                                  L(name: "@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", weak: true)],
                                          rpaths: ["@executable_path/Frameworks"], signed: false, filetype: 2)
            let tweak = ContentMachO.build(loads: [L(name: "@loader_path/libhelper.dylib")],
                                           imports: ["_method_setImplementation"],
                                           strings: ["/Library/MobileSubstrate/DynamicLibraries/"], signed: false)
            let app = try makeApp(dir, main: main, files: [
                "Frameworks/widevine.framework/widevine": ContentMachO.build(signed: false),
                "Frameworks/YTKACE.dylib": tweak,
                "Frameworks/libhelper.dylib": ContentMachO.build(signed: false),
                "Frameworks/CydiaSubstrate.framework/CydiaSubstrate": ContentMachO.build(signed: false),
            ])
            let additions = scan(app).additions
            // What the app loads first, then what those load.
            #expect(additions.map(\.path) == ["Frameworks/YTKACE.dylib", "Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
                                              "Frameworks/libhelper.dylib"])
            let ytkace = try #require(additions.first)
            #expect(ytkace.name == "YTKACE")
            #expect(ytkace.kind == .tweak)
            #expect(ytkace.load == .launch)
            #expect(ytkace.size == Int64(tweak.count))
            #expect(!ytkace.hasMetadata)
            let helper = additions[2]
            #expect(helper.name == "libhelper.dylib")
            #expect(helper.kind == .unknown)
            #expect(helper.load == .indirect)
            #expect(helper.loadedBy == "YTKACE")
            let substrate = additions[1]
            #expect(substrate.name == "CydiaSubstrate")
            #expect(substrate.kind == .tweakLibrary)
            #expect(substrate.load == .weak)
        }
    }

    /// A library named like Swift's own but that isn't one (libswiftIU.dylib, a crack seen in
    /// the wild), unsigned in a signed app.
    @Test func aFakeSwiftLibraryIsAnAddition() throws {
        try withTempDir { dir in
            let main = ContentMachO.build(loads: [L(name: "@executable_path/libswiftIU.dylib", weak: true)],
                                          team: "TEAM111111", filetype: 2)
            let fake = ContentMachO.build(loads: [L(name: "/Library/MobileSubstrate/DynamicLibraries/Patch.dylib")], signed: false)
            let app = try makeApp(dir, main: main, files: ["libswiftIU.dylib": fake])
            let additions = scan(app).additions
            #expect(additions.map(\.name) == ["libswiftIU"])
            #expect(additions.first?.kind == .tweak)
            #expect(additions.first?.load == .weak)
        }
    }

    /// Another team's (or no team's) framework in a signed app is an addition; the app's own
    /// framework isn't.
    @Test func aFrameworkOfAnotherTeamIsAnAddition() throws {
        try withTempDir { dir in
            let main = ContentMachO.build(loads: [L(name: "@rpath/Own.framework/Own"), L(name: "@rpath/Other.framework/Other"),
                                                  L(name: "@rpath/Unsigned.framework/Unsigned")],
                                          rpaths: ["@executable_path/Frameworks"], team: "TEAM111111", filetype: 2)
            let other = ContentMachO.build(team: "TEAM222222")
            let app = try makeApp(dir, main: main, files: [
                "Frameworks/Own.framework/Own": ContentMachO.build(team: "TEAM111111"),
                "Frameworks/Other.framework/Other": other,
                "Frameworks/Other.framework/Info.plist": try PropertyListSerialization.data(
                    fromPropertyList: ["CFBundleIdentifier": "com.other.lib", "CFBundleName": "Other Lib"], format: .xml, options: 0),
                "Frameworks/Unsigned.framework/Unsigned": ContentMachO.build(signed: false),
            ])
            let additions = scan(app).additions
            #expect(additions.map(\.name) == ["Other Lib", "Unsigned"])
            #expect(additions.first?.hasMetadata == true)
            #expect(additions.last?.hasMetadata == false)
            // Without a team on the main executable, frameworks aren't judged by team.
            let unsignedMain = ContentMachO.build(loads: [L(name: "@rpath/Other.framework/Other")],
                                                  rpaths: ["@executable_path/Frameworks"], signed: false, filetype: 2)
            try unsignedMain.write(to: app.appendingPathComponent("Demo"))
            #expect(scan(app).additions.isEmpty)
        }
    }

    /// On an unsigned/ad-hoc IPA (no team to trust) a loose dylib named after a Swift runtime
    /// module proves nothing by its name: it is listed like any other loose dylib, and its warning
    /// signs are computed (review 2, T2-1).
    @Test func aFakeSwiftRuntimeLibInAnUnsignedIPAIsAnAddition() throws {
        try withTempDir { dir in
            let main = ContentMachO.build(loads: [L(name: "@executable_path/libswiftARKit.dylib")],
                                          signed: false, filetype: 2)
            let fake = ContentMachO.build(strings: ["https://discord.com/api/webhooks/1/abc"], signed: false)
            let app = try makeApp(dir, main: main, files: ["libswiftARKit.dylib": fake])
            let additions = scan(app).additions
            #expect(additions.map(\.name) == ["libswiftARKit.dylib"])
            #expect(additions.first?.signs == [.discordWebhook])
        }
    }

    /// A loose dylib signed by the app's own team on a signed IPA is the app's own (a real Swift
    /// runtime or a plain bundled lib): not an addition (review 2, T2-2).
    @Test func aLooseDylibOfTheAppsOwnTeamIsNotAnAddition() throws {
        try withTempDir { dir in
            let main = ContentMachO.build(loads: [L(name: "@executable_path/libextra.dylib"),
                                                  L(name: "@executable_path/libswiftARKit.dylib")],
                                          team: "TEAM111111", filetype: 2)
            let app = try makeApp(dir, main: main, files: [
                "libextra.dylib": ContentMachO.build(team: "TEAM111111"),
                "libswiftARKit.dylib": ContentMachO.build(team: "TEAM111111"),
            ])
            #expect(scan(app).additions.isEmpty)
        }
    }

    /// A loose dylib signed by the app's own team is still listed when it shows a warning sign:
    /// a team-id match from the IPA's own signature isn't proof of origin (a repackager re-signs
    /// the payload), so a disguised dylib can't hide behind it (security review of T2-1/T2-2).
    @Test func aSameTeamLooseDylibWithASignIsAnAddition() throws {
        try withTempDir { dir in
            let main = ContentMachO.build(loads: [L(name: "@executable_path/libswiftARKit.dylib")],
                                          team: "TEAM111111", filetype: 2)
            let payload = ContentMachO.build(strings: ["https://discord.com/api/webhooks/9/z"], team: "TEAM111111")
            let app = try makeApp(dir, main: main, files: ["libswiftARKit.dylib": payload])
            let additions = scan(app).additions
            #expect(additions.map(\.name) == ["libswiftARKit.dylib"])
            #expect(additions.first?.signs == [.discordWebhook])
        }
    }

    @Test func knownTweakFrameworksAreAdditionsWhateverTheirTeam() throws {
        try withTempDir { dir in
            let names = ["Cephei", "Orion", "ElleKit"]
            let main = ContentMachO.build(loads: names.map { L(name: "@rpath/\($0).framework/\($0)") },
                                          rpaths: ["@executable_path/Frameworks"], team: "TEAM111111", filetype: 2)
            var files: [String: Data] = [:]
            for n in names { files["Frameworks/\(n).framework/\(n)"] = ContentMachO.build(team: "TEAM111111") }
            let app = try makeApp(dir, main: main, files: files)
            let additions = scan(app).additions
            #expect(additions.map(\.name) == names)
            #expect(additions.allSatisfy { $0.kind == .tweakLibrary })
        }
    }

    /// Paths that leave the bundle, symlinks out of it, loops between libraries and huge load
    /// lists: nothing outside the app is read, and the scan ends.
    @Test func hostileLoadsStayInsideTheBundleAndEnd() throws {
        try withTempDir { dir in
            let outside = dir.appendingPathComponent("outside.dylib")
            try ContentMachO.build(signed: false).write(to: outside)
            var loads = [L(name: "@executable_path/../../outside.dylib"), L(name: "@rpath/../../../outside.dylib"),
                         L(name: "@executable_path/link.dylib"), L(name: "@executable_path/a.dylib"),
                         L(name: outside.path), L(name: "@executable_path/missing.dylib"),
                         L(name: "@executable_path/Info.plist")]
            for i in 0..<600 { loads.append(L(name: "@executable_path/n\(i).dylib")) }
            let main = ContentMachO.build(loads: loads, rpaths: ["@executable_path/../.."], signed: false, filetype: 2)
            let a = ContentMachO.build(loads: [L(name: "@loader_path/b.dylib")], signed: false)
            let b = ContentMachO.build(loads: [L(name: "@loader_path/a.dylib"), L(name: "@loader_path/b.dylib")], signed: false)
            var files = ["a.dylib": a, "b.dylib": b]
            for i in 0..<600 { files["n\(i).dylib"] = ContentMachO.build(signed: false) }
            let app = try makeApp(dir, main: main, files: files)
            try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("link.dylib"), withDestinationURL: outside)
            let additions = scan(app).additions
            #expect(!additions.contains { $0.path.contains("outside") || $0.path.contains("link") })
            #expect(additions.first?.path == "a.dylib")
            #expect(additions.count <= IPAContentScanner.maxAdditions)
        }
    }

    @Test func garbageFilesNeverTrap() throws {
        try withTempDir { dir in
            let main = ContentMachO.build(loads: [L(name: "@executable_path/x.dylib"), L(name: "@executable_path/y.dylib")],
                                          signed: false, filetype: 2)
            var truncated = ContentMachO.build(loads: [L(name: "@loader_path/x.dylib")], imports: ["_dlopen"], strings: ["discord.com/api/webhooks/1"])
            truncated = truncated.prefix(40)
            let app = try makeApp(dir, main: main, files: ["x.dylib": Data(repeating: 0xCF, count: 100), "y.dylib": truncated])
            _ = scan(app)
            try Data([0xCF, 0xFA]).write(to: app.appendingPathComponent("Demo"))
            #expect(scan(app).additions.isEmpty)
            try FileManager.default.removeItem(at: app.appendingPathComponent("Demo"))
            #expect(scan(app).additions.isEmpty)
        }
    }

    // MARK: warning signs

    private func signs(_ addition: Data, kindStrings: [String] = []) throws -> [WarningSign] {
        try withTempDir { dir in
            let main = ContentMachO.build(loads: [L(name: "@executable_path/libhelper.dylib")], signed: false, filetype: 2)
            let app = try makeApp(dir, main: main, files: ["libhelper.dylib": addition])
            return scan(app).additions.first?.signs ?? []
        }
    }

    @Test func exfiltrationEndpointsAreSigns() throws {
        #expect(try signs(ContentMachO.build(strings: ["https://discord.com/api/webhooks/123/abc"], signed: false)) == [.discordWebhook])
        #expect(try signs(ContentMachO.build(strings: ["https://discordapp.com/api/webhooks/1"], signed: false)) == [.discordWebhook])
        #expect(try signs(ContentMachO.build(strings: ["https://api.telegram.org/bot%@/sendMessage"], signed: false)) == [.telegramBot])
        #expect(try signs(ContentMachO.build(strings: ["https://pastebin.com/raw/xyz"], signed: false)) == [.pasteSite])
        #expect(try signs(ContentMachO.build(strings: ["https://abcd.ngrok-free.app/x", "https://webhook.site/u"], signed: false)) == [.tunnel])
        #expect(try signs(ContentMachO.build(strings: ["http://45.12.8.200:8080/upload"], signed: false)) == [.rawIP])
        // A local or private address, a link to a Telegram channel, a plain https site: nothing.
        #expect(try signs(ContentMachO.build(strings: ["http://127.0.0.1:8080/", "http://192.168.1.4:80/", "http://10.0.0.1:1/",
                                                       "https://t.me/kamohacks", "https://sponsor.ajay.app", "1.2.3.4:5",
                                                       // a public suffix list
                                                       "ngrok.io", "*.ngrok.io", "webhook.site"],
                                             signed: false)).isEmpty)
    }

    /// A paste site is a sign only in a raw/paste path form, not a bare domain mention: a tweak
    /// that merely links to hastebin.com isn't flagged (review 2, T2-3).
    @Test func hastebinIsASignOnlyWithAPastePath() throws {
        #expect(try signs(ContentMachO.build(strings: ["https://hastebin.com/raw/abc"], signed: false)) == [.pasteSite])
        // An upload/API path (how data is exfiltrated to a paste site) fires too, not only /raw.
        #expect(try signs(ContentMachO.build(strings: ["https://hastebin.com/documents"], signed: false)) == [.pasteSite])
        #expect(try signs(ContentMachO.build(strings: ["https://pastebin.com/api/api_post.php"], signed: false)) == [.pasteSite])
        #expect(try signs(ContentMachO.build(strings: ["see hastebin.com for details"], signed: false)).isEmpty)
    }

    /// Reading the keychain, the pasteboard or cookies is common (a tweak keeping its settings):
    /// a sign only in an unknown addition, or one that also writes to an exfiltration address.
    @Test func dataReadsAreSignsOnlyWhenSuspicious() throws {
        let keychain = ["_SecItemCopyMatching"]
        let hooks = ["_MSHookMessageEx"]
        #expect(try signs(ContentMachO.build(imports: keychain, signed: false)) == [.keychain])
        #expect(try signs(ContentMachO.build(imports: keychain + hooks, signed: false)).isEmpty)
        #expect(try signs(ContentMachO.build(imports: keychain + hooks, strings: ["https://discord.com/api/webhooks/1"],
                                             signed: false)) == [.discordWebhook, .keychain])
        let cookies = ContentMachO.build(imports: ["_OBJC_CLASS_$_NSHTTPCookieStorage"],
                                         strings: ["sharedHTTPCookieStorage", "cookies"], signed: false)
        #expect(try signs(cookies) == [.cookies])
        let pasteboard = ContentMachO.build(imports: ["_OBJC_CLASS_$_UIPasteboard"],
                                            strings: ["generalPasteboard", "string", "changeCount"], signed: false)
        #expect(try signs(pasteboard) == [.pasteboard])
        // Copying a link (generalPasteboard + setString:) isn't watching the pasteboard.
        let copy = ContentMachO.build(imports: ["_OBJC_CLASS_$_UIPasteboard"], strings: ["generalPasteboard", "setString:"], signed: false)
        #expect(try signs(copy).isEmpty)
    }

    @Test func downloadingAndRunningCodeIsASign() throws {
        let runs = ContentMachO.build(imports: ["_dlopen"], strings: ["downloadTaskWithURL:completionHandler:", "Documents"], signed: false)
        #expect(try signs(runs) == [.remoteCode])
        let loadsOwn = ContentMachO.build(imports: ["_dlopen"], strings: ["Documents"], signed: false)
        #expect(try signs(loadsOwn).isEmpty)
        // A tweak that downloads and loads code: a sign only with an address to send things to.
        let tweak = ContentMachO.build(imports: ["_dlopen", "_MSHookMessageEx"],
                                       strings: ["downloadTaskWithURL:completionHandler:", "Documents"], signed: false)
        #expect(try signs(tweak).isEmpty)
        let stealer = ContentMachO.build(imports: ["_dlopen", "_MSHookMessageEx"],
                                         strings: ["downloadTaskWithURL:completionHandler:", "Documents", "https://webhook.site/x"],
                                         signed: false)
        #expect(try signs(stealer) == [.tunnel, .remoteCode])
    }

    // MARK: accesses

    @Test func accessesComeFromUsageKeysAndEntitlements() throws {
        try withTempDir { dir in
            let app = try makeApp(dir, main: ContentMachO.build(signed: false, filetype: 2), plist: [
                "NSCameraUsageDescription": "x", "NSMicrophoneUsageDescription": "x", "NSPhotoLibraryAddUsageDescription": "x",
                "NSLocationWhenInUseUsageDescription": "x", "NSLocationAlwaysAndWhenInUseUsageDescription": "x",
                "NSBonjourServices": ["_x._tcp"], "NSContactsUsageDescription": 3, "NSFaceIDUsageDescription": "",
            ])
            #expect(scan(app, entitlements: ["aps-environment": "production"]).accesses
                    == [.notifications, .camera, .microphone, .photos, .location, .localNetwork])
            #expect(scan(app).accesses == [.camera, .microphone, .photos, .location, .localNetwork])
        }
    }

    // MARK: storage

    @Test func roundTripsAndOlderOrDamagedRecordsStillLoad() throws {
        let content = IPAContent(additions: [IPAAddition(name: "T", path: "Frameworks/T.dylib", size: 3, load: .indirect,
                                                         loadedBy: "U", kind: .tweak, hasMetadata: false, signs: [.keychain])],
                                 accesses: [.camera])
        let data = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode(IPAContent.self, from: data) == content)
        #expect(content.isCurrent)

        let base = #"{"id":"6B1B5B56-6A3B-4C0B-9C52-2B8F0E4E9A10","originalBundleID":"com.x","ipaPath":"apps/x/original.ipa""#
        #expect(try JSONDecoder().decode(AppRecord.self, from: Data((base + "}").utf8)).content == nil)
        let damaged = try JSONDecoder().decode(AppRecord.self, from: Data((base + #","content":{"additions":"no"}}"#).utf8))
        #expect(damaged.content == nil)
        // A sign or access a newer XSide wrote is dropped, the rest kept.
        let newer = #","content":{"version":1,"additions":[{"name":"T","path":"T.dylib","size":1,"load":"later","kind":"x","hasMetadata":true,"signs":["future","keychain"]}],"accesses":["teleport","camera"]}}"#
        let record = try JSONDecoder().decode(AppRecord.self, from: Data((base + newer).utf8))
        #expect(record.content?.accesses == [.camera])
        #expect(record.content?.additions.first?.signs == [.keychain])
        #expect(record.content?.additions.first?.kind == .unknown)
    }

    @Test func theLibraryKeepsTheContent() async throws {
        try await withTemporaryDirectory { dir in
            let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
            let ipa = dir.appendingPathComponent("a.ipa")
            try Data("x".utf8).write(to: ipa)
            let content = IPAContent(additions: [], accesses: [.microphone])
            let info = AppInfo(bundleID: "com.example.a", name: "A", version: nil, executable: "A", content: content)
            let record = try await lib.importIPA(ipa, info: info, teamID: "TEAM123456")
            #expect(record.content == content)
            let later = IPAContent(additions: [], accesses: [.camera])
            try await lib.setContent(later, for: record.id)
            #expect(await lib.records().first?.content == later)
            let reloaded = AppLibrary(root: dir.appendingPathComponent("lib"))
            #expect(await reloaded.records().first?.content == later)
        }
    }
}

private func withTempDir<T>(_ body: (URL) throws -> T) throws -> T {
    let dir = TestTemp.root.appendingPathComponent("content-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}
