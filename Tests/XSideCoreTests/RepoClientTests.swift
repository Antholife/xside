import Foundation
import CryptoKit
import Testing
@testable import XSideCore

/// Serves a map of URL -> bytes (or an error), never the network. Honours `maxBytes` like the real
/// fetcher (throws `.tooLarge` and leaves no file).
final class FakeFetcher: HTTPFetching, @unchecked Sendable {
    enum Route { case data(Data, final: URL?), failure(RepoError) }
    private let lock = NSLock()
    private var routes: [URL: Route] = [:]
    private var _fetched: [(url: URL, maxBytes: Int, origin: URL?, hosts: Set<String>?)] = []

    func serve(_ url: String, _ data: Data, final: String? = nil) {
        lock.withLock { routes[URL(string: url)!] = .data(data, final: final.map { URL(string: $0)! }) }
    }
    func fail(_ url: String, _ error: RepoError) { lock.withLock { routes[URL(string: url)!] = .failure(error) } }
    var fetched: [URL] { lock.withLock { _fetched.map(\.url) } }
    func maxBytes(for url: String) -> Int? { lock.withLock { _fetched.last { $0.url.absoluteString == url }?.maxBytes } }
    func origin(for url: String) -> URL?? { lock.withLock { _fetched.last { $0.url.absoluteString == url }.map(\.origin) } }
    func hosts(for url: String) -> Set<String>? { lock.withLock { _fetched.last { $0.url.absoluteString == url }?.hosts } }

    func fetch(_ url: URL, maxBytes: Int, to file: URL, stayingOn origin: URL?) async throws -> URL {
        try await serve(url, maxBytes: maxBytes, to: file, origin: origin, hosts: nil)
    }

    func fetch(_ url: URL, maxBytes: Int, to file: URL, redirectingWithin hosts: Set<String>) async throws -> URL {
        try await serve(url, maxBytes: maxBytes, to: file, origin: nil, hosts: hosts)
    }

    private func serve(_ url: URL, maxBytes: Int, to file: URL, origin: URL?, hosts: Set<String>?) async throws -> URL {
        let route = lock.withLock { () -> Route? in _fetched.append((url, maxBytes, origin, hosts)); return routes[url] }
        try? FileManager.default.removeItem(at: file)
        switch route {
        case nil: throw RepoError.httpStatus(404)
        case .failure(let e)?: throw e
        case .data(let data, let final)?:
            guard data.count <= maxBytes else { throw RepoError.tooLarge }
            try data.write(to: file)
            return final ?? url
        }
    }
}

struct RepoClientTests {
    static let chariz = "https://repo.chariz.com/"
    static let cephei = "ws.hbang.common"

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    static func sha512(_ d: Data) -> String { SHA512.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    static func md5(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    struct Pkg {
        var package = cephei
        var version: String
        var arch = "iphoneos-arm64"
        var filename: String?
        var deb: Data
        var sha256: String?
        var size: String?
        var provides: String?
        init(_ version: String, arch: String = "iphoneos-arm64", filename: String? = nil, deb: Data? = nil) {
            self.version = version
            self.arch = arch
            self.filename = filename
            self.deb = deb ?? Data("deb \(version) \(arch)".utf8)
        }
        var file: String { filename ?? "debs/\(package)_\(version)_\(arch).deb" }
        var stanza: String {
            var s = "Package: \(package)\nName: Cephei\nVersion: \(version)\nArchitecture: \(arch)\n"
            if let provides { s += "Provides: \(provides)\n" }
            s += "Filename: \(file)\nSize: \(size ?? String(deb.count))\n"
            s += "MD5sum: \(RepoClientTests.md5(deb))\n"
            if let h = sha256 ?? Optional(RepoClientTests.sha256(deb)), !h.isEmpty { s += "SHA256: \(h)\n" }
            return s + "Description: Support library\n"
        }
    }

    static func index(_ pkgs: [Pkg]) -> Data { Data(pkgs.map(\.stanza).joined(separator: "\n").utf8) }

    enum HashKinds { case sha256, sha512AndMD5, md5Only }

    /// A flat Release listing `files` (name -> bytes) with the given hash fields.
    static func release(_ files: [(String, Data)], _ kinds: HashKinds = .sha256) -> Data {
        var s = "Origin: Test\nLabel: Test\nSuite: stable\nArchitectures: iphoneos-arm iphoneos-arm64\n"
        func block(_ field: String, _ hash: (Data) -> String) {
            s += "\(field):\n" + files.map { " \(hash($0.1)) \($0.1.count) \($0.0)\n" }.joined()
        }
        switch kinds {
        case .sha256: block("MD5Sum", md5); block("SHA256", sha256)
        case .sha512AndMD5: block("MD5Sum", md5); block("SHA512", sha512)
        case .md5Only: block("MD5Sum", md5)
        }
        return Data(s.utf8)
    }

    /// Serves a Chariz-like flat repo with a plain `Packages` index and the debs.
    static func serveRepo(_ fetcher: FakeFetcher, _ pkgs: [Pkg], kinds: HashKinds = .sha256) {
        let idx = index(pkgs)
        fetcher.serve(chariz + "Release", release([("Packages", idx)], kinds))
        fetcher.serve(chariz + "Packages", idx)
        for p in pkgs { fetcher.serve(chariz + p.file, p.deb) }
    }

    func client(_ fetcher: FakeFetcher, _ dir: URL) -> RepoClient {
        RepoClient(fetcher: fetcher, runner: FakeRunner(), workDir: dir)
    }

    static let threeVersions = [Pkg("1.15.3", arch: "iphoneos-arm"), Pkg("1.16", arch: "iphoneos-arm"), Pkg("2.0", arch: "iphoneos-arm64")]

    @Test func findsTheNewestSatisfyingVersion() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            Self.serveRepo(fetcher, Self.threeVersions)
            let offer = try await client(fetcher, dir).offer(
                for: DebDependency(package: Self.cephei, relation: ">=", version: "1.16"), preferredArchitecture: "iphoneos-arm64")
            #expect(offer.version == "2.0")
            #expect(offer.architecture == "iphoneos-arm64")
            #expect(offer.url.absoluteString == Self.chariz + "debs/ws.hbang.common_2.0_iphoneos-arm64.deb")
            #expect(offer.sha256 == Self.sha256(Self.threeVersions[2].deb))
            #expect(offer.size == Self.threeVersions[2].deb.count)
            #expect(offer.repo.id == "chariz")
            #expect(offer.name == "Cephei")
            #expect(fetcher.maxBytes(for: Self.chariz + "Release") == 1024 * 1024)
            // Release and the index may only redirect on the repo's host.
            #expect(fetcher.origin(for: Self.chariz + "Release") == .some(URL(string: Self.chariz)!))
            #expect(fetcher.origin(for: Self.chariz + "Packages") == .some(URL(string: Self.chariz)!))
            // Index work files are gone.
            #expect(Self.isEmpty(dir))
        }
    }

    @Test func prefersTheTweaksArchitecture() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            Self.serveRepo(fetcher, Self.threeVersions + [Pkg("3.0", arch: "iphoneos-arm64e")])
            let c = client(fetcher, dir)
            let dep = DebDependency(package: Self.cephei, relation: ">=", version: "1.16")
            let rootful = try await c.offer(for: dep, preferredArchitecture: "iphoneos-arm")
            #expect(rootful.version == "1.16" && rootful.architecture == "iphoneos-arm")
            // No preference: arm64 first, never arm64e even when it's newer.
            let none = try await c.offer(for: dep, preferredArchitecture: nil)
            #expect(none.version == "2.0" && none.architecture == "iphoneos-arm64")
            let e = try await c.offer(for: dep, preferredArchitecture: "iphoneos-arm64e")
            #expect(e.architecture == "iphoneos-arm64")
            // Preferred arch missing: falls back to arm64, then arm.
            let only = FakeFetcher()
            Self.serveRepo(only, [Pkg("1.16", arch: "iphoneos-arm")])
            let fallback = try await client(only, dir).offer(for: dep, preferredArchitecture: "iphoneos-arm64")
            #expect(fallback.architecture == "iphoneos-arm")
        }
    }

    /// The allowlist is per package: another vendor's package on the same (multi-vendor) repo that
    /// says `Provides: ws.hbang.common` is never offered, even with a higher version.
    @Test func providesIsNeverOffered() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            var p = Pkg("99"); p.package = "com.anyone.x"; p.provides = "ws.hbang.common"
            Self.serveRepo(fetcher, [p])
            await #expect(throws: RepoError.notFound(Self.cephei)) {
                try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
            // Next to the real package, the real one wins.
            let both = FakeFetcher()
            Self.serveRepo(both, [p, Pkg("2.0")])
            let offer = try await client(both, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            #expect(offer.packageID == Self.cephei && offer.version == "2.0")
            // An allowlisted repo's package that isn't on its list is not looked up there.
            await #expect(throws: RepoError.notAllowlisted) {
                try await client(both, dir).offer(for: DebDependency(package: "com.anyone.x"), preferredArchitecture: nil)
            }
        }
    }

    @Test func noVersionSatisfying() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            Self.serveRepo(fetcher, Self.threeVersions + [Pkg("9.0", arch: "iphoneos-arm64e")])
            let c = client(fetcher, dir)
            await #expect(throws: RepoError.noVersionSatisfying(Self.cephei)) {
                try await c.offer(for: DebDependency(package: Self.cephei, relation: ">=", version: "3.0"), preferredArchitecture: nil)
            }
            // A stanza without SHA256 is not a candidate.
            let noHash = FakeFetcher()
            var p = Pkg("2.0"); p.sha256 = ""
            Self.serveRepo(noHash, [p])
            await #expect(throws: RepoError.noVersionSatisfying(Self.cephei)) {
                try await client(noHash, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
            // Not in the index at all.
            let other = FakeFetcher()
            var q = Pkg("1.0"); q.package = "com.other"
            Self.serveRepo(other, [q])
            await #expect(throws: RepoError.notFound(Self.cephei)) {
                try await client(other, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
            // An unreadable constraint is satisfied by nothing.
            await #expect(throws: RepoError.noVersionSatisfying(Self.cephei)) {
                try await c.offer(for: DebDependency(package: Self.cephei, unparseable: true), preferredArchitecture: nil)
            }
        }
    }

    @Test func notAllowlisted() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            Self.serveRepo(fetcher, Self.threeVersions)
            await #expect(throws: RepoError.notAllowlisted) {
                try await client(fetcher, dir).offer(for: DebDependency(package: "com.evil.tweak"), preferredArchitecture: nil)
            }
            #expect(fetcher.fetched.isEmpty)
            // An offer for a repo that isn't on the list is not downloaded either.
            let evil = TrustedRepo(id: "evil", name: "Evil", base: URL(string: "https://evil.example/")!, indexPath: "", packages: [Self.cephei])
            let offer = RepoOffer(repo: evil, packageID: Self.cephei, name: "Cephei", version: "1", architecture: "iphoneos-arm64",
                                  url: URL(string: "https://evil.example/x.deb")!, size: 3, sha256: String(repeating: "0", count: 64))
            await #expect(throws: RepoError.notAllowlisted) { try await client(fetcher, dir).download(offer) }
            // A trusted repo, but a package it isn't trusted for.
            let chariz = TrustedRepos.offering(Self.cephei)[0]
            let other = RepoOffer(repo: chariz, packageID: "com.anyone.x", name: "Cephei", version: "1", architecture: "iphoneos-arm64",
                                  url: URL(string: Self.chariz + "debs/x.deb")!, size: 3, sha256: String(repeating: "0", count: 64))
            await #expect(throws: RepoError.notAllowlisted) { try await client(fetcher, dir).download(other) }
            #expect(fetcher.fetched.isEmpty)
        }
    }

    /// opa334.github.io is not on it: its Release publishes no hashes (checked 2026-11-09).
    @Test func allowlistIsChariz() {
        #expect(TrustedRepos.all.map(\.id) == ["chariz"])
        #expect(TrustedRepos.offering("ws.hbang.common").map(\.base.absoluteString) == ["https://repo.chariz.com/"])
        #expect(TrustedRepos.offering("com.opa334.altlist").isEmpty)
        #expect(TrustedRepos.offering("com.evil").isEmpty)
        for r in TrustedRepos.all {
            #expect(r.base.scheme == "https" && r.base.absoluteString.hasSuffix("/") && r.indexPath.isEmpty)
        }
    }

    @Test func indexHashMismatchStops() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            Self.serveRepo(fetcher, Self.threeVersions)
            // The index served differs from what Release lists (same size, one byte changed).
            var tampered = Self.index(Self.threeVersions)
            tampered[tampered.startIndex] ^= 0x20
            fetcher.serve(Self.chariz + "Packages", tampered)
            let c = client(fetcher, dir)
            await #expect(throws: RepoError.indexHashMismatch) {
                try await c.offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
            // Shorter than Release says (within the cap): refused on the size, before hashing.
            fetcher.serve(Self.chariz + "Packages", Self.index(Self.threeVersions).dropLast())
            await #expect(throws: RepoError.indexHashMismatch) {
                try await c.offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
            // Longer: the cap (the Release size) stops it.
            fetcher.serve(Self.chariz + "Packages", Self.index(Self.threeVersions) + Data("\n".utf8))
            await #expect(throws: RepoError.tooLarge) {
                try await c.offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
            // The index is fetched with the Release size as its cap.
            #expect(fetcher.maxBytes(for: Self.chariz + "Packages") == Self.index(Self.threeVersions).count)
            #expect(!fetcher.fetched.contains { $0.pathExtension == "deb" })
            #expect(Self.isEmpty(dir))
        }
    }

    @Test func oversizedIndexIsRefusedBeforeFetching() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            let release = "SHA256:\n \(String(repeating: "a", count: 64)) \(32 * 1024 * 1024 + 1) Packages\n"
            fetcher.serve(Self.chariz + "Release", Data(release.utf8))
            await #expect(throws: RepoError.tooLarge) {
                try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
            #expect(fetcher.fetched.map(\.lastPathComponent) == ["Release"])
        }
    }

    @Test func downloadWithWrongHashIsRejectedAndDeleted() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            Self.serveRepo(fetcher, Self.threeVersions)
            let c = client(fetcher, dir)
            let offer = try await c.offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            // Same size, other bytes.
            var evil = Self.threeVersions[2].deb
            evil[evil.startIndex] ^= 1
            fetcher.serve(offer.url.absoluteString, evil)
            await #expect(throws: RepoError.hashMismatch) { try await c.download(offer) }
            #expect(Self.isEmpty(dir))
            // The right bytes, even through a redirect to another HTTPS host, are accepted.
            fetcher.serve(offer.url.absoluteString, Self.threeVersions[2].deb, final: "https://cdn.example/x.deb")
            let file = try await c.download(offer)
            #expect(file.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
            #expect(try Data(contentsOf: file) == Self.threeVersions[2].deb)
            #expect(fetcher.maxBytes(for: offer.url.absoluteString) == offer.size)
            #expect(fetcher.origin(for: offer.url.absoluteString) == .some(nil))
            #expect(Self.entries(dir) == 1)
        }
    }

    @Test func sizeMismatchIsRejected() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            Self.serveRepo(fetcher, Self.threeVersions)
            let c = client(fetcher, dir)
            let offer = try await c.offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            fetcher.serve(offer.url.absoluteString, Self.threeVersions[2].deb.dropLast())
            await #expect(throws: RepoError.sizeMismatch) { try await c.download(offer) }
            #expect(Self.isEmpty(dir))
            // Longer than announced: the fetcher's cap stops it.
            fetcher.serve(offer.url.absoluteString, Self.threeVersions[2].deb + Data([0]))
            await #expect(throws: RepoError.tooLarge) { try await c.download(offer) }
            #expect(Self.isEmpty(dir))
        }
    }

    @Test func oversizedDebIsRefused() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            var p = Pkg("2.0"); p.size = String(DebLimits.maxDebBytes + 1)
            Self.serveRepo(fetcher, [p])
            await #expect(throws: RepoError.tooLarge) {
                try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
        }
    }

    @Test func badFilenamesAreRefused() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let bad = ["../x.deb", "/abs.deb", "https://evil/x.deb", "debs/../../x.deb", "//evil.example/x.deb",
                       "debs/%2e%2e/%2e%2e/x.deb", "debs\\..\\x.deb", "debs/x.deb?y", "debs/x.deb#y", "http:x.deb",
                       "debs/..", "", "debs/x y.deb", "debs//x.deb", "debs/."]
            for name in bad {
                let fetcher = FakeFetcher()
                Self.serveRepo(fetcher, [Pkg("2.0", filename: name)])
                await #expect(throws: RepoError.badFilename, "\(name)") {
                    try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
                }
                #expect(!fetcher.fetched.contains { $0.pathExtension == "deb" })
            }
            // "./" is fine and stays under the base.
            let fetcher = FakeFetcher()
            Self.serveRepo(fetcher, [Pkg("2.0", filename: "./debs/cephei.deb")])
            let offer = try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            #expect(offer.url.absoluteString == Self.chariz + "debs/cephei.deb")
        }
    }

    @Test func md5OnlyReleaseHasNoIndex() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            Self.serveRepo(fetcher, Self.threeVersions, kinds: .md5Only)
            await #expect(throws: RepoError.noIndex) {
                try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
            #expect(fetcher.fetched.map(\.lastPathComponent) == ["Release"])
            // Garbage hashes in the SHA256 block are not an index either.
            fetcher.serve(Self.chariz + "Release", Data("SHA256:\n nothex 12 Packages\n zz\n".utf8))
            await #expect(throws: RepoError.noIndex) {
                try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
        }
    }

    @Test func sha512ReleaseWorks() async throws {
        try await withTemporaryDirectory("repo") { dir in
            // Chariz shape: SHA512 and MD5 only, a gzip index.
            let fetcher = FakeFetcher()
            let idx = Self.index(Self.threeVersions)
            let gz = try Self.gzip(idx, dir)
            fetcher.serve(Self.chariz + "Release", Self.release([("Packages.gz", gz)], .sha512AndMD5))
            fetcher.serve(Self.chariz + "Packages.gz", gz)
            let offer = try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            #expect(offer.version == "2.0")
            #expect(fetcher.fetched.map(\.lastPathComponent) == ["Release", "Packages.gz"])
            // A tampered gzip index fails its SHA512.
            var bad = gz; bad[bad.index(bad.startIndex, offsetBy: 20)] ^= 0xFF
            fetcher.serve(Self.chariz + "Packages.gz", bad)
            await #expect(throws: RepoError.indexHashMismatch) {
                try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
        }
    }

    @Test func gzipIsTheLastChoiceAmongIndexes() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            let idx = Self.index(Self.threeVersions)
            let gz = try Self.gzip(idx, dir)
            fetcher.serve(Self.chariz + "Release", Self.release([("Packages.gz", gz), ("Packages", idx)]))
            fetcher.serve(Self.chariz + "Packages.gz", gz)
            fetcher.serve(Self.chariz + "Packages", idx)
            _ = try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            #expect(fetcher.fetched.map(\.lastPathComponent) == ["Release", "Packages"])
        }
    }

    @Test func releaseOrIndexOffTheTrustedHostIsRefused() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            Self.serveRepo(fetcher, Self.threeVersions)
            fetcher.serve(Self.chariz + "Release", Self.release([("Packages", Self.index(Self.threeVersions))]),
                          final: "https://mirror.example/Release")
            await #expect(throws: RepoError.notAllowlisted) {
                try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
            Self.serveRepo(fetcher, Self.threeVersions)
            fetcher.serve(Self.chariz + "Packages", Self.index(Self.threeVersions), final: "https://mirror.example/Packages")
            await #expect(throws: RepoError.notAllowlisted) {
                try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
            #expect(Self.isEmpty(dir))
        }
    }

    @Test func missingIndexFallsBackToTheNextListed() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            let idx = Self.index(Self.threeVersions)
            // Release lists Packages.xz, but the server doesn't have it (404).
            fetcher.serve(Self.chariz + "Release", Self.release([("Packages.xz", Data("xz".utf8)), ("Packages", idx)]))
            fetcher.serve(Self.chariz + "Packages", idx)
            let offer = try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            #expect(offer.version == "2.0")
            #expect(fetcher.fetched.map(\.lastPathComponent) == ["Release", "Packages.xz", "Packages"])
            // Another failure (not a 404) stops there.
            fetcher.fail(Self.chariz + "Packages.xz", .httpStatus(500))
            await #expect(throws: RepoError.httpStatus(500)) {
                try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
            // All listed indexes missing: the 404 is reported.
            let none = FakeFetcher()
            none.serve(Self.chariz + "Release", Self.release([("Packages", idx)]))
            await #expect(throws: RepoError.httpStatus(404)) {
                try await client(none, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
        }
    }

    @Test func corruptVerifiedIndexIsNoIndex() async throws {
        try await withTemporaryDirectory("repo") { dir in
            // Hash-verified but not a gzip stream: unusable, not "too large".
            let fetcher = FakeFetcher()
            let junk = Data("not gzip at all".utf8)
            fetcher.serve(Self.chariz + "Release", Self.release([("Packages.gz", junk)]))
            fetcher.serve(Self.chariz + "Packages.gz", junk)
            await #expect(throws: RepoError.noIndex) {
                try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
            #expect(Self.isEmpty(dir))
        }
    }

    @Test func fetchErrorsPassThrough() async throws {
        try await withTemporaryDirectory("repo") { dir in
            let fetcher = FakeFetcher()
            fetcher.fail(Self.chariz + "Release", .timedOut)
            await #expect(throws: RepoError.timedOut) {
                try await client(fetcher, dir).offer(for: DebDependency(package: Self.cephei), preferredArchitecture: nil)
            }
            #expect(Self.isEmpty(dir))
        }
    }

    static func entries(_ dir: URL) -> Int { (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? -1 }
    static func isEmpty(_ dir: URL) -> Bool { entries(dir) == 0 }

    static func gzip(_ data: Data, _ dir: URL) throws -> Data {
        let src = dir.appendingPathComponent("gz-src-\(UUID().uuidString)")
        let out = dir.appendingPathComponent("gz-out-\(UUID().uuidString)")
        try data.write(to: src)
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: out) }
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); p.arguments = ["-c"]
        p.standardInput = try FileHandle(forReadingFrom: src)
        p.standardOutput = try FileHandle(forWritingTo: out)
        try p.run(); p.waitUntilExit()
        return try Data(contentsOf: out)
    }
}
