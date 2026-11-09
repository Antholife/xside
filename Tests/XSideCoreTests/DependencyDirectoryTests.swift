import Foundation
import Testing
@testable import XSideCore

struct DependencyDirectoryTests {
    @Test func knownPages() {
        #expect(DependencyDirectory.page(for: "ws.hbang.common")?.absoluteString == "https://chariz.com/get/cephei")
        #expect(DependencyDirectory.page(for: "com.opa334.altlist")?.absoluteString == "https://github.com/opa334/AltList")
        #expect(DependencyDirectory.page(for: "libroot")?.absoluteString == "https://github.com/opa334/libroot")
        #expect(DependencyDirectory.page(for: "com.opa334.libroot")?.absoluteString == "https://github.com/opa334/libroot")
        #expect(DependencyDirectory.page(for: "com.mrgcgamer.libgcuniversal")?.absoluteString
                == "https://github.com/MrGcGamer/LibGcUniversalDocumentation")
        #expect(DependencyDirectory.page(for: "com.example.unknown") == nil)
        #expect(DependencyDirectory.page(for: "") == nil)
    }

    @Test func searchURLsAreEncodedAndValidated() {
        #expect(DependencyDirectory.searchURLs(for: "ws.hbang.common").map(\.absoluteString) == [
            "https://canister.me/search?q=ws.hbang.common",
            "https://www.ios-repo-updates.com/search/?s=ws.hbang.common",
        ])
        // "+" is a space in a query: encoded.
        #expect(DependencyDirectory.searchURLs(for: "libc++").map(\.absoluteString) == [
            "https://canister.me/search?q=libc%2B%2B",
            "https://www.ios-repo-updates.com/search/?s=libc%2B%2B",
        ])
        for bad in ["a b", "../x", "", "a", "x&y=1", "x#y", "-x", ".x", "Ws.Hbang", "a/b", "é.x",
                    String(repeating: "a", count: 129)] {
            #expect(DependencyDirectory.searchURLs(for: bad).isEmpty, "\(bad)")
        }
        #expect(DependencyDirectory.searchURLs(for: String(repeating: "a", count: 128)).count == 2)
    }

    // MARK: A .deb the person adds for a dependency

    static func package(_ id: String, version: String?, provides: [String] = []) -> TweakPackage {
        TweakPackage(id: "0123456789abcdef", kind: .deb, origin: .added, packageID: id, provides: provides,
                     name: "Pkg", version: version, addedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func anAddedDebMatchesByItsExactPackageIDAndVersion() {
        let dep = DebDependency(package: "ws.hbang.common", relation: ">=", version: "1.16")
        #expect(DependencyDirectory.check(Self.package("ws.hbang.common", version: "2.0"), for: dep) == .matches)
        #expect(DependencyDirectory.check(Self.package("ws.hbang.common", version: "1.16"), for: dep) == .matches)
        #expect(DependencyDirectory.check(Self.package("ws.hbang.common", version: "1.15.3"), for: dep)
                == .tooOld(found: "1.15.3", needed: "≥ 1.16"))
        #expect(DependencyDirectory.check(Self.package("ws.hbang.common", version: nil), for: dep)
                == .unsuitable(found: "?", needed: "≥ 1.16"))
        // An upper bound: too recent; an exact one: doesn't fit.
        #expect(DependencyDirectory.check(Self.package("ws.hbang.common", version: "3.0"),
                                          for: DebDependency(package: "ws.hbang.common", relation: "<<", version: "2.0"))
                == .tooNew(found: "3.0", needed: "< 2.0"))
        #expect(DependencyDirectory.check(Self.package("ws.hbang.common", version: "2.0"),
                                          for: DebDependency(package: "ws.hbang.common", relation: "<=", version: "1.9"))
                == .tooNew(found: "2.0", needed: "≤ 1.9"))
        #expect(DependencyDirectory.check(Self.package("ws.hbang.common", version: "2.0"),
                                          for: DebDependency(package: "ws.hbang.common", relation: "=", version: "1.9"))
                == .unsuitable(found: "2.0", needed: "= 1.9"))
        #expect(DependencyDirectory.check(Self.package("ws.hbang.common", version: "1.0"),
                                          for: DebDependency(package: "ws.hbang.common", relation: ">>", version: "1.0"))
                == .tooOld(found: "1.0", needed: "> 1.0"))
        #expect(DependencyDirectory.check(Self.package("com.other", version: "9"), for: dep)
                == .wrongPackage(found: "com.other", wanted: "ws.hbang.common"))
        // Any version will do.
        #expect(DependencyDirectory.check(Self.package("ws.hbang.common", version: nil),
                                          for: DebDependency(package: "ws.hbang.common")) == .matches)
        // An unreadable constraint is never satisfied.
        #expect(DependencyDirectory.check(Self.package("ws.hbang.common", version: "2.0"),
                                          for: DebDependency(package: "ws.hbang.common", unparseable: true))
                == .unsuitable(found: "2.0", needed: "?"))
    }

    /// Versioned `Provides` aren't read: a `Provides` only satisfies a dependency without a version
    /// (as the classifier does), never a versioned one.
    @Test func providesOnlySatisfiesAnUnversionedDependency() {
        let other = Self.package("com.fork.cephei", version: "9.0", provides: ["ws.hbang.common"])
        #expect(DependencyDirectory.check(other, for: DebDependency(package: "ws.hbang.common")) == .matches)
        #expect(DependencyDirectory.check(other, for: DebDependency(package: "ws.hbang.common", relation: ">=", version: "1.0"))
                == .wrongPackage(found: "com.fork.cephei", wanted: "ws.hbang.common"))
    }

    @Test func constraintsAreWrittenWithSymbols() {
        #expect(DependencyDirectory.constraint(DebDependency(package: "x", relation: ">=", version: "1")) == "≥ 1")
        #expect(DependencyDirectory.constraint(DebDependency(package: "x", relation: "<=", version: "1")) == "≤ 1")
        #expect(DependencyDirectory.constraint(DebDependency(package: "x", relation: ">>", version: "1")) == "> 1")
        #expect(DependencyDirectory.constraint(DebDependency(package: "x", relation: "<<", version: "1")) == "< 1")
        #expect(DependencyDirectory.constraint(DebDependency(package: "x", relation: "=", version: "1")) == "= 1")
        #expect(DependencyDirectory.constraint(DebDependency(package: "x")) == nil)
        #expect(DependencyDirectory.constraint(DebDependency(package: "x", unparseable: true)) == "?")
    }

    // MARK: Download: the cache first, then the trusted repo

    static let altlist = "com.opa334.altlist"
    static let opa = "https://opa334.github.io/"

    static func serveAltList(_ fetcher: FakeFetcher, version: String, deb: Data) {
        var p = RepoClientTests.Pkg(version, deb: deb)
        p.package = altlist
        let idx = Data(p.stanza.utf8)
        fetcher.serve(opa + "Release", RepoClientTests.release([("Packages", idx)]))
        fetcher.serve(opa + "Packages", idx)
        fetcher.serve(opa + p.file, deb)
    }

    @Test func aDownloadIsStoredThenReusedWithoutNetwork() async throws {
        try await withTemporaryDirectory("deps") { dir in
            let fetcher = FakeFetcher()
            let deb = Data("altlist deb".utf8)
            Self.serveAltList(fetcher, version: "1.0.5", deb: deb)
            let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
            let work = dir.appendingPathComponent("work")
            let downloader = DependencyDownloader(library: lib, client: RepoClient(fetcher: fetcher, runner: FakeRunner(), workDir: work))
            let dep = DebDependency(package: Self.altlist, relation: ">=", version: "1.0")

            let source = try await downloader.prepare(dep, preferredArchitecture: "iphoneos-arm64")
            guard case .repo(let offer) = source else { Issue.record("expected an offer"); return }
            #expect(offer.version == "1.0.5")
            #expect(offer.repo.id == "opa334")
            #expect(source.version == "1.0.5")
            #expect(source.size == deb.count)
            #expect(!source.isCached)
            let before = fetcher.fetched.count
            #expect(before == 2) // Release and the index, no .deb yet

            let got = try await downloader.fetch(source)
            #expect(try Data(contentsOf: got.file) == deb)
            #expect(got.file.deletingLastPathComponent() == lib.root.appendingPathComponent("downloads"))
            #expect(got.origin == .downloaded(repo: "opa334", url: offer.url.absoluteString, sha256: RepoClientTests.sha256(deb)))
            #expect(fetcher.fetched.count == before + 1)
            #expect(RepoClientTests.isEmpty(work)) // the work copy is gone

            // Again: from the cache, nothing fetched.
            let again = try await downloader.prepare(dep, preferredArchitecture: "iphoneos-arm64")
            guard case .cached(let cached) = again else { Issue.record("expected the cache"); return }
            #expect(again.isCached)
            #expect(cached.version == "1.0.5")
            #expect(cached.repo == "opa334")
            #expect(again.repoName == "opa334")
            let reused = try await downloader.fetch(again)
            #expect(reused.file == got.file)
            #expect(reused.origin == got.origin)
            #expect(fetcher.fetched.count == before + 1)

            // A cached version that doesn't satisfy the constraint isn't used.
            let newer = DebDependency(package: Self.altlist, relation: ">=", version: "2.0")
            await #expect(throws: RepoError.noVersionSatisfying(Self.altlist)) {
                try await downloader.prepare(newer, preferredArchitecture: nil)
            }
        }
    }

    @Test func aWrongHashIsNotStored() async throws {
        try await withTemporaryDirectory("deps") { dir in
            let fetcher = FakeFetcher()
            Self.serveAltList(fetcher, version: "1.0.5", deb: Data("altlist deb".utf8))
            let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
            let downloader = DependencyDownloader(library: lib, client: RepoClient(fetcher: fetcher, runner: FakeRunner(),
                                                                                 workDir: dir.appendingPathComponent("work")))
            let dep = DebDependency(package: Self.altlist)
            let source = try await downloader.prepare(dep, preferredArchitecture: nil)
            guard case .repo(let offer) = source else { Issue.record("expected an offer"); return }
            fetcher.serve(offer.url.absoluteString, Data("altlist DEB".utf8)) // same size, other bytes
            await #expect(throws: RepoError.hashMismatch) { try await downloader.fetch(source) }
            #expect(await lib.cachedDownload(packageID: Self.altlist, satisfying: dep) == nil)
            #expect(DependencyDownloader.failure(RepoError.hashMismatch) == .hash)
        }
    }

    @Test func aPackageNoTrustedRepoOffersIsNeverLookedUp() async throws {
        try await withTemporaryDirectory("deps") { dir in
            let fetcher = FakeFetcher()
            let downloader = DependencyDownloader(library: AppLibrary(root: dir.appendingPathComponent("lib")),
                                                  client: RepoClient(fetcher: fetcher, runner: FakeRunner(), workDir: dir))
            await #expect(throws: RepoError.notAllowlisted) {
                try await downloader.prepare(DebDependency(package: "com.example.unknown"), preferredArchitecture: nil)
            }
            #expect(fetcher.fetched.isEmpty)
        }
    }

    /// A kept copy is reused only when it came from a repo that is trusted for that package now;
    /// any other is dropped (file and index entry) and the repo is asked instead.
    @Test func aCachedCopyFromARepoNotTrustedForThePackageIsDropped() async throws {
        try await withTemporaryDirectory("deps") { dir in
            let fetcher = FakeFetcher()
            let deb = Data("altlist deb".utf8)
            Self.serveAltList(fetcher, version: "1.0.5", deb: deb)
            let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
            let planted = dir.appendingPathComponent("planted.deb")
            let bytes = Data("not from opa334".utf8)
            try bytes.write(to: planted)
            // Newer than the repo's, and kept as coming from Chariz (not trusted for AltList).
            let kept = try await lib.storeDownload(planted, sha256: RepoClientTests.sha256(bytes), packageID: Self.altlist,
                                                   version: "9.0", repo: "chariz", url: "https://repo.chariz.com/x.deb")
            let downloader = DependencyDownloader(library: lib, client: RepoClient(fetcher: fetcher, runner: FakeRunner(),
                                                                                 workDir: dir.appendingPathComponent("work")))
            let dep = DebDependency(package: Self.altlist)
            let source = try await downloader.prepare(dep, preferredArchitecture: nil)
            guard case .repo(let offer) = source else { Issue.record("an untrusted kept copy was reused"); return }
            #expect(offer.version == "1.0.5")
            #expect(!FileManager.default.fileExists(atPath: kept.path))
            #expect(await lib.cachedDownloadEntry(packageID: Self.altlist, satisfying: dep) == nil)
            // An unknown repo id too.
            let other = try await lib.storeDownload(planted, sha256: RepoClientTests.sha256(bytes), packageID: Self.altlist,
                                                    version: "9.0", repo: "evil", url: "https://evil.example/x.deb")
            guard case .repo = try await downloader.prepare(dep, preferredArchitecture: nil) else {
                Issue.record("an unknown repo's kept copy was reused"); return
            }
            #expect(!FileManager.default.fileExists(atPath: other.path))
        }
    }

    // MARK: Per device

    static func tweak(depends: [[DebDependency]]) -> TweakPackage {
        let binary = TweakBinary(path: "Library/MobileSubstrate/DynamicLibraries/T.dylib", isEntry: true,
                                 filter: TweakFilter(bundles: ["com.example.app"]),
                                 slices: [TweakSlice(arch: "arm64", platform: 2, minOS: "15.0")],
                                 linked: ["/usr/lib/libobjc.A.dylib"], mentionsJailbreakPaths: false, imageName: "T.dylib")
        return TweakPackage(id: "00000000000000aa", kind: .deb, origin: .added, packageID: "com.example.tweak", name: "T",
                            version: "1.0", depends: depends,
                            files: ["Library/MobileSubstrate/DynamicLibraries/T.dylib", "Library/MobileSubstrate/DynamicLibraries/T.plist"],
                            binaries: [binary], addedAt: Date(timeIntervalSince1970: 0))
    }

    static func dependencyPackage(_ packageID: String, name: String, version: String) -> TweakPackage {
        let binary = TweakBinary(path: "usr/lib/\(name).dylib", isEntry: false, filter: nil,
                                 slices: [TweakSlice(arch: "arm64", platform: 2, minOS: "15.0")], linked: [],
                                 mentionsJailbreakPaths: false, imageName: "\(name).dylib")
        return TweakPackage(id: "00000000000000bb", kind: .deb, origin: .added, packageID: packageID, name: name,
                            version: version, files: [binary.path], binaries: [binary], addedAt: Date(timeIntervalSince1970: 0))
    }

    static func context(_ others: [TweakPackage], os: String = "17.5") -> TweakContext {
        TweakContext(originalBundleID: "com.example.app", executableName: "Example", deviceOS: os, others: others)
    }

    @Test func devicesThatAgreeShareOneStatus() {
        let t = Self.tweak(depends: [[DebDependency(package: "mobilesubstrate")],
                                     [DebDependency(package: "com.example.helper", relation: ">=", version: "1.0")]])
        let helper = Self.dependencyPackage("com.example.helper", name: "Helper", version: "1.2")
        let rows = DependencyRows.rows(t, contexts: [("a", Self.context([helper])), ("b", Self.context([helper]))])
        #expect(rows.count == 2)
        #expect(rows[0].statuses == [DependencyDeviceStatus(deviceID: nil, dependency: DebDependency(package: "mobilesubstrate"),
                                                             status: .notNeeded, addedVersion: nil)])
        #expect(rows[1].statuses.count == 1)
        #expect(rows[1].statuses[0].deviceID == nil)
        #expect(rows[1].statuses[0].status == .addedByYou("Helper"))
        #expect(rows[1].statuses[0].addedVersion == "1.2")
        #expect(!rows[1].isMissingAnywhere)
        #expect(rows[1].missingDependency == nil)
    }

    /// The helper is on the iPhone only: added there, missing on the iPad. The iPad's verdict
    /// then says so too for a known library (Cephei); an unknown one is listed for the row's flag.
    @Test func devicesThatDisagreeGetOneStatusEach() {
        let need = DebDependency(package: "com.example.helper", relation: ">=", version: "1.0")
        let t = Self.tweak(depends: [[need]])
        let helper = Self.dependencyPackage("com.example.helper", name: "Helper", version: "1.2")
        let rows = DependencyRows.rows(t, contexts: [("iphone", Self.context([helper])), ("ipad", Self.context([]))])
        #expect(rows.count == 1)
        #expect(rows[0].statuses == [
            DependencyDeviceStatus(deviceID: "iphone", dependency: need, status: .addedByYou("Helper"), addedVersion: "1.2"),
            DependencyDeviceStatus(deviceID: "ipad", dependency: need, status: .missing(need), addedVersion: nil),
        ])
        #expect(rows[0].isMissingAnywhere)
        #expect(rows[0].missingDependency == need)
        #expect(rows[0].missingDevices == ["ipad"])
        #expect(DependencyRows.missing(t, Self.context([helper])).isEmpty)
        #expect(DependencyRows.missing(t, Self.context([])) == ["com.example.helper"])

        // A known library missing on one device: that device's verdict is ❌.
        let cepheiNeed = DebDependency(package: "ws.hbang.common", relation: ">=", version: "1.0")
        let c = Self.tweak(depends: [[cepheiNeed]])
        let cephei = Self.dependencyPackage("ws.hbang.common", name: "Cephei", version: "2.0")
        #expect(TweakClassifier.verdict(c, Self.context([cephei])) != .incompatible(.missingDependency("Cephei")))
        #expect(TweakClassifier.verdict(c, Self.context([])) == .incompatible(.missingDependency("Cephei")))
        #expect(DependencyRows.rows(c, contexts: [("iphone", Self.context([cephei])), ("ipad", Self.context([]))])[0]
                    .missingDevices == ["ipad"])
    }

    @Test func noDeviceMeansNoRows() {
        #expect(DependencyRows.rows(Self.tweak(depends: [[DebDependency(package: "x")]]), contexts: []).isEmpty)
    }

    @Test func failuresAreSortedForTheirMessage() {
        #expect(DependencyDownloader.failure(RepoError.hashMismatch) == .hash)
        #expect(DependencyDownloader.failure(RepoError.sizeMismatch) == .hash)
        #expect(DependencyDownloader.failure(RepoError.indexHashMismatch) == .hash)
        #expect(DependencyDownloader.failure(RepoError.notFound("x")) == .notFound)
        #expect(DependencyDownloader.failure(RepoError.noVersionSatisfying("x")) == .notFound)
        #expect(DependencyDownloader.failure(RepoError.httpStatus(503)) == .network)
        #expect(DependencyDownloader.failure(RepoError.timedOut) == .network)
        #expect(DependencyDownloader.failure(URLError(.notConnectedToInternet)) == .network)
    }
}
