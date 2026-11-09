import Foundation
import Testing
@testable import XSideCore

/// Where a downloaded or added dependency goes, which tweaks it is a dependency of, what removing
/// it breaks, its updates, and the kept downloads across apps.
struct DependencyManagementTests {
    typealias D = DependencyDirectoryTests
    static let cepheiNeed = DebDependency(package: "ws.hbang.common", relation: ">=", version: "1.0")

    // MARK: Placement (the 2026-11-09 bug: a tweak ❌ for want of Cephei is off everywhere, so
    // « where the tweak is on » was nowhere and the downloaded Cephei was turned on nowhere)

    @Test func aTweakOffBecauseItsLibraryIsMissingGetsItAndIsTurnedOn() {
        let tweak = D.tweak(depends: [[Self.cepheiNeed]])
        let cephei = D.dependencyPackage("ws.hbang.common", name: "Cephei", version: "1.17.1")
        // ❌ on both (Cephei missing), so its switch is off on both.
        let plan = DependencyPlacement.plan(tweak: tweak, adding: cephei, devices: [
            .init(id: "iphone", context: D.context([]), tweakOn: false),
            .init(id: "ipad", context: D.context([]), tweakOn: false),
        ])
        #expect(plan.dependencyOn == ["iphone", "ipad"])
        #expect(plan.tweakTurnedOn == ["iphone", "ipad"])
    }

    @Test func aTweakTurnedOffByThePersonStaysOffAndGetsNoDependencyThere() {
        let need = DebDependency(package: "com.example.helper")
        let tweak = D.tweak(depends: [[need]])
        let helper = D.dependencyPackage("com.example.helper", name: "Helper", version: "1.0")
        // An unknown package: no ❌, so an off switch is the person's choice.
        let plan = DependencyPlacement.plan(tweak: tweak, adding: helper, devices: [
            .init(id: "iphone", context: D.context([]), tweakOn: true),
            .init(id: "ipad", context: D.context([]), tweakOn: false),
        ])
        #expect(plan.dependencyOn == ["iphone"])
        #expect(plan.tweakTurnedOn.isEmpty)
        // Off everywhere by choice: it still goes where it is missing, so the sheet says it's there.
        let nowhere = DependencyPlacement.plan(tweak: tweak, adding: helper, devices: [
            .init(id: "iphone", context: D.context([]), tweakOn: false),
            .init(id: "ipad", context: D.context([helper]), tweakOn: false),
        ])
        #expect(nowhere.dependencyOn == ["iphone"])
        #expect(nowhere.tweakTurnedOn.isEmpty)
    }

    @Test func aDependencyThatDoesNotUnblockTheTweakDoesNotTurnItOn() {
        // Too old for the tweak: the tweak stays ❌ and off.
        let tweak = D.tweak(depends: [[DebDependency(package: "ws.hbang.common", relation: ">=", version: "2.0")]])
        let old = D.dependencyPackage("ws.hbang.common", name: "Cephei", version: "1.17.1")
        let plan = DependencyPlacement.plan(tweak: tweak, adding: old, devices: [
            .init(id: "iphone", context: D.context([]), tweakOn: false),
        ])
        #expect(plan.tweakTurnedOn.isEmpty)
        #expect(plan.dependencyOn == ["iphone"]) // missing there: it goes where it is asked for
        #expect(DependencyPlacement.plan(tweak: tweak, adding: old, devices: []).dependencyOn.isEmpty)
    }

    /// Fake fetcher end to end: « Télécharger » → kept → analysed → it is Cephei → placed → the
    /// sheet's status reads « Ajoutée par toi » and the tweak is no longer ❌.
    @Test func downloadThenAddThenStatusIsAddedByYou() async throws {
        try await withTemporaryDirectory("deps-e2e") { dir in
            let control = "Package: ws.hbang.common\nName: Cephei\nVersion: 1.17.1\nArchitecture: iphoneos-arm\n"
            let deb = try await FakeDeb.deb(control: control,
                                            files: [.file("./usr/lib/libcephei.dylib", FakeIPA.dylibMachO(linking: [], padding: 64))],
                                            compression: "lzma")
            let fetcher = FakeFetcher()
            var p = RepoClientTests.Pkg("1.17.1", arch: "iphoneos-arm", deb: deb)
            p.package = RepoClientTests.cephei
            let idx = Data(p.stanza.utf8)
            fetcher.serve(RepoClientTests.chariz + "Release", RepoClientTests.release([("Packages", idx)]))
            fetcher.serve(RepoClientTests.chariz + "Packages", idx)
            fetcher.serve(RepoClientTests.chariz + p.file, deb)
            let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
            let downloader = DependencyDownloader(library: lib, client: RepoClient(fetcher: fetcher, runner: ProcessRunner(),
                                                                                 workDir: dir.appendingPathComponent("work")))
            let source = try await downloader.prepare(Self.cepheiNeed, preferredArchitecture: "iphoneos-arm")
            let fetched = try await downloader.fetch(source)
            let package = try await TweakAnalyzer.analyze(fetched.file, into: dir.appendingPathComponent("staging"),
                                                          origin: fetched.origin, runner: ProcessRunner(), now: Date())
            #expect(DependencyDirectory.check(package, for: Self.cepheiNeed) == .matches)
            guard case .downloaded(let repo, _, _) = package.origin else { Issue.record("origin lost"); return }
            #expect(repo == "chariz")

            let tweak = D.tweak(depends: [[Self.cepheiNeed]])
            #expect(TweakClassifier.verdict(tweak, D.context([])) == .incompatible(.missingDependency("Cephei")))
            let plan = DependencyPlacement.plan(tweak: tweak, adding: package,
                                                devices: [.init(id: "iphone", context: D.context([]), tweakOn: false)])
            #expect(plan.dependencyOn == ["iphone"] && plan.tweakTurnedOn == ["iphone"])
            let after = D.context(plan.dependencyOn.contains("iphone") ? [package] : [])
            let rows = DependencyRows.rows(tweak, contexts: [("iphone", after)])
            #expect(rows.first?.statuses.first?.status == .addedByYou("Cephei"))
            #expect(rows.first?.statuses.first?.addedVersion == "1.17.1")
            #expect(!rows.contains { $0.isMissingAnywhere })
            if case .incompatible = TweakClassifier.verdict(tweak, after) { Issue.record("still ❌") }
            #expect(DependencyRows.dependents(of: package, among: [tweak, package]).map(\.id) == [tweak.id])
        }
    }

    // MARK: Cards

    @Test func dependentsAreTheTweaksThatAskForIt() {
        let cephei = D.dependencyPackage("ws.hbang.common", name: "Cephei", version: "1.17.1")
        let a = D.tweak(depends: [[Self.cepheiNeed]])
        var b = D.tweak(depends: [[DebDependency(package: "other"), DebDependency(package: "ws.hbang.common")]])
        b = TweakPackage(id: "00000000000000cc", kind: .deb, origin: .added, packageID: "com.example.b", name: "B",
                         depends: b.depends, addedAt: b.addedAt)
        let c = TweakPackage(id: "00000000000000dd", kind: .deb, origin: .added, packageID: "com.example.c", name: "C",
                             depends: [[DebDependency(package: "virtual-cephei")]], addedAt: b.addedAt)
        #expect(DependencyRows.dependents(of: cephei, among: [a, b, c, cephei]).map(\.name) == ["T", "B"])
        // Through Provides.
        let provider = TweakPackage(id: "00000000000000ee", kind: .deb, origin: .added, packageID: "com.x.cephei",
                                    provides: ["virtual-cephei"], name: "P", addedAt: b.addedAt)
        #expect(DependencyRows.dependents(of: provider, among: [a, c]).map(\.name) == ["C"])
        // Not its own dependent; a plain tweak has none.
        #expect(DependencyRows.dependents(of: a, among: [a, b]).isEmpty)
    }

    @Test func removingADependencyATweakNeedsSaysItBecomesIncompatible() {
        let cephei = D.dependencyPackage("ws.hbang.common", name: "Cephei", version: "1.17.1")
        let tweak = D.tweak(depends: [[Self.cepheiNeed]])
        // Enabled together on the device: removing Cephei makes the tweak ❌.
        #expect(DependencyRows.brokenByRemoving(cephei, enabled: [tweak, cephei], context: D.context([])).map(\.id) == [tweak.id])
        // The tweak isn't on there: nothing to warn about.
        #expect(DependencyRows.brokenByRemoving(cephei, enabled: [cephei], context: D.context([])).isEmpty)
        // Another copy still satisfies it: nothing breaks.
        var other = D.dependencyPackage("ws.hbang.common", name: "Cephei", version: "1.18")
        other = TweakPackage(id: "00000000000000ff", kind: other.kind, origin: .added, packageID: other.packageID,
                             name: other.name, version: other.version, files: other.files, binaries: other.binaries,
                             addedAt: other.addedAt)
        #expect(DependencyRows.brokenByRemoving(cephei, enabled: [tweak, cephei, other], context: D.context([])).isEmpty)
    }

    // MARK: « Mettre à jour »

    @Test func anUpdateIsANewerVersionThatStillSatisfiesTheTweak() async throws {
        try await withTemporaryDirectory("deps-update") { dir in
            let fetcher = FakeFetcher()
            let pkgs = ["1.17.1", "1.18", "2.1"].map { v -> RepoClientTests.Pkg in
                var p = RepoClientTests.Pkg(v, arch: "iphoneos-arm")
                p.package = RepoClientTests.cephei
                return p
            }
            let idx = RepoClientTests.index(pkgs)
            fetcher.serve(RepoClientTests.chariz + "Release", RepoClientTests.release([("Packages", idx)]))
            fetcher.serve(RepoClientTests.chariz + "Packages", idx)
            let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
            let downloader = DependencyDownloader(library: lib, client: RepoClient(fetcher: fetcher, runner: FakeRunner(),
                                                                                 workDir: dir.appendingPathComponent("work")))
            let below2 = DebDependency(package: "ws.hbang.common", relation: "<<", version: "2.0")
            let offer = try await downloader.update(below2, installed: "1.17.1", preferredArchitecture: "iphoneos-arm")
            #expect(offer?.version == "1.18")
            #expect(try await downloader.update(below2, installed: "1.18", preferredArchitecture: "iphoneos-arm") == nil)
            #expect(try await downloader.update(DebDependency(package: "ws.hbang.common"), installed: "1.18",
                                                preferredArchitecture: "iphoneos-arm")?.version == "2.1")
            // Even with a kept copy, the repo is asked (that's what the click is for).
            #expect(fetcher.fetched.count >= 2)
            await #expect(throws: RepoError.notAllowlisted) {
                try await downloader.update(DebDependency(package: "com.example.unknown"), installed: "1", preferredArchitecture: nil)
            }
        }
    }

    // MARK: Kept downloads across apps

    private func store(_ lib: AppLibrary, _ bytes: String, packageID: String, version: String, dir: URL) async throws -> String {
        let file = dir.appendingPathComponent(UUID().uuidString)
        let data = Data(bytes.utf8)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let sha = RepoClientTests.sha256(data)
        _ = try await lib.storeDownload(file, sha256: sha, packageID: packageID, version: version, repo: "chariz",
                                        url: "https://repo.chariz.com/debs/\(packageID)_\(version).deb")
        return sha
    }

    @Test func keptDownloadsListTheirUseAndOnlyUnusedOnesAreDeleted() async throws {
        try await withTemporaryDirectory("deps-usage") { dir in
            let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
            let used = try await store(lib, "cephei 1.17.1", packageID: "ws.hbang.common", version: "1.17.1", dir: dir)
            let unused = try await store(lib, "cephei 1.16", packageID: "ws.hbang.common", version: "1.16", dir: dir)
            let alsoUnused = try await store(lib, "altlist", packageID: "com.opa334.altlist", version: "1.0", dir: dir)

            // An app whose pool has the 1.17.1 download.
            let ipa = dir.appendingPathComponent("a.ipa")
            try Data("ipa".utf8).write(to: ipa)
            let rec = try await lib.importIPA(ipa, info: AppInfo(bundleID: "com.example.demo", name: "Demo", version: "1.0",
                                                                 executable: "Demo"), teamID: "TEAM123456")
            let debFile = dir.appendingPathComponent("c.deb")
            try await FakeDeb.deb(control: "Package: ws.hbang.common\nName: Cephei\nVersion: 1.17.1\n",
                                  files: [.file("./usr/lib/libcephei.dylib", FakeIPA.dylibMachO(linking: [], padding: 64))],
                                  compression: "gz").write(to: debFile)
            _ = try await lib.addTweak(debFile, origin: .downloaded(repo: "chariz", url: "u", sha256: used.uppercased()),
                                       recordID: rec.id, deviceIDs: [], runner: ProcessRunner(), now: Date())

            let usage = await lib.downloadUsage()
            #expect(usage.count == 3)
            let byID = Dictionary(uniqueKeysWithValues: usage.map { ($0.sha256, $0) })
            #expect(byID[used]?.apps == ["Demo"])
            #expect(byID[used]?.isUsed == true)
            #expect(byID[unused]?.apps == [])
            #expect(byID[unused]?.size == Int64("cephei 1.16".utf8.count))
            #expect(byID[unused]?.repoName == "Chariz")
            #expect(byID[alsoUnused]?.packageID == "com.opa334.altlist")
            // Newest first within a package, packages by id.
            #expect(usage.map(\.version) == ["1.0", "1.17.1", "1.16"])

            // One still in an app's pool is never deleted.
            #expect(await lib.removeUnusedDownload(sha256: used) == false)
            #expect(FileManager.default.fileExists(atPath: lib.root.appendingPathComponent("downloads/\(used).deb").path))
            #expect(await lib.removeUnusedDownload(sha256: "not-a-sha") == false)
            #expect(await lib.removeUnusedDownload(sha256: unused) == true)
            #expect(!FileManager.default.fileExists(atPath: lib.root.appendingPathComponent("downloads/\(unused).deb").path))

            let freed = await lib.removeUnusedDownloads()
            #expect(freed.count == 1 && freed.bytes == Int64("altlist".utf8.count))
            #expect(await lib.downloadUsage().map(\.sha256) == [used])
            #expect(await lib.removeUnusedDownloads().count == 0)
        }
    }
}

/// The compact Tweaks cards: device chips, card order, who uses a kept download.
struct TweakCardLogicTests {
    typealias D = DependencyDirectoryTests

    @Test func deviceChipsUseAShortName() {
        #expect(DeviceShortName.short("iPhone Duo de Anthony") == "iPhone Duo")
        #expect(DeviceShortName.short("Anthony's iPad Air 5") == "iPad Air 5")
        #expect(DeviceShortName.short("Anthony’s iPhone") == "iPhone")
        #expect(DeviceShortName.short("iPad d'Émilie") == "iPad")
        #expect(DeviceShortName.short("iPhone") == "iPhone")
        // Nothing left once trimmed, or no rule: the name as is, capped.
        #expect(DeviceShortName.short("de Anthony") == "de Anthony")
        #expect(DeviceShortName.short("  ") == "")
        #expect(DeviceShortName.short(String(repeating: "x", count: 40)) == String(repeating: "x", count: 19) + "…")
    }

    private static func pkg(_ id: String, _ packageID: String, depends: [String] = []) -> TweakPackage {
        TweakPackage(id: id, kind: .deb, origin: .added, packageID: packageID, name: packageID,
                     depends: depends.map { [DebDependency(package: $0)] }, addedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func dependencyCardsFollowTheFirstTweakThatNeedsThem() {
        let altlist = Self.pkg("a", "com.opa334.altlist")
        let cephei = Self.pkg("c", "ws.hbang.common")
        let u = Self.pkg("u", "uyouplus", depends: ["com.opa334.altlist", "ws.hbang.common"])
        let y = Self.pkg("y", "youpip", depends: ["ws.hbang.common"])
        let plain = Self.pkg("p", "plain")
        let orphan = Self.pkg("o", "com.example.lib")
        let order = DependencyRows.cardOrder([altlist, plain, u, orphan, cephei, y])
        #expect(order.map(\.package.id) == ["p", "u", "a", "c", "o", "y"]) // tweaks in load order
        #expect(order.map(\.dependencyOf) == [[], [], ["uyouplus"], ["uyouplus", "youpip"], [], []])
        // A dependency that itself needs another one: still after its own dependent.
        let lib = Self.pkg("l", "lib", depends: ["ws.hbang.common"])
        let t = Self.pkg("t", "t", depends: ["lib"])
        #expect(DependencyRows.cardOrder([cephei, lib, t]).map(\.package.id) == ["t", "l", "c"])
        #expect(DependencyRows.cardOrder([]).isEmpty)
    }

    @Test func aKeptDownloadSaysWhichTweaksUseItWhere() async throws {
        try await withTemporaryDirectory("deps-users") { dir in
            let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
            let bytes = Data("cephei".utf8)
            let file = dir.appendingPathComponent("f")
            try bytes.write(to: file)
            let sha = RepoClientTests.sha256(bytes)
            _ = try await lib.storeDownload(file, sha256: sha, packageID: "ws.hbang.common", version: "1.17.1", repo: "chariz", url: "u")
            let ipa = dir.appendingPathComponent("a.ipa")
            try Data("ipa".utf8).write(to: ipa)
            let rec = try await lib.importIPA(ipa, info: AppInfo(bundleID: "com.example.yt", name: "YouTube", version: "1",
                                                                 executable: "YT"), teamID: "TEAM123456")
            func deb(_ control: String, _ path: String) async throws -> URL {
                let u = dir.appendingPathComponent(UUID().uuidString + ".deb")
                try await FakeDeb.deb(control: control, files: [.file(path, FakeIPA.dylibMachO(linking: [], padding: 64, strings: [path]))],
                                      compression: "gz").write(to: u)
                return u
            }
            let cephei = try await lib.addTweak(try await deb("Package: ws.hbang.common\nName: Cephei\nVersion: 1.17.1\n", "./usr/lib/libc.dylib"),
                                                origin: .downloaded(repo: "chariz", url: "u", sha256: sha), recordID: rec.id,
                                                deviceIDs: ["phone", "pad"], runner: ProcessRunner(), now: Date()).package
            let u = try await lib.addTweak(try await deb("Package: uyou\nName: uYouPlus\nDepends: ws.hbang.common\n", "./usr/lib/u.dylib"),
                                           recordID: rec.id, deviceIDs: ["phone", "pad"], runner: ProcessRunner(), now: Date()).package
            _ = try await lib.addTweak(try await deb("Package: pip\nName: YouPiP\nDepends: ws.hbang.common (>= 1.0)\n", "./usr/lib/p.dylib"),
                                       recordID: rec.id, deviceIDs: ["phone"], runner: ProcessRunner(), now: Date())
            // uYouPlus off on the iPad: listed there, but not using it.
            let pending = try #require(await lib.records().first?.pendingTweakUses)
            for d in ["phone", "pad"] {
                var i = Installation(deviceID: d, installedAt: Date(), expiresAt: Date().addingTimeInterval(86400),
                                     lastAttempt: nil, lastErrorKey: nil)
                let uses = try #require(pending[d])
                i.tweaks = d == "pad" ? uses.map { $0.id == u.id ? TweakUse(id: $0.id, enabled: false) : $0 } : uses
                try await lib.upsert(i, for: rec.id)
            }
            let usage = try #require(await lib.downloadUsage().first)
            #expect(usage.apps == ["YouTube"])
            #expect(usage.users == [DownloadUser(app: "YouTube", tweaks: [
                DownloadUser.Tweak(name: "uYouPlus", deviceIDs: ["phone"]),
                DownloadUser.Tweak(name: "YouPiP", deviceIDs: ["phone"]),
            ])])
            #expect(usage.tweakCount == 2)
            _ = cephei
        }
    }
}
