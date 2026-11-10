import Foundation
import Testing
@testable import XSideCore

/// Device round 3, R3-3: « Désinstaller… » a downloaded dependency from some app × device
/// installations (the sheet is grouped by device), the tweaks it leaves without it turned off
/// there with the reason, the file deleted once no installation uses it; and the automatic
/// cleanup when a tweak is removed from an app.
struct DownloadUninstallTests {
    typealias D = DependencyDirectoryTests

    /// A library with one kept Cephei download, used by YouTube on the iPhone and the iPad (and
    /// by Instagram on the iPhone), each with a tweak that needs it.
    private struct Setup {
        let lib: AppLibrary
        let sha: String
        let youtube: AppRecord
        let instagram: AppRecord
        /// Pool ids: YouTube's Cephei and its tweak, Instagram's Cephei and its tweak.
        let ytCephei: String, ytTweak: String, igCephei: String, igTweak: String
        var file: String { lib.root.appendingPathComponent("downloads/\(sha).deb").path }
    }

    private static func deb(_ dir: URL, _ control: String, _ path: String) async throws -> URL {
        let u = dir.appendingPathComponent(UUID().uuidString + ".deb")
        try await FakeDeb.deb(control: control, files: [.file(path, FakeIPA.dylibMachO(linking: [], padding: 64, strings: [path]))],
                              compression: "gz").write(to: u)
        return u
    }

    private static func app(_ lib: AppLibrary, _ dir: URL, _ name: String) async throws -> AppRecord {
        let ipa = dir.appendingPathComponent("\(name).ipa")
        try Data(name.utf8).write(to: ipa)
        return try await lib.importIPA(ipa, info: AppInfo(bundleID: "com.example.\(name.lowercased())", name: name, version: "1.0",
                                                          executable: name), teamID: "TEAM123456")
    }

    /// Installs `record` on `devices` with the lists chosen so far (pending → installation),
    /// signed with those lists when `signed`.
    private static func install(_ lib: AppLibrary, _ record: AppRecord, on devices: [String], signed: Bool) async throws {
        let pending = await lib.records().first { $0.id == record.id }?.pendingTweakUses ?? [:]
        for d in devices {
            var i = Installation(deviceID: d, installedAt: Date(), expiresAt: Date().addingTimeInterval(86_400))
            i.tweaks = pending[d] ?? []
            if signed {
                i.signedChoices = SigningChoices(withoutXSideFeatures: false, duoCompatibility: false, iCloudSignedOut: false,
                                                 tweaks: i.enabledTweakIDs)
            }
            _ = try await lib.recordSigning(i, for: record.id, requireExisting: false)
        }
    }

    private static func setup(_ dir: URL, signed: Bool = false) async throws -> Setup {
        let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
        let bytes = Data("cephei 1.17.1".utf8)
        let f = dir.appendingPathComponent("f")
        try bytes.write(to: f)
        let sha = RepoClientTests.sha256(bytes)
        _ = try await lib.storeDownload(f, sha256: sha, packageID: "ws.hbang.common", version: "1.17.1", repo: "chariz", url: "u")
        let cephei = "Package: ws.hbang.common\nName: Cephei\nVersion: 1.17.1\n"
        let origin = TweakOrigin.downloaded(repo: "chariz", url: "u", sha256: sha)
        // Needs an unknown package (no ❌ without it, but « missing » there): the generic case.
        let yt = try await app(lib, dir, "YouTube"), ig = try await app(lib, dir, "Instagram")
        let ytC = try await lib.addTweak(try await deb(dir, cephei, "./usr/lib/libc.dylib"), origin: origin, recordID: yt.id,
                                         deviceIDs: ["iphone", "ipad"], runner: ProcessRunner(), now: Date()).package
        let ytT = try await lib.addTweak(try await deb(dir, "Package: com.example.dislike\nName: Return YouTube Dislike\nDepends: ws.hbang.common\n",
                                                       "./usr/lib/d.dylib"),
                                         recordID: yt.id, deviceIDs: ["iphone", "ipad"], runner: ProcessRunner(), now: Date()).package
        let igC = try await lib.addTweak(try await deb(dir, cephei, "./usr/lib/libc.dylib"), origin: origin, recordID: ig.id,
                                         deviceIDs: ["iphone"], runner: ProcessRunner(), now: Date()).package
        let igT = try await lib.addTweak(try await deb(dir, "Package: com.example.rocket\nName: Rocket\nDepends: ws.hbang.common\n",
                                                       "./usr/lib/r.dylib"),
                                         recordID: ig.id, deviceIDs: ["iphone"], runner: ProcessRunner(), now: Date()).package
        try await install(lib, yt, on: ["iphone", "ipad"], signed: signed)
        try await install(lib, ig, on: ["iphone"], signed: signed)
        return Setup(lib: lib, sha: sha, youtube: yt, instagram: ig,
                     ytCephei: ytC.id, ytTweak: ytT.id, igCephei: igC.id, igTweak: igT.id)
    }

    private static func uses(_ lib: AppLibrary, _ record: AppRecord, _ device: String) async -> [TweakUse] {
        await lib.records().first { $0.id == record.id }?.installations.first { $0.deviceID == device }?.tweaks ?? []
    }

    @Test func theUsageListsEachInstallationWithItsTweaks() async throws {
        try await withTemporaryDirectory("uninstall-usage") { dir in
            let s = try await Self.setup(dir)
            let usage = try #require(await s.lib.downloadUsage().first)
            #expect(usage.installations == [
                DownloadInstallation(recordID: s.instagram.id, app: "Instagram", deviceID: "iphone", tweaks: ["Rocket"]),
                DownloadInstallation(recordID: s.youtube.id, app: "YouTube", deviceID: "iphone", tweaks: ["Return YouTube Dislike"]),
                DownloadInstallation(recordID: s.youtube.id, app: "YouTube", deviceID: "ipad", tweaks: ["Return YouTube Dislike"]),
            ].sorted { ($0.deviceID, $0.app) < ($1.deviceID, $1.app) })
        }
    }

    /// From the iPad only: the iPad's YouTube loses Cephei and its tweak is off with the reason;
    /// the iPhone keeps both apps' use; the file stays on the Mac.
    @Test func uninstallingFromOneDeviceKeepsTheFileAndTheOtherDevicesUse() async throws {
        try await withTemporaryDirectory("uninstall-one") { dir in
            let s = try await Self.setup(dir)
            let target = DownloadInstallation.Key(recordID: s.youtube.id, deviceID: "ipad")
            let deleted = try await s.lib.uninstallDownload(sha256: s.sha, from: [target],
                                                            disabling: [target: [s.ytTweak]], name: "Cephei")
            #expect(deleted == false)
            #expect(FileManager.default.fileExists(atPath: s.file))
            let pad = await Self.uses(s.lib, s.youtube, "ipad")
            #expect(!pad.contains { $0.id == s.ytCephei })
            #expect(pad.first { $0.id == s.ytTweak } == TweakUse(id: s.ytTweak, enabled: false, removedDependency: "Cephei"))
            // The iPhone: untouched in both apps.
            let phone = await Self.uses(s.lib, s.youtube, "iphone")
            #expect(phone == [TweakUse(id: s.ytCephei), TweakUse(id: s.ytTweak)])
            #expect(await Self.uses(s.lib, s.instagram, "iphone") == [TweakUse(id: s.igCephei), TweakUse(id: s.igTweak)])
            let usage = try #require(await s.lib.downloadUsage().first)
            #expect(usage.installations.map(\.deviceID) == ["iphone", "iphone"])
        }
    }

    /// From every installation: gone from all lists, the tweaks off with the reason, the file deleted.
    @Test func uninstallingEverywhereDeletesTheFile() async throws {
        try await withTemporaryDirectory("uninstall-all") { dir in
            let s = try await Self.setup(dir, signed: true)
            let keys = [DownloadInstallation.Key(recordID: s.youtube.id, deviceID: "iphone"),
                        DownloadInstallation.Key(recordID: s.youtube.id, deviceID: "ipad"),
                        DownloadInstallation.Key(recordID: s.instagram.id, deviceID: "iphone")]
            let disabling = [keys[0]: Set([s.ytTweak]), keys[1]: [s.ytTweak], keys[2]: [s.igTweak]]
            let deleted = try await s.lib.uninstallDownload(sha256: s.sha, from: Set(keys), disabling: disabling, name: "Cephei")
            #expect(deleted)
            #expect(!FileManager.default.fileExists(atPath: s.file))
            #expect(await s.lib.downloadUsage().isEmpty)
            for (record, device, tweak) in [(s.youtube, "iphone", s.ytTweak), (s.youtube, "ipad", s.ytTweak),
                                            (s.instagram, "iphone", s.igTweak)] {
                #expect(await Self.uses(s.lib, record, device) == [TweakUse(id: tweak, enabled: false, removedDependency: "Cephei")])
                // Signed with it: the change waits for the next signing.
                let i = try #require(await s.lib.records().first { $0.id == record.id }?.installations.first { $0.deviceID == device })
                #expect(i.pendingSigningChanges(wantsWithoutXSideFeatures: false).contains(.tweaks))
            }
        }
    }

    @Test func aBadHashOrAnUnusedTargetChangesNothing() async throws {
        try await withTemporaryDirectory("uninstall-bad") { dir in
            let s = try await Self.setup(dir)
            let before = await s.lib.records()
            #expect(try await s.lib.uninstallDownload(sha256: "../x", from: [.init(recordID: s.youtube.id, deviceID: "ipad")],
                                                      disabling: [:], name: "Cephei") == false)
            #expect(try await s.lib.uninstallDownload(sha256: s.sha, from: [.init(recordID: UUID(), deviceID: "ipad")],
                                                      disabling: [:], name: "Cephei") == false)
            #expect(await s.lib.records() == before)
            #expect(FileManager.default.fileExists(atPath: s.file))
        }
    }

    /// Turning the tweak back on clears the reason (it then shows « À régler » as usual).
    @Test func reEnablingATweakClearsTheReason() async throws {
        try await withTemporaryDirectory("uninstall-reenable") { dir in
            let s = try await Self.setup(dir)
            let target = DownloadInstallation.Key(recordID: s.youtube.id, deviceID: "ipad")
            _ = try await s.lib.uninstallDownload(sha256: s.sha, from: [target], disabling: [target: [s.ytTweak]], name: "Cephei")
            var list = await Self.uses(s.lib, s.youtube, "ipad")
            list[0].enabled = true
            try await s.lib.setTweaks(list, recordID: s.youtube.id, deviceID: "ipad")
            #expect(await Self.uses(s.lib, s.youtube, "ipad") == [TweakUse(id: s.ytTweak)])
        }
    }

    /// Device round 3: the automatic cleanup also runs when a tweak is removed from an app.
    @Test func removingATweakDeletesADownloadNoOneUsesAndKeepsOneStillUsed() async throws {
        try await withTemporaryDirectory("uninstall-retire") { dir in
            let s = try await Self.setup(dir)
            // A second download only YouTube uses (on the iPad).
            let bytes = Data("altlist".utf8)
            let f = dir.appendingPathComponent("g")
            try bytes.write(to: f)
            let alt = RepoClientTests.sha256(bytes)
            _ = try await s.lib.storeDownload(f, sha256: alt, packageID: "com.opa334.altlist", version: "1.0", repo: "chariz", url: "u")
            let altPkg = try await s.lib.addTweak(try await Self.deb(dir, "Package: com.opa334.altlist\nName: AltList\nVersion: 1.0\n",
                                                                     "./usr/lib/libalt.dylib"),
                                                  origin: .downloaded(repo: "chariz", url: "u", sha256: alt), recordID: s.youtube.id,
                                                  deviceIDs: ["ipad"], runner: ProcessRunner(), now: Date()).package
            let altFile = s.lib.root.appendingPathComponent("downloads/\(alt).deb").path
            #expect(FileManager.default.fileExists(atPath: altFile))
            // « Retirer » AltList and Cephei on the iPad: AltList no one uses goes, Cephei (iPhone) stays.
            let pad = await Self.uses(s.lib, s.youtube, "ipad").filter { $0.id != altPkg.id && $0.id != s.ytCephei }
            try await s.lib.setTweaks(pad, recordID: s.youtube.id, deviceID: "ipad")
            #expect(!FileManager.default.fileExists(atPath: altFile))
            #expect(FileManager.default.fileExists(atPath: s.file))
        }
    }

    // MARK: F3: « Utilisée par » is real use; signed or not, the file goes once no list has it

    private static func retire(_ s: Setup, _ record: AppRecord, _ device: String, _ ids: Set<String>) async throws {
        let list = await uses(s.lib, record, device).filter { !ids.contains($0.id) }
        try await s.lib.setTweaks(list, recordID: record.id, deviceID: device)
    }

    @Test func aCopyRemovedWithItsTweakGoesWhetherOrNotTheAppWasSigned() async throws {
        for signed in [false, true] {
            try await withTemporaryDirectory("retire-\(signed)") { dir in
                let s = try await Self.setup(dir, signed: signed)
                // YouTube's tweak and its Cephei gone from both devices: Instagram still uses it.
                try await Self.retire(s, s.youtube, "ipad", [s.ytTweak, s.ytCephei])
                try await Self.retire(s, s.youtube, "iphone", [s.ytTweak, s.ytCephei])
                #expect(FileManager.default.fileExists(atPath: s.file))
                let usage = try #require(await s.lib.downloadUsage().first)
                #expect(usage.apps == ["Instagram"])
                #expect(usage.users.map(\.app) == ["Instagram"])
                #expect(usage.installations.map(\.app) == ["Instagram"])
                // Instagram's too: nothing lists it any more, the file goes.
                try await Self.retire(s, s.instagram, "iphone", [s.igTweak, s.igCephei])
                #expect(!FileManager.default.fileExists(atPath: s.file), "signed: \(signed)")
                #expect(await s.lib.downloadUsage().isEmpty)
            }
        }
    }

    // MARK: Which tweaks go off, and their group

    @Test func theTweaksLeftWithoutItAreTheOnesTurnedOff() {
        let need = DebDependency(package: "ws.hbang.common", relation: ">=", version: "1.0")
        let tweak = D.tweak(depends: [[need]])
        let cephei = D.dependencyPackage("ws.hbang.common", name: "Cephei", version: "1.17.1")
        let plain = TweakPackage(id: "00000000000000cc", kind: .deb, origin: .added, packageID: "com.example.plain", name: "Plain",
                                 addedAt: Date(timeIntervalSince1970: 0))
        #expect(DependencyRows.disabledByUninstalling([cephei], enabled: [tweak, cephei, plain], context: D.context([])).map(\.id)
                == [tweak.id])
        // Another version still there: nothing goes off.
        var other = D.dependencyPackage("ws.hbang.common", name: "Cephei", version: "1.16")
        other = TweakPackage(id: "00000000000000dd", kind: other.kind, origin: other.origin, packageID: other.packageID,
                             name: other.name, version: other.version, files: other.files, binaries: other.binaries,
                             addedAt: other.addedAt)
        #expect(DependencyRows.disabledByUninstalling([cephei], enabled: [tweak, cephei, other], context: D.context([])).isEmpty)
        #expect(DependencyRows.disabledByUninstalling([cephei], enabled: [], context: D.context([])).isEmpty)
    }

    /// Off because the person removed its dependency: never « À régler ».
    @Test func aTweakOffBecauseItsDependencyWasRemovedIsNotToSettle() {
        let missing = TweakVerdict.incompatible(.missingDependency("Cephei"))
        #expect(TweakGroups.group([.init(verdict: missing, isOn: false, isForced: false, missingDependencies: ["ws.hbang.common"],
                                         dependencyRemoved: true)]) == .ready)
        // Turned back on: as usual.
        #expect(TweakGroups.group([.init(verdict: missing, isOn: true, isForced: false, missingDependencies: ["ws.hbang.common"],
                                         dependencyRemoved: true)]) == .toSettle)
        #expect(TweakGroups.group([.init(verdict: missing, isOn: false, isForced: false,
                                         missingDependencies: ["ws.hbang.common"])]) == .toSettle)
    }
}
