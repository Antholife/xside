import Foundation
import CryptoKit

/// What a trusted repo has for a missing dependency: shown to the person before anything is
/// downloaded (what, from where, how big).
public struct RepoOffer: Equatable, Sendable {
    public let repo: TrustedRepo
    public let packageID: String
    public let name: String
    public let version: String
    public let architecture: String
    public let url: URL
    public let size: Int
    public let sha256: String
}

/// Looks up and downloads a dependency from `TrustedRepos` only. Trust is HTTPS + the allowlist +
/// the hash chain: `Release` (on the repo's host) lists the index's SHA256 or SHA512 and size, the
/// index lists the .deb's SHA256 and size. Nothing is executed or extracted here; it never touches
/// the library (the caller stores the verified file).
public struct RepoClient: Sendable {
    public static let maxReleaseBytes = 1024 * 1024
    public static let maxIndexBytes = 32 * 1024 * 1024
    public static let maxIndexDecompressedBytes = 128 * 1024 * 1024
    public static let maxIndexStanzas = 100_000
    /// Most wanted first. gzip comes late: a multi-member .gz is refused by `StreamDecompressor`.
    static let indexNames = ["Packages.xz", "Packages.zst", "Packages", "Packages.gz", "Packages.bz2"]
    static let fallbackArchitectures = ["iphoneos-arm64", "iphoneos-arm"]
    static let refusedArchitecture = "iphoneos-arm64e"

    private let fetcher: HTTPFetching
    private let runner: CommandRunning
    private let workDir: URL
    private let log = Log("repo")

    public init(fetcher: HTTPFetching, runner: CommandRunning, workDir: URL) {
        self.fetcher = fetcher
        self.runner = runner
        self.workDir = workDir
    }

    /// The same fetcher, runner and work folder, for the pinned authors' GitHub releases.
    var authorReleases: AuthorReleaseClient { AuthorReleaseClient(fetcher: fetcher, runner: runner, workDir: workDir) }

    // MARK: - Offer

    public func offer(for dependency: DebDependency, preferredArchitecture: String?) async throws -> RepoOffer {
        let id = dependency.package.lowercased()
        let repos = TrustedRepos.offering(id)
        guard !repos.isEmpty else {
            log.notice("\(id): not offered by any trusted repo")
            throw RepoError.notAllowlisted
        }
        let order = Self.architectureOrder(preferredArchitecture)
        var best: (offer: RepoOffer, rank: Int)?
        var firstError: Error?
        for repo in repos {
            do {
                let found = try await offer(id, dependency, in: repo, order: order)
                if best == nil || Self.isBetter(found, than: best!) { best = found }
            } catch {
                if error is CancellationError { throw error }
                log.error("\(repo.id): \(id): \(error)")
                if firstError == nil { firstError = error }
            }
        }
        guard let best else { throw firstError ?? RepoError.notFound(id) }
        log.notice("\(id): offering \(best.offer.packageID) \(best.offer.version) \(best.offer.architecture) from \(best.offer.repo.id), \(best.offer.size) bytes")
        return best.offer
    }

    /// The tweak's own architecture, then arm64, then arm; never arm64e.
    static func architectureOrder(_ preferred: String?) -> [String] {
        var order: [String] = []
        for a in [preferred?.lowercased()].compactMap({ $0 }) + fallbackArchitectures
        where a != refusedArchitecture && !a.isEmpty && !order.contains(a) { order.append(a) }
        return order
    }

    private static func isBetter(_ a: (offer: RepoOffer, rank: Int), than b: (offer: RepoOffer, rank: Int)) -> Bool {
        if a.rank != b.rank { return a.rank < b.rank }
        return DebVersion.compare(a.offer.version, b.offer.version) == .orderedDescending
    }

    private func offer(_ id: String, _ dependency: DebDependency, in repo: TrustedRepo,
                       order: [String]) async throws -> (offer: RepoOffer, rank: Int) {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let scratch = workDir.appendingPathComponent(".repo-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }

        guard let folder = repo.indexPath.isEmpty ? repo.base : URL(string: repo.indexPath, relativeTo: repo.base)?.absoluteURL,
              Self.isUnder(folder, repo.base) else { throw RepoError.notAllowlisted }
        // Release: on the repo's host, HTTPS (no signature check: see TrustedRepos).
        guard let releaseURL = URL(string: "Release", relativeTo: folder)?.absoluteURL else { throw RepoError.noIndex }
        let releaseFile = scratch.appendingPathComponent("Release")
        try await fetchOnHost(releaseURL, of: repo, maxBytes: Self.maxReleaseBytes, to: releaseFile)
        let release = String(decoding: try Data(contentsOf: releaseFile), as: UTF8.self)
        let listed = Self.pickIndexes(release)
        guard !listed.isEmpty else {
            log.error("\(repo.id): Release lists no Packages index with a SHA256 or SHA512 hash")
            throw RepoError.noIndex
        }

        // The index: checked against Release before anything reads it. A listed name the server
        // doesn't have (404) falls back to the next one.
        // One over the cap is skipped too: tooLarge only when nothing else could be fetched.
        var fetched: (entry: IndexEntry, file: URL)?
        var skippedTooLarge = false
        for (i, candidate) in listed.enumerated() {
            guard candidate.size <= Self.maxIndexBytes else {
                log.notice("\(repo.id): \(candidate.name) is \(candidate.size) bytes, over the cap, trying the next index")
                skippedTooLarge = true
                continue
            }
            guard let indexURL = URL(string: candidate.name, relativeTo: folder)?.absoluteURL else { throw RepoError.noIndex }
            let file = scratch.appendingPathComponent("index-" + candidate.name)
            do {
                try await fetchOnHost(indexURL, of: repo, maxBytes: candidate.size, to: file)
                fetched = (candidate, file)
                break
            } catch RepoError.httpStatus(404) where i < listed.count - 1 {
                log.notice("\(repo.id): \(candidate.name) listed but missing (404), trying the next index")
            }
        }
        guard let (entry, indexFile) = fetched else { throw skippedTooLarge ? RepoError.tooLarge : RepoError.noIndex }
        let got = try Self.fileSize(indexFile)
        guard got == entry.size, try Self.hexDigest(of: indexFile, sha512: entry.sha512) == entry.hash else {
            log.error("\(repo.id): \(entry.name) hash check failed (\(got) bytes, Release says \(entry.size))")
            throw RepoError.indexHashMismatch
        }
        log.info("\(repo.id): \(entry.name) hash ok (\(entry.sha512 ? "SHA512" : "SHA256"), \(got) bytes)")

        let plain = scratch.appendingPathComponent("Packages-plain")
        do {
            try await StreamDecompressor.decompress(indexFile, kind: Self.compression(of: entry.name), to: plain,
                                                    maxBytes: UInt64(Self.maxIndexDecompressedBytes), runner: runner)
        } catch let e as DebError {
            throw e == .tooLarge ? RepoError.tooLarge : RepoError.noIndex
        }
        let stanzas: [[String: String]]
        do {
            stanzas = try DebControl.stanzas(String(decoding: try Data(contentsOf: plain), as: UTF8.self),
                                             maxStanzas: Self.maxIndexStanzas)
        } catch let e as DebError {
            throw e == .tooLarge ? RepoError.tooLarge : RepoError.noIndex
        }
        return try Self.choose(id, dependency, from: stanzas, repo: repo, order: order)
    }

    /// Release and the index stay on the allowlisted host, even through redirects.
    private func fetchOnHost(_ url: URL, of repo: TrustedRepo, maxBytes: Int, to file: URL) async throws {
        let final = try await fetcher.fetch(url, maxBytes: maxBytes, to: file, stayingOn: repo.base)
        guard Self.isUnder(final, repo.base) else {
            try? FileManager.default.removeItem(at: file)
            log.error("\(repo.id): \(RepoLog.display(url)) ended on \(RepoLog.display(final)), off the trusted host")
            throw RepoError.notAllowlisted
        }
    }

    struct IndexEntry: Equatable {
        let name: String
        let hash: String
        let size: Int
        let sha512: Bool
    }

    /// The `indexNames` that Release lists with a SHA256 (else SHA512) hash, most wanted first.
    /// MD5 and SHA1 are never used. An unreadable Release lists nothing.
    static func pickIndexes(_ release: String) -> [IndexEntry] {
        guard let fields = (try? DebControl.stanzas(release, maxStanzas: 8))?.first else { return [] }
        func entries(_ key: String, hexLength: Int) -> [String: (hash: String, size: Int)] {
            var out: [String: (String, Int)] = [:]
            for line in (fields[key] ?? "").split(separator: "\n") {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count == 3, let size = Int(parts[1]), size >= 0 else { continue }
                let hash = parts[0].lowercased()
                guard hash.utf8.count == hexLength, hash.utf8.allSatisfy(isHex) else { continue }
                let name = String(parts[2])
                if out[name] == nil { out[name] = (hash, size) }
            }
            return out
        }
        let sha256 = entries("sha256", hexLength: 64), sha512 = entries("sha512", hexLength: 128)
        return indexNames.compactMap { name in
            if let e = sha256[name] { return IndexEntry(name: name, hash: e.hash, size: e.size, sha512: false) }
            if let e = sha512[name] { return IndexEntry(name: name, hash: e.hash, size: e.size, sha512: true) }
            return nil
        }
    }

    static func compression(of name: String) -> CompressionKind {
        switch (name as NSString).pathExtension {
        case "xz": return .xz
        case "zst": return .zstd
        case "gz": return .gzip
        case "bz2": return .bzip2
        default: return .none
        }
    }

    /// Among the stanzas whose `Package` is exactly `id`, an id the repo is trusted for, whose
    /// `Version` satisfies the dependency and that carry a SHA256 and a size: the best architecture,
    /// then the highest version. `Provides` is never used: on a multi-vendor repo any seller could
    /// claim to provide an allowlisted id.
    static func choose(_ id: String, _ dependency: DebDependency, from stanzas: [[String: String]], repo: TrustedRepo,
                       order: [String]) throws -> (offer: RepoOffer, rank: Int) {
        var matched = false
        var best: (stanza: [String: String], package: String, version: String, arch: String, sha: String, size: Int, rank: Int)?
        for s in stanzas {
            guard let package = s["package"]?.lowercased(), DebControl.isValidPackageID(package) else { continue }
            guard package == id, repo.packages.contains(package) else { continue }
            matched = true
            guard let version = s["version"], !version.isEmpty, dependency.isSatisfied(by: version) else { continue }
            guard let arch = s["architecture"]?.lowercased(), let rank = order.firstIndex(of: arch) else { continue }
            guard let sha = s["sha256"]?.lowercased(), sha.utf8.count == 64, sha.utf8.allSatisfy(isHex) else { continue }
            guard let sizeText = s["size"], let size = Int(sizeText), size > 0 else { continue }
            if let b = best {
                if rank > b.rank { continue }
                if rank == b.rank, DebVersion.compare(version, b.version) != .orderedDescending { continue }
            }
            best = (s, package, version, arch, sha, size, rank)
        }
        guard let best else { throw matched ? RepoError.noVersionSatisfying(id) : RepoError.notFound(id) }
        guard best.size <= DebLimits.maxDebBytes else { throw RepoError.tooLarge }
        guard let url = resolve(best.stanza["filename"] ?? "", under: repo.base) else { throw RepoError.badFilename }
        let name = best.stanza["name"].flatMap { $0.isEmpty ? nil : String($0.prefix(256)) } ?? best.package
        let offer = RepoOffer(repo: repo, packageID: best.package, name: name, version: best.version,
                              architecture: best.arch, url: url, size: best.size, sha256: best.sha)
        return (offer, best.rank)
    }

    /// A `Filename` is a plain relative path under `base`: no scheme, no leading "/", no "..", no
    /// empty segment, no query or fragment, nothing percent-encoded that decodes to one of those.
    /// "./" segments are fine.
    static func resolve(_ filename: String, under base: URL) -> URL? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~+/%=,@".utf8)
        guard !filename.isEmpty, filename.utf8.count <= DebLimits.maxPathBytes,
              filename.utf8.allSatisfy(allowed.contains), !filename.hasPrefix("/") else { return nil }
        guard let decoded = filename.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == "\\" || $0 == ":" || $0 == "?" || $0 == "#" })
        else { return nil }
        for path in [filename, decoded] {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == ".." }),
                  parts.last != "." else { return nil }
        }
        guard let url = URL(string: filename, relativeTo: base)?.absoluteURL.standardized,
              url.query == nil, url.fragment == nil, isUnder(url, base) else { return nil }
        return url
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool { RedirectPolicy.sameOrigin(a, b) }

    static func isUnder(_ url: URL, _ base: URL) -> Bool {
        sameOrigin(url, base) && url.absoluteString.hasPrefix(base.absoluteString)
    }

    // MARK: - Download

    /// The .deb, checked against the index's size and SHA256, as a file in `workDir`. It may come
    /// through redirects to another HTTPS host: the hash is what's trusted. On any failure nothing
    /// is left behind.
    public func download(_ offer: RepoOffer) async throws -> URL {
        guard TrustedRepos.all.contains(offer.repo), offer.repo.packages.contains(offer.packageID),
              Self.isUnder(offer.url, offer.repo.base) else {
            log.error("download refused, not a trusted repo and package: \(offer.packageID) \(RepoLog.display(offer.url))")
            throw RepoError.notAllowlisted
        }
        guard offer.size > 0, offer.size <= DebLimits.maxDebBytes else { throw RepoError.tooLarge }
        let expected = offer.sha256.lowercased()
        guard expected.utf8.count == 64, expected.utf8.allSatisfy(Self.isHex) else { throw RepoError.hashMismatch }

        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let dest = workDir.appendingPathComponent(
            "\(Self.safe(offer.packageID))_\(Self.safe(offer.version))_\(Self.safe(offer.architecture)).deb")
        let partial = workDir.appendingPathComponent(".\(UUID().uuidString).partial")
        do {
            let final = try await fetcher.fetch(offer.url, maxBytes: offer.size, to: partial)
            let got = try Self.fileSize(partial)
            guard got == offer.size else {
                log.error("\(RepoLog.display(offer.url)): \(got) bytes, the index says \(offer.size)")
                throw RepoError.sizeMismatch
            }
            guard try Self.hexDigest(of: partial, sha512: false) == expected else {
                log.error("\(RepoLog.display(offer.url)): SHA256 check failed")
                throw RepoError.hashMismatch
            }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: partial, to: dest)
            log.notice("downloaded \(offer.packageID) \(offer.version) from \(RepoLog.display(final)): \(got) bytes, SHA256 ok")
            return dest
        } catch {
            try? fm.removeItem(at: partial)
            log.error("download of \(RepoLog.display(offer.url)) failed: \(error)")
            throw error
        }
    }

    // MARK: - Helpers

    private static func isHex(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 97 && c <= 102) }

    private static func safe(_ s: String) -> String {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+~-".utf8)
        let mapped = String(decoding: s.utf8.prefix(128).map { ok.contains($0) ? $0 : UInt8(ascii: "_") }, as: UTF8.self)
        return mapped.hasPrefix(".") || mapped.isEmpty ? "_" + mapped : mapped
    }

    private static func fileSize(_ url: URL) throws -> Int {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw RepoError.sizeMismatch }
        return Int(st.st_size)
    }

    static func hexDigest(of url: URL, sha512: Bool) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var a = SHA256(), b = SHA512()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if sha512 { b.update(data: chunk) } else { a.update(data: chunk) }
        }
        let digest: [UInt8] = sha512 ? Array(b.finalize()) : Array(a.finalize())
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
