import Foundation

/// The decisions behind applying an app update from GitHub, kept pure so they can be tested.
public enum UpdateApply {
    /// Auto-install only a stable release whose content check ran and shows no warning sign.
    /// A missing check (`nil`) or a prerelease is never automatic.
    public static func autoAllowed(content: IPAContent?, stable: Bool) -> Bool {
        guard stable, let content else { return false }
        return content.additions.flatMap(\.signs).isEmpty
    }

    /// The downloaded app must be the one already installed: same bundle id, exactly.
    public static func bundleIDMatches(_ infoBundleID: String, originalBundleID: String) -> Bool {
        infoBundleID == originalBundleID
    }

    /// Fetches a release asset with the kind's fixed size cap (not the size the release claims),
    /// then checks it is a regular file of exactly the listed size.
    public static func downloadAsset(_ asset: ReleaseAsset, kind: ReleaseKind, to file: URL,
                                     fetcher: HTTPFetching) async throws {
        guard asset.size > 0, asset.size <= kind.maxBytes else { throw RepoError.tooLarge }
        do {
            _ = try await fetcher.fetch(asset.url, maxBytes: kind.maxBytes, to: file,
                                        redirectingWithin: AuthorReleases.assetHosts)
        } catch { try? FileManager.default.removeItem(at: file); throw error }
        var st = stat()
        guard lstat(file.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, Int(st.st_size) == asset.size else {
            try? FileManager.default.removeItem(at: file)
            throw RepoError.tooLarge
        }
    }
}
