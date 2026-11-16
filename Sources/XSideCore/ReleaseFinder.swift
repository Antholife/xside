import Foundation

/// An installable file (`.ipa` or `.deb`) of a GitHub release, its URL already validated.
public struct ReleaseAsset: Equatable, Sendable {
    public let name: String
    public let url: URL
    public let size: Int

    public init(name: String, url: URL, size: Int) {
        self.name = name
        self.url = url
        self.size = size
    }
}

public struct FoundRelease: Equatable, Sendable {
    public let tag: String
    public let isPrerelease: Bool
    public let asset: ReleaseAsset
    /// `<tag>|<asset name>|<updated_at>`: changes when the release or its file is replaced.
    public let trigger: String

    public init(tag: String, isPrerelease: Bool, asset: ReleaseAsset, trigger: String) {
        self.tag = tag
        self.isPrerelease = isPrerelease
        self.asset = asset
        self.trigger = trigger
    }
}

public enum ReleaseKind: Sendable { case ipa, deb }

public enum ReleaseFind: Equatable, Sendable {
    case found(FoundRelease)
    case ambiguous(assets: [ReleaseAsset])
    case none
}

/// Reads a repo's GitHub releases JSON and finds the `.ipa`/`.deb` to follow. A sibling of
/// `AuthorReleaseClient.choose` (which picks a dependency's `.deb`); asset URLs go through the
/// same validator.
public enum ReleaseFinder {
    private typealias Entry = (tag: String, isPrerelease: Bool, asset: ReleaseAsset, updatedAt: String)

    public static func installableAssets(_ listJSON: Data, source: GitHubSource, kind: ReleaseKind) throws
        -> [(tag: String, isPrerelease: Bool, asset: ReleaseAsset)] {
        entries(listJSON, source: source, kind: kind).map { ($0.tag, $0.isPrerelease, $0.asset) }
    }

    public static func choose(_ listJSON: Data, source: GitHubSource, kind: ReleaseKind,
                              variant: VariantSelector) throws -> ReleaseFind {
        let all = entries(listJSON, source: source, kind: kind)
        // Release by release, newest first: the first release with a matching asset is the one.
        var order: [String] = []
        for e in all where !order.contains(e.tag) { order.append(e.tag) }
        for tag in order {
            let matching = all.filter { $0.tag == tag && variant.matches($0.asset.name) }
            switch matching.count {
            case 0: continue
            case 1:
                let e = matching[0]
                return .found(FoundRelease(tag: e.tag, isPrerelease: e.isPrerelease, asset: e.asset,
                                           trigger: "\(e.tag)|\(e.asset.name)|\(e.updatedAt)"))
            default: return .ambiguous(assets: matching.map(\.asset))
            }
        }
        return .none
    }

    private static func entries(_ data: Data, source: GitHubSource, kind: ReleaseKind) -> [Entry] {
        let suffix = kind == .ipa ? ".ipa" : ".deb"
        let releases = (try? JSONSerialization.jsonObject(with: data)) as? [Any] ?? []
        var out: [Entry] = []
        for case let release as [String: Any] in releases.prefix(AuthorReleases.maxReleases) {
            if release["draft"] as? Bool == true { continue }
            guard let tag = release["tag_name"] as? String, !tag.isEmpty else { continue }
            let pre = release["prerelease"] as? Bool == true
            for case let asset as [String: Any] in (release["assets"] as? [Any] ?? []).prefix(AuthorReleases.maxAssets) {
                guard let name = asset["name"] as? String, name.utf8.count <= 256,
                      name.lowercased().hasSuffix(suffix),
                      let size = (asset["size"] as? NSNumber).flatMap({ Int(exactly: $0.doubleValue) }), size > 0, size <= kind.maxBytes,
                      let link = asset["browser_download_url"] as? String,
                      let url = AuthorReleaseClient.assetURL(link, of: source) else { continue }
                let updated = asset["updated_at"] as? String ?? ""
                out.append((tag, pre, ReleaseAsset(name: name, url: url, size: size), updated))
            }
        }
        return out
    }
}

/// Fixed download caps: the size a release lists is attacker-controlled, so it never sets the limit.
public enum AppUpdateLimits {
    public static let maxIPABytes = 600 * 1024 * 1024
}

extension ReleaseKind {
    public var maxBytes: Int { self == .ipa ? AppUpdateLimits.maxIPABytes : DebLimits.maxDebBytes }
}
