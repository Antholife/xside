import Foundation
import Testing
@testable import XSideCore

/// Alderis (ws.hbang.alderis), pinned to its author's GitHub releases (hbang/Alderis) as the
/// fallback of Chariz: Chariz first, the releases only when Chariz fails or lacks the version.
/// `Fixtures/alderis-releases.json` is the releases API's answer as it was on 2026-11-10 (trimmed
/// to the fields XSide reads): 1.2.4, the newest, has no asset; 1.2.3 and 1.2.2 have both arches.
/// Never the network.
struct AlderisPinTests {
    static let alderis = "ws.hbang.alderis"
    static let api = "https://api.github.com/repos/hbang/Alderis/releases?per_page=30"
    static let download = "https://github.com/hbang/Alderis/releases/download/"

    static func fixture() throws -> Data {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        return try Data(contentsOf: dir.appendingPathComponent("alderis-releases.json"))
    }

    /// The fixture with each asset's size set to `size` (a downloaded test .deb must match it).
    static func fixture(size: Int) throws -> Data {
        var list = try JSONSerialization.jsonObject(with: fixture()) as! [[String: Any]]
        for i in list.indices {
            list[i]["assets"] = (list[i]["assets"] as! [[String: Any]]).map { a in
                var a = a; a["size"] = size; return a
            }
        }
        return try JSONSerialization.data(withJSONObject: list)
    }

    static func deb(package: String = alderis, version: String = "1.2.3") async throws -> Data {
        try await FakeDeb.deb(control: "Package: \(package)\nName: Alderis\nVersion: \(version)\nArchitecture: iphoneos-arm64\n",
                              files: [.file("./var/jb/Library/Frameworks/Alderis.framework/Alderis", Data("bin".utf8))],
                              compression: "none")
    }

    static func chariz(_ fetcher: FakeFetcher, _ pkgs: [RepoClientTests.Pkg]) {
        RepoClientTests.serveRepo(fetcher, pkgs)
    }

    static func charizPkg(_ version: String) -> RepoClientTests.Pkg {
        var p = RepoClientTests.Pkg(version)
        p.package = alderis
        return p
    }

    func downloader(_ fetcher: FakeFetcher, _ dir: URL) -> DependencyDownloader {
        DependencyDownloader(library: AppLibrary(root: dir.appendingPathComponent("lib")),
                             client: RepoClient(fetcher: fetcher, runner: ProcessRunner(), workDir: dir.appendingPathComponent("work")))
    }

    // MARK: The pin

    @Test func alderisIsPinnedToHbangAlderisAndOfferedByChariz() {
        let s = GitHubSource(owner: "hbang", repo: "Alderis")
        #expect(AuthorReleases.pinned == [Self.alderis: s])
        #expect(AuthorReleases.source(for: Self.alderis) == s)
        #expect(AuthorReleases.source(for: "WS.HBANG.ALDERIS") == s)
        #expect(AuthorReleases.source(id: "github:hbang/Alderis") == s)
        #expect(s.page.absoluteString == "https://github.com/hbang/Alderis/releases")
        #expect(s.api.absoluteString == Self.api)
        #expect(TrustedRepos.offering(Self.alderis).map(\.id) == ["chariz"])
        #expect(DependencySources.canDownload(Self.alderis))
        #expect(DependencySources.trustedIDs(for: Self.alderis) == ["chariz", "github:hbang/Alderis"])
        // Chariz is named first.
        #expect(DependencySources.name(for: Self.alderis) == "Chariz")
        #expect(DependencySources.places(for: Self.alderis) == ["https://repo.chariz.com/",
                                                                "https://github.com/hbang/Alderis/releases"])
    }

    // MARK: The releases (fixture)

    /// 1.2.4 has no asset: the latest release with an asset for the arch, 1.2.3, is offered.
    @Test func theLatestReleaseWithAnAssetForTheArchIsOffered() async throws {
        try await withTemporaryDirectory("alderis") { dir in
            let fetcher = FakeFetcher()
            fetcher.serve(Self.api, try Self.fixture())
            let c = AuthorReleaseClient(fetcher: fetcher, runner: ProcessRunner(), workDir: dir)
            let offer = try await c.offer(for: DebDependency(package: Self.alderis), preferredArchitecture: "iphoneos-arm64")
            #expect(offer.version == "1.2.3")
            #expect(offer.architecture == "iphoneos-arm64")
            #expect(offer.assetName == "ws.hbang.alderis_1.2.3_iphoneos-arm64.deb")
            #expect(offer.url.absoluteString == Self.download + "1.2.3/ws.hbang.alderis_1.2.3_iphoneos-arm64.deb")
            #expect(offer.size == 290546)
            #expect(fetcher.fetched.map(\.absoluteString) == [Self.api])

            let rootful = try await c.offer(for: DebDependency(package: Self.alderis), preferredArchitecture: "iphoneos-arm")
            #expect(rootful.version == "1.2.3")
            #expect(rootful.architecture == "iphoneos-arm")
            #expect(rootful.size == 372700)

            let older = try await c.offer(for: DebDependency(package: Self.alderis, relation: "<<", version: "1.2.3"),
                                          preferredArchitecture: nil)
            #expect(older.version == "1.2.2")
            // 1.2.4 exists only as a tag: nothing to download satisfies it.
            await #expect(throws: RepoError.noVersionSatisfying(Self.alderis)) {
                try await c.offer(for: DebDependency(package: Self.alderis, relation: ">=", version: "1.2.4"),
                                  preferredArchitecture: nil)
            }
            #expect(AuthorReleasesTests.isEmpty(dir))
        }
    }

    /// The downloaded .deb's control must say ws.hbang.alderis.
    @Test func theDownloadedControlMustBeAlderis() async throws {
        try await withTemporaryDirectory("alderis") { dir in
            let fetcher = FakeFetcher()
            let c = AuthorReleaseClient(fetcher: fetcher, runner: ProcessRunner(), workDir: dir)
            let dep = DebDependency(package: Self.alderis)
            let good = try await Self.deb()
            fetcher.serve(Self.api, try Self.fixture(size: good.count))
            let offer = try await c.offer(for: dep, preferredArchitecture: nil)
            fetcher.serve(offer.url.absoluteString, good)
            let got = try await c.download(offer, for: dep)
            #expect(got.version == "1.2.3")
            try FileManager.default.removeItem(at: got.file)

            let bad = try await Self.deb(package: "ws.hbang.common")
            fetcher.serve(Self.api, try Self.fixture(size: bad.count))
            let offer2 = try await c.offer(for: dep, preferredArchitecture: nil)
            fetcher.serve(offer2.url.absoluteString, bad)
            await #expect(throws: RepoError.packageMismatch) { try await c.download(offer2, for: dep) }
            #expect(AuthorReleasesTests.isEmpty(dir))
        }
    }

    // MARK: Chariz first

    @Test func charizIsAskedFirst() async throws {
        try await withTemporaryDirectory("alderis") { dir in
            let fetcher = FakeFetcher()
            Self.chariz(fetcher, [Self.charizPkg("1.2.3")])
            fetcher.serve(Self.api, try Self.fixture())
            let source = try await downloader(fetcher, dir).prepare(DebDependency(package: Self.alderis),
                                                                    preferredArchitecture: "iphoneos-arm64")
            guard case .repo(let offer) = source else { Issue.record("expected Chariz"); return }
            #expect(offer.repo.id == "chariz")
            #expect(source.isHashChecked)
            #expect(!fetcher.fetched.contains { $0.absoluteString == Self.api })
        }
    }

    @Test func theReleasesAreTheFallbackWhenCharizFailsOrLacksTheVersion() async throws {
        // Chariz unreachable.
        try await withTemporaryDirectory("alderis") { dir in
            let fetcher = FakeFetcher()
            fetcher.fail(RepoClientTests.chariz + "Release", .httpStatus(503))
            fetcher.serve(Self.api, try Self.fixture())
            let source = try await downloader(fetcher, dir).prepare(DebDependency(package: Self.alderis), preferredArchitecture: nil)
            guard case .authorRelease(let offer) = source else { Issue.record("expected the author's release"); return }
            #expect(offer.version == "1.2.3")
            #expect(!source.isHashChecked)
            #expect(source.repoName == "GitHub hbang/Alderis")
        }
        // Chariz without Alderis.
        try await withTemporaryDirectory("alderis") { dir in
            let fetcher = FakeFetcher()
            Self.chariz(fetcher, [RepoClientTests.Pkg("2.0")])
            fetcher.serve(Self.api, try Self.fixture())
            guard case .authorRelease = try await downloader(fetcher, dir).prepare(DebDependency(package: Self.alderis),
                                                                                  preferredArchitecture: nil) else {
                Issue.record("expected the author's release"); return
            }
        }
        // Chariz without the version asked for.
        try await withTemporaryDirectory("alderis") { dir in
            let fetcher = FakeFetcher()
            Self.chariz(fetcher, [Self.charizPkg("1.2.1")])
            fetcher.serve(Self.api, try Self.fixture())
            let source = try await downloader(fetcher, dir).prepare(
                DebDependency(package: Self.alderis, relation: ">=", version: "1.2.2"), preferredArchitecture: nil)
            guard case .authorRelease(let offer) = source else { Issue.record("expected the author's release"); return }
            #expect(offer.version == "1.2.3")
        }
    }
}
