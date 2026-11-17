import Foundation

public enum UpdateOutcome: Sendable, Equatable {
    case upToDate(trigger: String?)
    /// `stable == false` (a prerelease) means the caller only notifies, never installs by itself.
    case available(FoundRelease, version: String, stable: Bool)
    case needsVariantChoice
    case failed(String)
}

/// Decides whether a GitHub source has a release newer than the one the person is on, by the
/// release the repo publishes (its tag), not by the app's own version: a tweak bumped without a
/// new host-app version is still an update. Only the release list is fetched — no file download, so
/// a check is cheap. The app version is used elsewhere only to flag a downgrade at install.
public struct UpdateChecker: Sendable {
    let fetcher: HTTPFetching
    let workDir: URL

    public init(fetcher: HTTPFetching, workDir: URL) {
        self.fetcher = fetcher
        self.workDir = workDir
    }

    /// Available when the newest release matching the variant is a different tag than the one the
    /// source is on (`installedTag`). No `installedTag` yet (older data, or the baseline was never
    /// set) means we can't tell, so it reports up to date rather than a false update.
    public func check(source: UpdateSource, kind: ReleaseKind) async -> UpdateOutcome {
        let fm = FileManager.default
        do { try fm.createDirectory(at: workDir, withIntermediateDirectories: true) } catch {
            return .failed("work directory: \(error.localizedDescription)")
        }
        let listFile = workDir.appendingPathComponent("releases-\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: listFile) }
        let data: Data
        do {
            _ = try await fetcher.fetch(source.repo.api, maxBytes: AuthorReleases.maxListBytes, to: listFile,
                                        stayingOn: AuthorReleases.apiOrigin)
            data = try Data(contentsOf: listFile)
        } catch {
            return .failed("release list: \(error)")
        }
        do {
            switch try ReleaseFinder.choose(data, source: source.repo, kind: kind, variant: source.variant) {
            case .ambiguous: return .needsVariantChoice
            case .none: return .upToDate(trigger: source.lastSeenTrigger)
            case .found(let found):
                guard let installedTag = source.installedTag, !installedTag.isEmpty else {
                    return .upToDate(trigger: found.trigger)
                }
                if found.tag == installedTag { return .upToDate(trigger: found.trigger) }
                return .available(found, version: Self.displayTag(found.tag), stable: !found.isPrerelease)
            }
        } catch {
            return .failed("release list: \(error)")
        }
    }

    /// A tag shown to the person: a leading `v`/`V` dropped (`v1.1.8` → `1.1.8`).
    public static func displayTag(_ tag: String) -> String {
        if let f = tag.first, f == "v" || f == "V" { return String(tag.dropFirst()) }
        return tag
    }

    /// Kind-aware "is the release newer": `.ipa` uses the dotted-integer rule, `.deb` the dpkg rule.
    /// No installed version, or a non-comparable one, is never newer (no false updates).
    public static func isNewer(_ candidate: String, than installed: String?, kind: ReleaseKind) -> Bool {
        switch kind {
        case .ipa: return isNewer(candidate, than: installed) == true
        case .deb:
            guard let installed else { return false }
            return DebVersion.compare(candidate, installed) == .orderedDescending
        }
    }

    /// Dotted numbers only (`1.10.2`); missing parts count as 0. Anything else (`v3.0`, `1.0-beta`),
    /// or no installed version, is not comparable (nil).
    public static func isNewer(_ candidate: String, than installed: String?) -> Bool? {
        guard let installed, let a = parts(candidate), let b = parts(installed) else { return nil }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// True only when both versions are known and comparable and the installed one is strictly newer
    /// than the one about to be installed.
    public static func isDowngrade(installed: String?, candidate: String?) -> Bool {
        guard let installed, let candidate, !installed.isEmpty, !candidate.isEmpty else { return false }
        return isNewer(installed, than: candidate) == true
    }

    private static func parts(_ s: String) -> [Int]? {
        let pieces = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }
        var out: [Int] = []
        for p in pieces {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }
}
