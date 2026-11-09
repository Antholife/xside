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
                == .tooOld(found: "?", needed: "≥ 1.16"))
        #expect(DependencyDirectory.check(Self.package("com.other", version: "9"), for: dep)
                == .wrongPackage(found: "com.other", wanted: "ws.hbang.common"))
        // Any version will do.
        #expect(DependencyDirectory.check(Self.package("ws.hbang.common", version: nil),
                                          for: DebDependency(package: "ws.hbang.common")) == .matches)
        // An unreadable constraint is never satisfied.
        #expect(DependencyDirectory.check(Self.package("ws.hbang.common", version: "2.0"),
                                          for: DebDependency(package: "ws.hbang.common", unparseable: true))
                == .tooOld(found: "2.0", needed: "?"))
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
