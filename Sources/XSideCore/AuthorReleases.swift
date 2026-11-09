import Foundation
import CryptoKit

/// A GitHub repo whose releases publish a dependency's `.deb` (its author's own).
public struct GitHubSource: Equatable, Hashable, Sendable {
    public let owner: String
    public let repo: String

    public init(owner: String, repo: String) {
        self.owner = owner
        self.repo = repo
    }

    /// What the kept copy and the tweak's origin record as their repo.
    public var id: String { "github:\(owner)/\(repo)" }
    public var name: String { "GitHub \(owner)/\(repo)" }
    public var page: URL { URL(string: "https://github.com/\(owner)/\(repo)/releases")! }
    var api: URL { URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=30")! }
    /// Every asset URL of the repo's releases starts with this.
    var downloadPrefix: String { "https://github.com/\(owner)/\(repo)/releases/download/" }
}

/// « Les versions GitHub de l'auteur »: for a few known dependencies whose author publishes no repo
/// with hashes, the `.deb` of the author's GitHub releases. The trust is HTTPS, the pinned
/// owner/repo (a code change with a review, never a setting) and the `.deb`'s own control
/// (package id and version), checked after download; no hash is published, and the confirmation
/// says so. Never used for a package that isn't pinned here.
public enum AuthorReleases {
    public static let pinned: [String: GitHubSource] = [
        // AltList: opa334's repo publishes no hashes (see TrustedRepos).
        "com.opa334.altlist": GitHubSource(owner: "opa334", repo: "AltList"),
    ]

    static let apiOrigin = URL(string: "https://api.github.com/")!
    /// The asset's URL on github.com redirects to one of the CDN hosts.
    public static let assetHosts: Set<String> = ["github.com", "objects.githubusercontent.com",
                                                 "release-assets.githubusercontent.com"]
    public static let maxListBytes = 4 * 1024 * 1024
    static let maxReleases = 100
    static let maxAssets = 100

    public static func source(for packageID: String) -> GitHubSource? { pinned[packageID.lowercased()] }

    /// The pinned source a kept copy's repo id names, if it is still pinned.
    public static func source(id: String) -> GitHubSource? { pinned.values.first { $0.id == id } }
}

/// One release asset XSide would download: shown before anything is downloaded.
public struct ReleaseOffer: Equatable, Sendable {
    public let source: GitHubSource
    public let packageID: String
    public let version: String
    public let architecture: String
    public let url: URL
    public let size: Int
    public let assetName: String
    /// What it was looked up for: the downloaded `.deb`'s version must satisfy it too.
    public let dependency: DebDependency

    public init(source: GitHubSource, packageID: String, version: String, architecture: String, url: URL, size: Int,
                assetName: String, dependency: DebDependency? = nil) {
        self.dependency = dependency ?? DebDependency(package: packageID)
        self.source = source
        self.packageID = packageID
        self.version = version
        self.architecture = architecture
        self.url = url
        self.size = size
        self.assetName = assetName
    }
}

/// Asks the GitHub releases API of a pinned repo (only after the click) and downloads one asset.
/// The API call never leaves api.github.com; the asset may only go through `assetHosts`.
public struct AuthorReleaseClient: Sendable {
    private let fetcher: HTTPFetching
    private let runner: CommandRunning
    private let workDir: URL
    private let log = Log("repo")

    public init(fetcher: HTTPFetching, runner: CommandRunning, workDir: URL) {
        self.fetcher = fetcher
        self.runner = runner
        self.workDir = workDir
    }

    // MARK: - Offer

    public func offer(for dependency: DebDependency, preferredArchitecture: String?) async throws -> ReleaseOffer {
        let id = dependency.package.lowercased()
        guard let source = AuthorReleases.source(for: id) else {
            log.notice("\(id): no pinned GitHub releases")
            throw RepoError.notAllowlisted
        }
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let file = workDir.appendingPathComponent(".releases-\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: file) }
        let final = try await fetcher.fetch(source.api, maxBytes: AuthorReleases.maxListBytes, to: file,
                                            stayingOn: AuthorReleases.apiOrigin)
        guard RedirectPolicy.sameOrigin(final, AuthorReleases.apiOrigin) else {
            log.error("\(source.id): the releases list ended on \(RepoLog.display(final)), off api.github.com")
            throw RepoError.notAllowlisted
        }
        let data = try Data(contentsOf: file)
        let offer = try Self.choose(data, id: id, dependency: dependency, source: source,
                                    order: RepoClient.architectureOrder(preferredArchitecture))
        log.notice("\(id): offering \(offer.assetName) (\(offer.version), \(offer.architecture)) from \(source.id), \(offer.size) bytes")
        return offer
    }

    /// The release assets that are a `.deb` of the pinned repo for an allowed architecture, whose
    /// version satisfies the dependency and whose size fits: the best architecture, then the
    /// highest version. Drafts and pre-releases are skipped; unreadable JSON is no release.
    static func choose(_ data: Data, id: String, dependency: DebDependency, source: GitHubSource,
                       order: [String]) throws -> ReleaseOffer {
        let releases = (try? JSONSerialization.jsonObject(with: data)) as? [Any] ?? []
        var matched = false
        var best: (offer: ReleaseOffer, rank: Int)?
        for case let release as [String: Any] in releases.prefix(AuthorReleases.maxReleases) {
            if release["draft"] as? Bool == true || release["prerelease"] as? Bool == true { continue }
            let tag = release["tag_name"] as? String ?? ""
            for case let asset as [String: Any] in (release["assets"] as? [Any] ?? []).prefix(AuthorReleases.maxAssets) {
                guard let name = asset["name"] as? String, let (arch, nameVersion) = parse(name, id: id),
                      let rank = order.firstIndex(of: arch) else { continue }
                guard let size = (asset["size"] as? NSNumber).flatMap({ Int(exactly: $0.doubleValue) }),
                      size > 0, size <= DebLimits.maxDebBytes else { continue }
                guard let link = asset["browser_download_url"] as? String, let url = assetURL(link, of: source) else { continue }
                let version = nameVersion ?? versionOf(tag: tag)
                guard let version, isPlainVersion(version) else { continue }
                matched = true
                guard dependency.isSatisfied(by: version) else { continue }
                if let b = best {
                    if rank > b.rank { continue }
                    if rank == b.rank, DebVersion.compare(version, b.offer.version) != .orderedDescending { continue }
                }
                best = (ReleaseOffer(source: source, packageID: id, version: version, architecture: arch, url: url,
                                     size: size, assetName: name, dependency: dependency), rank)
            }
        }
        guard let best else { throw matched ? RepoError.noVersionSatisfying(id) : RepoError.notFound(id) }
        return best.offer
    }

    /// `<id>_<version>_<arch>.deb` gives both; any other `…_<arch>.deb` or `…-<arch>.deb` gives the
    /// architecture only (the version is the tag's). arm64e and other architectures: nil.
    static func parse(_ name: String, id: String) -> (arch: String, version: String?)? {
        let lower = name.lowercased()
        guard lower.utf8.count <= 256, lower.hasSuffix(".deb") else { return nil }
        let stem = String(lower.dropLast(4))
        for arch in RepoClient.fallbackArchitectures.sorted(by: { $0.count > $1.count }) {
            for sep in ["_", "-"] where stem.hasSuffix(sep + arch) {
                let head = String(stem.dropLast(arch.count + 1))
                if sep == "_", head.hasPrefix(id + "_") {
                    let v = String(head.dropFirst(id.count + 1))
                    return (arch, v.isEmpty ? nil : v)
                }
                return (arch, nil)
            }
        }
        return nil
    }

    static func versionOf(tag: String) -> String? {
        var t = Substring(tag)
        if t.first == "v" || t.first == "V" { t = t.dropFirst() }
        return t.isEmpty ? nil : String(t)
    }

    /// A Debian version's characters, at most 64 bytes, starting with a digit.
    static func isPlainVersion(_ v: String) -> Bool {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+~-:".utf8)
        guard let first = v.utf8.first, first >= 48, first <= 57 else { return false }
        return v.utf8.count <= 64 && v.utf8.allSatisfy(ok.contains)
    }

    /// `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>`: nothing else, no "..",
    /// no query or fragment.
    static func assetURL(_ link: String, of source: GitHubSource) -> URL? {
        guard link.utf8.count <= 1024, link.lowercased().hasPrefix(source.downloadPrefix.lowercased()),
              let url = URL(string: link), RedirectPolicy.isOn(url, ["github.com"]),
              url.query == nil, url.fragment == nil else { return nil }
        let rest = String(link.dropFirst(source.downloadPrefix.count))
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              let decoded = rest.removingPercentEncoding,
              !decoded.contains(".."), !decoded.contains("\\"), decoded.split(separator: "/").count == 2 else { return nil }
        return url
    }

    // MARK: - Download

    /// The asset, capped at its listed size and checked: exactly that size, a readable `.deb`
    /// whose control `Package` is the dependency and whose `Version` satisfies it. Returns the work
    /// file (the caller keeps it), its SHA256 and the control's version. Nothing is left behind on
    /// any failure.
    public func download(_ offer: ReleaseOffer, for dependency: DebDependency) async throws
        -> (file: URL, sha256: String, version: String) {
        let id = dependency.package.lowercased()
        guard offer.packageID == id, AuthorReleases.source(for: id) == offer.source,
              Self.assetURL(offer.url.absoluteString, of: offer.source) != nil else {
            log.error("download refused, not a pinned release asset: \(offer.packageID) \(RepoLog.display(offer.url))")
            throw RepoError.notAllowlisted
        }
        guard offer.size > 0, offer.size <= DebLimits.maxDebBytes else { throw RepoError.tooLarge }
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let partial = workDir.appendingPathComponent(".\(UUID().uuidString).partial")
        do {
            let final = try await fetcher.fetch(offer.url, maxBytes: offer.size, to: partial,
                                                redirectingWithin: AuthorReleases.assetHosts)
            guard RedirectPolicy.isOn(final, AuthorReleases.assetHosts) else {
                log.error("\(RepoLog.display(offer.url)) ended on \(RepoLog.display(final)), off GitHub's hosts")
                throw RepoError.notAllowlisted
            }
            var st = stat()
            guard lstat(partial.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, Int(st.st_size) == offer.size else {
                log.error("\(RepoLog.display(offer.url)): not the \(offer.size) bytes the release lists")
                throw RepoError.sizeMismatch
            }
            let control: DebControl
            do {
                control = try DebControl.parse(try await DebReader.control(of: partial, runner: runner))
            } catch {
                log.error("\(RepoLog.display(offer.url)): unreadable .deb (\(error))")
                throw RepoError.packageMismatch
            }
            guard control.package == id, let version = control.version, dependency.isSatisfied(by: version) else {
                log.error("\(RepoLog.display(offer.url)): its control says \(control.package) \(control.version ?? "?"), wanted \(id) \(DependencyDirectory.constraint(dependency) ?? "")")
                throw RepoError.packageMismatch
            }
            let sha = try RepoClient.hexDigest(of: partial, sha512: false)
            log.notice("downloaded \(id) \(version) from \(RepoLog.display(final)) (\(offer.source.id), no published hash): \(offer.size) bytes, SHA256 \(sha)")
            return (partial, sha, version)
        } catch {
            try? fm.removeItem(at: partial)
            log.error("download of \(RepoLog.display(offer.url)) failed: \(error)")
            throw error
        }
    }
}
