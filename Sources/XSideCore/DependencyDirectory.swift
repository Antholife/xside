import Foundation

/// Where a tweak's missing dependency can be found: a page XSide knows, else two package search
/// sites. These links are only opened in the browser, never fetched by XSide.
public enum DependencyDirectory {
    private static let pages: [String: String] = [
        "ws.hbang.common": "https://chariz.com/get/cephei",
        "com.opa334.altlist": "https://github.com/opa334/AltList",
        "libroot": "https://github.com/opa334/libroot",
        "com.opa334.libroot": "https://github.com/opa334/libroot",
        "com.mrgcgamer.libgcuniversal": "https://github.com/MrGcGamer/LibGcUniversalDocumentation",
    ]

    /// The package's own page, when XSide knows it.
    public static func page(for packageID: String) -> URL? {
        pages[packageID].flatMap(URL.init(string:))
    }

    /// Canister, then iOS Repo Updates (both answered 200 on 2026-11-09). Only for something that
    /// looks like a package id (`^[a-z0-9][a-z0-9+.-]{1,127}$`), else none.
    public static func searchURLs(for packageID: String) -> [URL] {
        guard looksLikePackageID(packageID) else { return [] }
        // Only "+" of the allowed characters means something in a query.
        let q = packageID.replacingOccurrences(of: "+", with: "%2B")
        return ["https://canister.me/search?q=" + q, "https://www.ios-repo-updates.com/search/?s=" + q]
            .compactMap(URL.init(string:))
    }

    static func looksLikePackageID(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count >= 2, bytes.count <= 128 else { return false }
        func isAlnum(_ c: UInt8) -> Bool { (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) }
        guard isAlnum(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { isAlnum($0) || $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }
    }

    /// The version a dependency asks for, as shown (« ≥ 1.16 »); nil when any version will do,
    /// "?" when it couldn't be read.
    public static func constraint(_ dependency: DebDependency) -> String? {
        if dependency.unparseable { return "?" }
        guard let relation = dependency.relation, let version = dependency.version else { return nil }
        let symbol: String
        switch relation {
        case ">=": symbol = "≥"
        case "<=": symbol = "≤"
        case ">>": symbol = ">"
        case "<<": symbol = "<"
        default: symbol = relation
        }
        return symbol + " " + version
    }

    /// A `.deb` the person added for `dependency`: the classifier's rule, so that an accepted one
    /// then shows as added. Its exact package id is checked against the version; a `Provides`
    /// (whose versions XSide doesn't read) only stands for a dependency without a version.
    public static func check(_ package: TweakPackage, for dependency: DebDependency) -> DependencyMatch {
        let wanted = dependency.package
        if package.packageID == wanted {
            if !dependency.unparseable, dependency.relation == nil { return .matches }
            if let v = package.version, dependency.isSatisfied(by: v) { return .matches }
            return .tooOld(found: package.version ?? "?", needed: constraint(dependency) ?? "?")
        }
        if package.provides.contains(wanted), !dependency.unparseable, dependency.relation == nil { return .matches }
        return .wrongPackage(found: package.packageID, wanted: wanted)
    }
}

/// Whether an added `.deb` is the dependency it was added for.
public enum DependencyMatch: Equatable, Sendable {
    case matches
    case wrongPackage(found: String, wanted: String)
    /// Its version doesn't meet the constraint (`needed`, as `DependencyDirectory.constraint` writes it).
    case tooOld(found: String, needed: String)
}

/// Where a dependency's `.deb` would come from: a copy XSide kept (no network), or a trusted repo.
public enum DependencySource: Equatable, Sendable {
    case cached(CachedDownload)
    case repo(RepoOffer)

    public var isCached: Bool { if case .cached = self { true } else { false } }

    public var version: String {
        switch self {
        case .cached(let c): c.version
        case .repo(let o): o.version
        }
    }

    /// The repo's display name (its id when it's no longer in the allowlist).
    public var repoName: String {
        switch self {
        case .cached(let c): TrustedRepos.all.first { $0.id == c.repo }?.name ?? c.repo
        case .repo(let o): o.repo.name
        }
    }

    public var repoURL: URL? {
        switch self {
        case .cached(let c): TrustedRepos.all.first { $0.id == c.repo }?.base
        case .repo(let o): o.repo.base
        }
    }

    public var debURL: String {
        switch self {
        case .cached(let c): c.source
        case .repo(let o): o.url.absoluteString
        }
    }

    /// In bytes; nil for a kept copy (nothing to download).
    public var size: Int? {
        switch self {
        case .cached: nil
        case .repo(let o): o.size
        }
    }
}

/// « Télécharger »: a kept copy that satisfies the dependency first (no network), otherwise the
/// trusted repo's offer; once the person confirms, the verified `.deb` is kept in the library.
/// The caller asks between `prepare` and `fetch`, and only calls `prepare` after the click.
public struct DependencyDownloader: Sendable {
    public enum Failure: Equatable, Sendable { case hash, network, notFound }

    let library: AppLibrary
    let client: RepoClient

    public init(library: AppLibrary, client: RepoClient) {
        self.library = library
        self.client = client
    }

    public func prepare(_ dependency: DebDependency, preferredArchitecture: String?) async throws -> DependencySource {
        // Only what a trusted repo offers is ever downloaded or reused.
        guard !TrustedRepos.offering(dependency.package).isEmpty else { throw RepoError.notAllowlisted }
        if let kept = await library.cachedDownloadEntry(packageID: dependency.package.lowercased(), satisfying: dependency) {
            return .cached(kept)
        }
        return .repo(try await client.offer(for: dependency, preferredArchitecture: preferredArchitecture))
    }

    /// The kept `.deb` and the origin to store its package with.
    public func fetch(_ source: DependencySource) async throws -> (file: URL, origin: TweakOrigin) {
        switch source {
        case .cached(let c):
            return (c.url, .downloaded(repo: c.repo, url: c.source, sha256: c.sha256))
        case .repo(let offer):
            let file = try await client.download(offer)
            defer { try? FileManager.default.removeItem(at: file) }
            let kept = try await library.storeDownload(file, sha256: offer.sha256, packageID: offer.packageID,
                                                       version: offer.version, repo: offer.repo.id,
                                                       url: offer.url.absoluteString)
            return (kept, .downloaded(repo: offer.repo.id, url: offer.url.absoluteString, sha256: offer.sha256.lowercased()))
        }
    }

    /// Which message an error gets.
    public static func failure(_ error: any Error) -> Failure {
        switch error as? RepoError {
        case .hashMismatch?, .sizeMismatch?, .indexHashMismatch?: .hash
        case .notFound?, .noVersionSatisfying?, .notAllowlisted?, .badFilename?, .tooLarge?: .notFound
        default: .network
        }
    }
}
