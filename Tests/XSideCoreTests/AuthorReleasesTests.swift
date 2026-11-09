import Foundation
import Testing
@testable import XSideCore

/// « Télécharger » for a dependency only its author publishes, on GitHub: a pinned owner/repo per
/// package id, the releases API, the right .deb asset, its size as the cap, then the .deb's own
/// control checked. Everything goes through `FakeFetcher`, never the network.
struct AuthorReleasesTests {
    static let altlist = "com.opa334.altlist"
    static let api = "https://api.github.com/repos/opa334/AltList/releases?per_page=30"
    static let download = "https://github.com/opa334/AltList/releases/download/"

    struct Asset {
        var name: String
        var size: Int
        var url: String
        init(_ name: String, size: Int = 100, tag: String) {
            self.name = name
            self.size = size
            self.url = AuthorReleasesTests.download + tag + "/" + name
        }
    }

    struct Release {
        var tag: String
        var draft = false
        var prerelease = false
        var assets: [Asset]
    }

    static func json(_ releases: [Release]) -> Data {
        let list: [[String: Any]] = releases.map { r in
            ["tag_name": r.tag, "draft": r.draft, "prerelease": r.prerelease,
             "assets": r.assets.map { ["name": $0.name, "size": $0.size, "browser_download_url": $0.url] as [String: Any] }]
        }
        return try! JSONSerialization.data(withJSONObject: list)
    }

    static func release(_ version: String, archs: [String] = ["iphoneos-arm", "iphoneos-arm64"], size: Int = 100) -> Release {
        let tag = "v" + version
        return Release(tag: tag, assets: archs.map { Asset("\(altlist)_\(version)_\($0).deb", size: size, tag: tag) })
    }

    func client(_ fetcher: FakeFetcher, _ dir: URL) -> AuthorReleaseClient {
        AuthorReleaseClient(fetcher: fetcher, runner: ProcessRunner(), workDir: dir)
    }

    static func deb(package: String = altlist, version: String) async throws -> Data {
        try await FakeDeb.deb(control: "Package: \(package)\nName: AltList\nVersion: \(version)\nArchitecture: iphoneos-arm64\n",
                              files: [.file("./var/jb/Library/Frameworks/AltList.framework/AltList", Data("bin".utf8))],
                              compression: "none")
    }

    // MARK: Which dependencies

    @Test func onlyPinnedPackagesHaveASource() {
        let s = AuthorReleases.source(for: Self.altlist)
        #expect(s == GitHubSource(owner: "opa334", repo: "AltList"))
        #expect(s?.id == "github:opa334/AltList")
        #expect(s?.page.absoluteString == "https://github.com/opa334/AltList/releases")
        #expect(AuthorReleases.source(for: "COM.OPA334.ALTLIST") == s)
        #expect(AuthorReleases.source(for: "ws.hbang.common") == nil)
        #expect(AuthorReleases.source(for: "com.evil.tweak") == nil)
        #expect(AuthorReleases.source(id: "github:opa334/AltList") == s)
        #expect(AuthorReleases.source(id: "github:evil/AltList") == nil)
    }

    @Test func anUnpinnedPackageIsNeverLookedUp() async throws {
        try await withTemporaryDirectory("gh") { dir in
            let fetcher = FakeFetcher()
            await #expect(throws: RepoError.notAllowlisted) {
                try await client(fetcher, dir).offer(for: DebDependency(package: "com.evil.tweak"), preferredArchitecture: nil)
            }
            #expect(fetcher.fetched.isEmpty)
        }
    }

    // MARK: Choosing the asset

    @Test func picksTheBestArchitectureThenTheNewestSatisfyingVersion() async throws {
        try await withTemporaryDirectory("gh") { dir in
            let fetcher = FakeFetcher()
            var arm64e = Self.release("9.0", archs: ["iphoneos-arm64e"])
            arm64e.assets.append(Asset("AltList-9.0.zip", tag: "v9.0"))
            var draft = Self.release("8.0"); draft.draft = true
            var pre = Self.release("7.0"); pre.prerelease = true
            fetcher.serve(Self.api, Self.json([arm64e, draft, pre, Self.release("1.0.6", archs: ["iphoneos-arm"]),
                                               Self.release("1.0.5"), Self.release("0.9")]))
            let c = client(fetcher, dir)
            let dep = DebDependency(package: Self.altlist, relation: ">=", version: "1.0")
            let offer = try await c.offer(for: dep, preferredArchitecture: nil)
            #expect(offer.version == "1.0.5")
            #expect(offer.architecture == "iphoneos-arm64")
            #expect(offer.url.absoluteString == Self.download + "v1.0.5/com.opa334.altlist_1.0.5_iphoneos-arm64.deb")
            #expect(offer.size == 100)
            #expect(offer.source == AuthorReleases.source(for: Self.altlist))
            #expect(offer.packageID == Self.altlist)
            // The API is asked over HTTPS, capped, and may not redirect off api.github.com.
            #expect(fetcher.fetched.map(\.absoluteString) == [Self.api])
            #expect(fetcher.origin(for: Self.api) == .some(URL(string: "https://api.github.com/")!))
            #expect(fetcher.maxBytes(for: Self.api) == AuthorReleases.maxListBytes)
            // A rootful tweak gets the rootful build.
            #expect(try await c.offer(for: dep, preferredArchitecture: "iphoneos-arm").version == "1.0.6")
            // A version nothing satisfies.
            await #expect(throws: RepoError.noVersionSatisfying(Self.altlist)) {
                try await c.offer(for: DebDependency(package: Self.altlist, relation: ">=", version: "2.0"), preferredArchitecture: nil)
            }
            #expect(Self.isEmpty(dir))
        }
    }

    /// The asset names that carry no package id take the version from the tag.
    @Test func theVersionComesFromTheAssetNameOrTheTag() async throws {
        try await withTemporaryDirectory("gh") { dir in
            let fetcher = FakeFetcher()
            fetcher.serve(Self.api, Self.json([Release(tag: "v1.1.0", assets: [Asset("AltList_iphoneos-arm64.deb", tag: "v1.1.0")])]))
            let offer = try await client(fetcher, dir).offer(for: DebDependency(package: Self.altlist), preferredArchitecture: nil)
            #expect(offer.version == "1.1.0")
            #expect(offer.architecture == "iphoneos-arm64")
        }
    }

    @Test func noReleaseIsNotFound() async throws {
        try await withTemporaryDirectory("gh") { dir in
            let fetcher = FakeFetcher()
            fetcher.serve(Self.api, Data("[]".utf8))
            await #expect(throws: RepoError.notFound(Self.altlist)) {
                try await client(fetcher, dir).offer(for: DebDependency(package: Self.altlist), preferredArchitecture: nil)
            }
        }
    }

    /// Assets that point anywhere but the pinned repo's release downloads, are too big or empty, or
    /// carry a hostile name are skipped; hostile JSON is no release.
    @Test func hostileListsAreSkippedOrRefused() async throws {
        try await withTemporaryDirectory("gh") { dir in
            let fetcher = FakeFetcher()
            var elsewhere = Asset("\(Self.altlist)_5.0_iphoneos-arm64.deb", tag: "v5.0")
            elsewhere.url = "https://evil.example/opa334/AltList/releases/download/v5.0/x.deb"
            var otherRepo = Asset("\(Self.altlist)_4.0_iphoneos-arm64.deb", tag: "v4.0")
            otherRepo.url = "https://github.com/evil/AltList/releases/download/v4.0/x.deb"
            var plain = Asset("\(Self.altlist)_3.5_iphoneos-arm64.deb", tag: "v3.5")
            plain.url = plain.url.replacingOccurrences(of: "https://", with: "http://")
            var dotdot = Asset("\(Self.altlist)_3.4_iphoneos-arm64.deb", tag: "v3.4")
            dotdot.url = Self.download + "../../../evil/x.deb"
            let huge = Asset("\(Self.altlist)_3.0_iphoneos-arm64.deb", size: DebLimits.maxDebBytes + 1, tag: "v3.0")
            let empty = Asset("\(Self.altlist)_2.5_iphoneos-arm64.deb", size: 0, tag: "v2.5")
            let negative = Asset("\(Self.altlist)_2.4_iphoneos-arm64.deb", size: -5, tag: "v2.4")
            fetcher.serve(Self.api, Self.json([
                Release(tag: "v5.0", assets: [elsewhere]), Release(tag: "v4.0", assets: [otherRepo]),
                Release(tag: "v3.5", assets: [plain]), Release(tag: "v3.4", assets: [dotdot]),
                Release(tag: "v3.0", assets: [huge]), Release(tag: "v2.5", assets: [empty]), Release(tag: "v2.4", assets: [negative]),
                Self.release("1.0"),
            ]))
            let c = client(fetcher, dir)
            let offer = try await c.offer(for: DebDependency(package: Self.altlist), preferredArchitecture: nil)
            #expect(offer.version == "1.0")

            for garbage in ["{\"message\":\"API rate limit exceeded\"}", "not json", "[1, \"x\", null, {\"assets\": 3}]",
                            "[{\"tag_name\": \"v1\", \"assets\": [{\"name\": \"\(Self.altlist)_1_iphoneos-arm64.deb\", \"size\": 1e300, \"browser_download_url\": \"\(Self.download)v1/a.deb\"}]}]"] {
                fetcher.serve(Self.api, Data(garbage.utf8))
                await #expect(throws: RepoError.notFound(Self.altlist)) {
                    try await c.offer(for: DebDependency(package: Self.altlist), preferredArchitecture: nil)
                }
            }
            // Over the cap: refused by the fetcher.
            fetcher.fail(Self.api, .tooLarge)
            await #expect(throws: RepoError.tooLarge) {
                try await c.offer(for: DebDependency(package: Self.altlist), preferredArchitecture: nil)
            }
            #expect(Self.isEmpty(dir))
        }
    }

    @Test func theAPIEndingOffItsHostIsRefused() async throws {
        try await withTemporaryDirectory("gh") { dir in
            let fetcher = FakeFetcher()
            fetcher.serve(Self.api, Self.json([Self.release("1.0")]), final: "https://evil.example/releases")
            await #expect(throws: RepoError.notAllowlisted) {
                try await client(fetcher, dir).offer(for: DebDependency(package: Self.altlist), preferredArchitecture: nil)
            }
            #expect(Self.isEmpty(dir))
        }
    }

    // MARK: Download

    @Test func theDownloadIsCappedAtTheAssetSizeAndItsControlChecked() async throws {
        try await withTemporaryDirectory("gh") { dir in
            let fetcher = FakeFetcher()
            let deb = try await Self.deb(version: "1.0.5")
            fetcher.serve(Self.api, Self.json([Self.release("1.0.5", size: deb.count)]))
            let c = client(fetcher, dir)
            let dep = DebDependency(package: Self.altlist, relation: ">=", version: "1.0")
            let offer = try await c.offer(for: dep, preferredArchitecture: nil)
            fetcher.serve(offer.url.absoluteString, deb,
                          final: "https://release-assets.githubusercontent.com/github-production-release-asset/1?sig=x")
            let got = try await c.download(offer, for: dep)
            #expect(try Data(contentsOf: got.file) == deb)
            #expect(got.sha256 == RepoClientTests.sha256(deb))
            #expect(got.version == "1.0.5")
            #expect(fetcher.maxBytes(for: offer.url.absoluteString) == deb.count)
            #expect(fetcher.hosts(for: offer.url.absoluteString) == AuthorReleases.assetHosts)
            #expect(AuthorReleases.assetHosts == ["github.com", "objects.githubusercontent.com",
                                                  "release-assets.githubusercontent.com"])
            try FileManager.default.removeItem(at: got.file)
            #expect(Self.isEmpty(dir))
        }
    }

    @Test func aDebThatIsNotThePackageOrNotAVersionThatWillDoIsRefused() async throws {
        try await withTemporaryDirectory("gh") { dir in
            let fetcher = FakeFetcher()
            let c = client(fetcher, dir)
            let dep = DebDependency(package: Self.altlist, relation: ">=", version: "1.0")
            for bad in [try await Self.deb(package: "com.evil.tweak", version: "1.0.5"), try await Self.deb(version: "0.5"),
                        Data("not a deb at all, but the right size?".utf8)] {
                fetcher.serve(Self.api, Self.json([Self.release("1.0.5", size: bad.count)]))
                let offer = try await c.offer(for: dep, preferredArchitecture: nil)
                fetcher.serve(offer.url.absoluteString, bad)
                await #expect(throws: RepoError.packageMismatch) { try await c.download(offer, for: dep) }
                #expect(Self.isEmpty(dir))
            }
            // Fewer bytes than the asset says.
            let deb = try await Self.deb(version: "1.0.5")
            fetcher.serve(Self.api, Self.json([Self.release("1.0.5", size: deb.count + 1)]))
            let offer = try await c.offer(for: dep, preferredArchitecture: nil)
            fetcher.serve(offer.url.absoluteString, deb)
            await #expect(throws: RepoError.sizeMismatch) { try await c.download(offer, for: dep) }
            #expect(Self.isEmpty(dir))
        }
    }

    @Test func aDownloadEndingOffTheAssetHostsOrNotFromThePinnedRepoIsRefused() async throws {
        try await withTemporaryDirectory("gh") { dir in
            let fetcher = FakeFetcher()
            let deb = try await Self.deb(version: "1.0.5")
            fetcher.serve(Self.api, Self.json([Self.release("1.0.5", size: deb.count)]))
            let c = client(fetcher, dir)
            let dep = DebDependency(package: Self.altlist)
            let offer = try await c.offer(for: dep, preferredArchitecture: nil)
            fetcher.serve(offer.url.absoluteString, deb, final: "https://evil.example/x.deb")
            await #expect(throws: RepoError.notAllowlisted) { try await c.download(offer, for: dep) }
            #expect(Self.isEmpty(dir))
            // An offer built by hand for another repo, or another URL, is never fetched.
            let before = fetcher.fetched.count
            let forged = [
                ReleaseOffer(source: GitHubSource(owner: "evil", repo: "AltList"), packageID: Self.altlist, version: "1",
                             architecture: "iphoneos-arm64", url: URL(string: "https://github.com/evil/AltList/releases/download/v1/a.deb")!,
                             size: 10, assetName: "a.deb"),
                ReleaseOffer(source: offer.source, packageID: Self.altlist, version: "1", architecture: "iphoneos-arm64",
                             url: URL(string: "https://evil.example/opa334/AltList/releases/download/v1/a.deb")!, size: 10, assetName: "a.deb"),
                ReleaseOffer(source: offer.source, packageID: "com.evil.tweak", version: "1", architecture: "iphoneos-arm64",
                             url: offer.url, size: 10, assetName: "a.deb"),
                ReleaseOffer(source: offer.source, packageID: Self.altlist, version: "1", architecture: "iphoneos-arm64",
                             url: offer.url, size: DebLimits.maxDebBytes + 1, assetName: "a.deb"),
            ]
            for f in forged {
                await #expect(throws: (any Error).self) { try await c.download(f, for: dep) }
            }
            #expect(fetcher.fetched.count == before)
        }
    }

    // MARK: Through « Télécharger »

    @Test func theDownloaderUsesTheAuthorsReleasesKeepsAndReusesTheCopy() async throws {
        try await withTemporaryDirectory("gh") { dir in
            let fetcher = FakeFetcher()
            let deb = try await Self.deb(version: "1.0.5")
            fetcher.serve(Self.api, Self.json([Self.release("1.0.5", size: deb.count)]))
            let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
            let work = dir.appendingPathComponent("work")
            let downloader = DependencyDownloader(library: lib, client: RepoClient(fetcher: fetcher, runner: ProcessRunner(), workDir: work))
            let dep = DebDependency(package: Self.altlist, relation: ">=", version: "1.0")

            let source = try await downloader.prepare(dep, preferredArchitecture: "iphoneos-arm64")
            guard case .authorRelease(let offer) = source else { Issue.record("expected the author's release"); return }
            #expect(!source.isHashChecked)
            #expect(source.version == "1.0.5")
            #expect(source.size == deb.count)
            #expect(source.repoName == "GitHub opa334/AltList")
            #expect(source.repoURL?.absoluteString == "https://github.com/opa334/AltList/releases")
            fetcher.serve(offer.url.absoluteString, deb)

            let got = try await downloader.fetch(source)
            let sha = RepoClientTests.sha256(deb)
            #expect(got.origin == .downloaded(repo: "github:opa334/AltList", url: offer.url.absoluteString, sha256: sha))
            #expect(try Data(contentsOf: got.file) == deb)
            #expect(RepoClientTests.isEmpty(work))
            let count = fetcher.fetched.count

            // Again: the kept copy, recorded with its source; no network.
            let again = try await downloader.prepare(dep, preferredArchitecture: "iphoneos-arm64")
            guard case .cached(let kept) = again else { Issue.record("expected the kept copy"); return }
            #expect(kept.repo == "github:opa334/AltList")
            #expect(again.repoName == "GitHub opa334/AltList")
            #expect(again.isHashChecked == false)
            #expect(fetcher.fetched.count == count)
            #expect(DependencySources.name(forRepoID: "github:opa334/AltList") == "GitHub opa334/AltList")
            #expect(DependencySources.canDownload(Self.altlist))
            #expect(DependencySources.canDownload("ws.hbang.common"))
            #expect(!DependencySources.canDownload("com.evil.tweak"))
        }
    }

    @Test func aWrongPackageIsNotKept() async throws {
        try await withTemporaryDirectory("gh") { dir in
            let fetcher = FakeFetcher()
            let bad = try await Self.deb(package: "com.evil.tweak", version: "1.0.5")
            fetcher.serve(Self.api, Self.json([Self.release("1.0.5", size: bad.count)]))
            let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
            let downloader = DependencyDownloader(library: lib, client: RepoClient(fetcher: fetcher, runner: ProcessRunner(),
                                                                                 workDir: dir.appendingPathComponent("work")))
            let dep = DebDependency(package: Self.altlist)
            let source = try await downloader.prepare(dep, preferredArchitecture: nil)
            guard case .authorRelease(let offer) = source else { Issue.record("expected the author's release"); return }
            fetcher.serve(offer.url.absoluteString, bad)
            await #expect(throws: RepoError.packageMismatch) { try await downloader.fetch(source) }
            #expect(await lib.cachedDownloadEntry(packageID: Self.altlist, satisfying: dep) == nil)
            #expect(DependencyDownloader.failure(RepoError.packageMismatch) == .mismatch)
        }
    }

    /// The old opa334.github.io copy is no longer trusted for AltList: dropped, the author's
    /// releases are asked instead.
    @Test func aCopyKeptFromTheOldRepoIsDropped() async throws {
        try await withTemporaryDirectory("gh") { dir in
            let fetcher = FakeFetcher()
            fetcher.serve(Self.api, Self.json([Self.release("1.0.5")]))
            let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
            let planted = dir.appendingPathComponent("planted.deb")
            let bytes = Data("old".utf8)
            try bytes.write(to: planted)
            let kept = try await lib.storeDownload(planted, sha256: RepoClientTests.sha256(bytes), packageID: Self.altlist,
                                                   version: "9.0", repo: "opa334", url: "https://opa334.github.io/x.deb")
            let downloader = DependencyDownloader(library: lib, client: RepoClient(fetcher: fetcher, runner: ProcessRunner(),
                                                                                 workDir: dir.appendingPathComponent("work")))
            guard case .authorRelease = try await downloader.prepare(DebDependency(package: Self.altlist), preferredArchitecture: nil) else {
                Issue.record("the old repo's copy was reused"); return
            }
            #expect(!FileManager.default.fileExists(atPath: kept.path))
        }
    }

    @Test func updateAsksTheAuthorsReleases() async throws {
        try await withTemporaryDirectory("gh") { dir in
            let fetcher = FakeFetcher()
            fetcher.serve(Self.api, Self.json([Self.release("1.0.6"), Self.release("1.0.5")]))
            let downloader = DependencyDownloader(library: AppLibrary(root: dir.appendingPathComponent("lib")),
                                                  client: RepoClient(fetcher: fetcher, runner: ProcessRunner(),
                                                                     workDir: dir.appendingPathComponent("work")))
            let dep = DebDependency(package: Self.altlist)
            let newer = try await downloader.update(dep, installed: "1.0.5", preferredArchitecture: nil)
            #expect(newer?.version == "1.0.6")
            #expect(newer?.isHashChecked == false)
            #expect(try await downloader.update(dep, installed: "1.0.6", preferredArchitecture: nil) == nil)
        }
    }

    static func isEmpty(_ dir: URL) -> Bool { RepoClientTests.isEmpty(dir) || !FileManager.default.fileExists(atPath: dir.path) }
}
