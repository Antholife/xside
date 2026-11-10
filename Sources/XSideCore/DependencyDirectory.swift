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
            let found = package.version ?? "?", needed = constraint(dependency) ?? "?"
            guard package.version != nil, !dependency.unparseable else { return .unsuitable(found: found, needed: needed) }
            switch dependency.relation {
            case ">=", ">>": return .tooOld(found: found, needed: needed)
            case "<=", "<<": return .tooNew(found: found, needed: needed)
            default: return .unsuitable(found: found, needed: needed)
            }
        }
        if package.provides.contains(wanted), !dependency.unparseable, dependency.relation == nil { return .matches }
        return .wrongPackage(found: package.packageID, wanted: wanted)
    }
}

/// Whether an added `.deb` is the dependency it was added for.
public enum DependencyMatch: Equatable, Sendable {
    case matches
    case wrongPackage(found: String, wanted: String)
    /// Its version is under a lower bound (`needed`, as `DependencyDirectory.constraint` writes it).
    case tooOld(found: String, needed: String)
    /// …over an upper bound.
    case tooNew(found: String, needed: String)
    /// …not the exact one asked for, unknown, or the constraint couldn't be read.
    case unsuitable(found: String, needed: String)
}

/// One device's status for a `Depends` group (`deviceID` nil: every device agrees).
public struct DependencyDeviceStatus: Equatable, Sendable {
    public let deviceID: String?
    /// The alternative the status is about.
    public let dependency: DebDependency
    public let status: DependencyStatus
    /// « Ajoutée par toi »: the version of the package that satisfies it.
    public let addedVersion: String?

    public init(deviceID: String?, dependency: DebDependency, status: DependencyStatus, addedVersion: String?) {
        self.deviceID = deviceID
        self.dependency = dependency
        self.status = status
        self.addedVersion = addedVersion
    }

    public var isMissing: Bool { if case .missing = status { true } else { false } }
}

/// One `Depends` group of a tweak across the devices it goes on: one status when they all agree,
/// else one per device, in the devices' order.
public struct DependencyRow: Equatable, Sendable, Identifiable {
    public let id: Int
    public let statuses: [DependencyDeviceStatus]

    public init(id: Int, statuses: [DependencyDeviceStatus]) {
        self.id = id
        self.statuses = statuses
    }

    public var dependency: DebDependency { statuses.first?.dependency ?? DebDependency(package: "") }
    public var isMissingAnywhere: Bool { statuses.contains(where: \.isMissing) }
    /// What « Ajouter son .deb… » and « Télécharger » look for.
    public var missingDependency: DebDependency? { statuses.first(where: \.isMissing)?.dependency }
    /// The devices that miss it (none named when they all do: `deviceID` nil).
    public var missingDevices: [String] { statuses.filter(\.isMissing).compactMap(\.deviceID) }
}

public enum DependencyRows {
    /// Each device's statuses (`TweakClassifier.dependencies` with that device's context), merged
    /// per group. No device: no rows.
    public static func rows(_ package: TweakPackage, contexts: [(deviceID: String, context: TweakContext)]) -> [DependencyRow] {
        let perDevice = contexts.map { (id: $0.deviceID, list: statuses(package, $0.context)) }
        guard let first = perDevice.first else { return [] }
        return first.list.indices.map { i in
            let each = perDevice.compactMap { d in
                i < d.list.count ? DependencyDeviceStatus(deviceID: d.id, dependency: d.list[i].dependency,
                                                          status: d.list[i].status, addedVersion: d.list[i].addedVersion) : nil
            }
            let agree = each.allSatisfy {
                $0.dependency == each[0].dependency && $0.status == each[0].status && $0.addedVersion == each[0].addedVersion
            }
            return DependencyRow(id: i, statuses: agree
                ? [DependencyDeviceStatus(deviceID: nil, dependency: each[0].dependency, status: each[0].status,
                                          addedVersion: each[0].addedVersion)]
                : each)
        }
    }

    /// The package ids missing in `context` (for the device row's flag).
    public static func missing(_ package: TweakPackage, _ context: TweakContext) -> [String] {
        TweakClassifier.dependencies(package, context).compactMap { pair in
            if case .missing(let d) = pair.1 { d.package } else { nil }
        }
    }

    private static func statuses(_ package: TweakPackage, _ context: TweakContext)
        -> [(dependency: DebDependency, status: DependencyStatus, addedVersion: String?)] {
        TweakClassifier.dependencies(package, context).map { dep, status in
            var version: String?
            if case .addedByYou(let name) = status {
                version = context.others.first { p in
                    p.name == name && (p.packageID == dep.package || p.provides.contains(dep.package))
                }?.version
            }
            return (dep, status, version)
        }
    }
}

/// Where XSide may download a dependency from: a trusted repo (hash chain) or its author's pinned
/// GitHub releases (no published hash).
public enum DependencySources {
    /// « Télécharger » / « Mettre à jour » exist for it.
    public static func canDownload(_ packageID: String) -> Bool {
        !TrustedRepos.offering(packageID).isEmpty || AuthorReleases.source(for: packageID) != nil
    }

    /// The repo ids a kept copy of `packageID` may come from now.
    public static func trustedIDs(for packageID: String) -> Set<String> {
        Set(TrustedRepos.offering(packageID).map(\.id) + [AuthorReleases.source(for: packageID)?.id].compactMap { $0 })
    }

    /// A kept copy's or an origin's repo id as shown (the id itself when no longer known).
    public static func name(forRepoID id: String) -> String {
        TrustedRepos.all.first { $0.id == id }?.name ?? AuthorReleases.source(id: id)?.name ?? id
    }

    public static func url(forRepoID id: String) -> URL? {
        TrustedRepos.all.first { $0.id == id }?.base ?? AuthorReleases.source(id: id)?.page
    }

    /// What « Recherche dans … » names before anything is known.
    public static func name(for packageID: String) -> String {
        TrustedRepos.offering(packageID).first?.name ?? AuthorReleases.source(for: packageID)?.name ?? packageID
    }

    /// Where it would come from, for a tooltip.
    public static func places(for packageID: String) -> [String] {
        TrustedRepos.offering(packageID).map(\.base.absoluteString)
            + [AuthorReleases.source(for: packageID)?.page.absoluteString].compactMap { $0 }
    }
}

/// Where a dependency's `.deb` would come from: a copy XSide kept (no network), a trusted repo, or
/// the author's GitHub releases.
public enum DependencySource: Equatable, Sendable {
    case cached(CachedDownload)
    case repo(RepoOffer)
    case authorRelease(ReleaseOffer)

    public var isCached: Bool { if case .cached = self { true } else { false } }

    /// Checked against a hash its source published (false for GitHub releases, which publish none).
    public var isHashChecked: Bool {
        switch self {
        case .cached(let c): AuthorReleases.source(id: c.repo) == nil
        case .repo: true
        case .authorRelease: false
        }
    }

    public var version: String {
        switch self {
        case .cached(let c): c.version
        case .repo(let o): o.version
        case .authorRelease(let o): o.version
        }
    }

    /// The source's display name (its id when it's no longer trusted).
    public var repoName: String {
        switch self {
        case .cached(let c): DependencySources.name(forRepoID: c.repo)
        case .repo(let o): o.repo.name
        case .authorRelease(let o): o.source.name
        }
    }

    public var repoURL: URL? {
        switch self {
        case .cached(let c): DependencySources.url(forRepoID: c.repo)
        case .repo(let o): o.repo.base
        case .authorRelease(let o): o.source.page
        }
    }

    public var debURL: String {
        switch self {
        case .cached(let c): c.source
        case .repo(let o): o.url.absoluteString
        case .authorRelease(let o): o.url.absoluteString
        }
    }

    /// In bytes; nil for a kept copy (nothing to download).
    public var size: Int? {
        switch self {
        case .cached: nil
        case .repo(let o): o.size
        case .authorRelease(let o): o.size
        }
    }
}

/// « Télécharger »: a kept copy that satisfies the dependency first (no network), otherwise the
/// trusted repo's offer, otherwise the author's pinned GitHub releases; once the person confirms,
/// the verified `.deb` is kept in the library. The caller asks between `prepare` and `fetch`, and
/// only calls `prepare` after the click.
public struct DependencyDownloader: Sendable {
    public enum Failure: Equatable, Sendable { case hash, network, notFound, mismatch }

    let library: AppLibrary
    let client: RepoClient

    public init(library: AppLibrary, client: RepoClient) {
        self.library = library
        self.client = client
    }

    public func prepare(_ dependency: DebDependency, preferredArchitecture: String?) async throws -> DependencySource {
        let id = dependency.package.lowercased()
        // Only what a trusted repo or a pinned author's releases offer is ever downloaded or reused.
        guard DependencySources.canDownload(id) else { throw RepoError.notAllowlisted }
        let trusted = DependencySources.trustedIDs(for: id)
        // A kept copy only from a source trusted for this package now; any other is dropped.
        for _ in 0..<AppLibrary.maxDownloadEntries {
            guard let kept = await library.cachedDownloadEntry(packageID: id, satisfying: dependency, hold: true) else { break }
            if trusted.contains(kept.repo) { return .cached(kept) }
            await library.releaseDownload(sha256: kept.sha256)
            await library.removeDownload(sha256: kept.sha256)
        }
        return try await offer(dependency, preferredArchitecture: preferredArchitecture)
    }

    /// The trusted repos first; the author's releases when no repo offers it or they all failed.
    func offer(_ dependency: DebDependency, preferredArchitecture: String?) async throws -> DependencySource {
        let id = dependency.package.lowercased()
        var repoError: Error?
        if !TrustedRepos.offering(id).isEmpty {
            do {
                return .repo(try await client.offer(for: dependency, preferredArchitecture: preferredArchitecture))
            } catch {
                if error is CancellationError || AuthorReleases.source(for: id) == nil { throw error }
                repoError = error
            }
        }
        do {
            return .authorRelease(try await client.authorReleases.offer(for: dependency,
                                                                        preferredArchitecture: preferredArchitecture))
        } catch {
            throw repoError ?? error
        }
    }

    /// Lets go of what `prepare` (a kept copy) or `fetch` (a stored download, `fetched`) held, once
    /// the caller has added it or given up. Every `prepare` gets one call.
    public func release(_ source: DependencySource, fetched: TweakOrigin? = nil) async {
        if case .cached(let c) = source {
            await library.releaseDownload(sha256: c.sha256)
        } else if case .downloaded(_, _, let sha)? = fetched {
            await library.releaseDownload(sha256: sha)
        }
    }

    /// The kept `.deb` and the origin to store its package with. Held for a stored download:
    /// see `release`.
    public func fetch(_ source: DependencySource) async throws -> (file: URL, origin: TweakOrigin) {
        switch source {
        case .cached(let c):
            return (c.url, .downloaded(repo: c.repo, url: c.source, sha256: c.sha256))
        case .repo(let offer):
            let file = try await client.download(offer)
            defer { try? FileManager.default.removeItem(at: file) }
            let kept = try await library.storeDownload(file, sha256: offer.sha256, packageID: offer.packageID,
                                                       version: offer.version, repo: offer.repo.id,
                                                       url: offer.url.absoluteString, hold: true)
            return (kept, .downloaded(repo: offer.repo.id, url: offer.url.absoluteString, sha256: offer.sha256.lowercased()))
        case .authorRelease(let offer):
            let got = try await client.authorReleases.download(offer, for: offer.dependency)
            defer { try? FileManager.default.removeItem(at: got.file) }
            let kept = try await library.storeDownload(got.file, sha256: got.sha256, packageID: offer.packageID,
                                                       version: got.version, repo: offer.source.id,
                                                       url: offer.url.absoluteString, hold: true)
            return (kept, .downloaded(repo: offer.source.id, url: offer.url.absoluteString, sha256: got.sha256))
        }
    }

    /// Which message an error gets.
    public static func failure(_ error: any Error) -> Failure {
        switch error as? RepoError {
        case .hashMismatch?, .sizeMismatch?, .indexHashMismatch?: .hash
        case .packageMismatch?: .mismatch
        case .notFound?, .noVersionSatisfying?, .notAllowlisted?, .badFilename?, .tooLarge?: .notFound
        default: .network
        }
    }
}
