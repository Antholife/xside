import Foundation

public enum UpdateOutcome: Sendable, Equatable {
    case upToDate(trigger: String?)
    /// `stable == false` (a prerelease) means the caller only notifies, never installs by itself.
    case available(FoundRelease, version: String, stable: Bool)
    case needsVariantChoice
    case failed(String)
}

/// Decides whether a GitHub source has a newer release than what is installed. The release list is
/// the cheap trigger; the downloaded file's own version (IPA Info.plist / deb control) is the truth.
public struct UpdateChecker: Sendable {
    /// Seam: reads the real version of a downloaded file. Tests inject a stub; the default inspects the ipa/deb.
    typealias VersionReader = @Sendable (URL, ReleaseKind) async -> String?

    let fetcher: HTTPFetching
    let runner: CommandRunning
    let workDir: URL
    let readVersion: VersionReader

    public init(fetcher: HTTPFetching, runner: CommandRunning, workDir: URL) {
        self.init(fetcher: fetcher, runner: runner, workDir: workDir,
                  readVersion: { file, kind in await Self.inspectVersion(file, kind: kind, runner: runner, workDir: workDir) })
    }

    init(fetcher: HTTPFetching, runner: CommandRunning, workDir: URL, readVersion: @escaping VersionReader) {
        self.fetcher = fetcher
        self.runner = runner
        self.workDir = workDir
        self.readVersion = readVersion
    }

    public func check(source: UpdateSource, kind: ReleaseKind, installedVersion: String?) async -> UpdateOutcome {
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
        let found: FoundRelease
        do {
            switch try ReleaseFinder.choose(data, source: source.repo, kind: kind, variant: source.variant) {
            case .ambiguous: return .needsVariantChoice
            case .none: return .upToDate(trigger: source.lastSeenTrigger)
            case .found(let f): found = f
            }
        } catch {
            return .failed("release list: \(error)")
        }
        if found.trigger == source.lastSeenTrigger { return .upToDate(trigger: found.trigger) }

        // Defence in depth: the finder already drops these.
        guard found.asset.size > 0, found.asset.size <= kind.maxBytes else { return .upToDate(trigger: found.trigger) }
        let ext = kind == .ipa ? "ipa" : "deb"
        let asset = workDir.appendingPathComponent("asset-\(UUID().uuidString).\(ext)")
        defer { try? fm.removeItem(at: asset) }
        do {
            _ = try await fetcher.fetch(found.asset.url, maxBytes: kind.maxBytes, to: asset,
                                        redirectingWithin: AuthorReleases.assetHosts)
        } catch {
            return .failed("download: \(error)")
        }
        var st = stat()
        guard lstat(asset.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, Int(st.st_size) == found.asset.size else {
            return .failed("download: not the \(found.asset.size) bytes the release lists")
        }
        guard let real = await readVersion(asset, kind) else { return .upToDate(trigger: found.trigger) }
        if Self.isNewer(real, than: installedVersion) == true {
            return .available(found, version: real, stable: !found.isPrerelease)
        }
        return .upToDate(trigger: found.trigger)
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

    private static func inspectVersion(_ file: URL, kind: ReleaseKind, runner: CommandRunning, workDir: URL) async -> String? {
        switch kind {
        case .ipa:
            return try? await IPAImporter.inspect(ipa: file, runner: runner, scratchRoot: workDir).version
        case .deb:
            guard let text = try? await DebReader.control(of: file, runner: runner) else { return nil }
            return (try? DebControl.parse(text))?.version
        }
    }
}
