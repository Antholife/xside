import Foundation

/// What XSide does when a newer release of an app's or tweak's GitHub source shows up.
public enum UpdateMode: String, Codable, Sendable { case notify, auto }

/// Re-picks the same release asset across releases whose names embed version numbers
/// (`YTKACE_1.1.8_YouTube_21.46.3.ipa` then `YTKACE_1.1.9_YouTube_21.47.0.ipa`): the name tokens
/// that stay (`stableTokens`) must all be there, and the other variant's (`excludedTokens`) none.
public struct VariantSelector: Codable, Equatable, Sendable {
    public let stableTokens: [String]
    public let excludedTokens: [String]

    public init(stableTokens: [String], excludedTokens: [String]) {
        self.stableTokens = stableTokens
        self.excludedTokens = excludedTokens
    }

    /// The name without its extension, split on `_ . - ` and whitespace, lowercased, with the
    /// version-like tokens (`118`, `v3`) dropped; alphanumeric ones (`ios16`, `arm64`) are kept.
    public static func tokens(_ name: String) -> Set<String> {
        var base = name
        if let dot = base.lastIndex(of: "."), base.distance(from: dot, to: base.endIndex) <= 6,
           base.index(after: dot) < base.endIndex, !base[base.index(after: dot)...].allSatisfy(\.isNumber) {
            base = String(base[..<dot])
        }
        let separators = CharacterSet(charactersIn: "_.-").union(.whitespacesAndNewlines)
        let parts = base.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
        return Set(parts.filter { !isVersionLike($0) })
    }

    private static func isVersionLike(_ t: String) -> Bool {
        if t.allSatisfy(\.isNumber) { return true }
        if t.hasPrefix("v"), t.count > 1, t.dropFirst().allSatisfy(\.isNumber) { return true }
        return false
    }

    public static func make(chosen: String, others: [String]) -> VariantSelector {
        let mine = tokens(chosen)
        let theirs = others.reduce(into: Set<String>()) { $0.formUnion(tokens($1)) }
        return VariantSelector(stableTokens: mine.sorted(), excludedTokens: theirs.subtracting(mine).sorted())
    }

    public func matches(_ assetName: String) -> Bool {
        // No stable token: nothing identifies the variant, so never a confident match.
        guard !stableTokens.isEmpty else { return false }
        let t = Self.tokens(assetName)
        return t.isSuperset(of: stableTokens) && t.isDisjoint(with: excludedTokens)
    }
}

/// Where an app (or tweak) is updated from: a GitHub repo, which of its assets, and what to do.
public struct UpdateSource: Codable, Equatable, Sendable {
    public let repo: GitHubSource
    public var variant: VariantSelector
    public var mode: UpdateMode
    /// The last release tag acted on or already notified about.
    public var lastSeenTrigger: String?
    /// The version of the release `lastSeenTrigger` points to, when that release was a newer one
    /// (so a manual check can report it as available again without re-downloading the file). `nil`
    /// means the last-seen release was not an update (up to date) or hasn't been read yet.
    public var lastSeenVersion: String?
    /// How often the background pass checks this source, in seconds. `nil` = follow the global
    /// default; `<= 0` = never (manual checks only). Clamped up to `UpdateSchedule.minimumInterval`.
    public var checkInterval: TimeInterval?
    /// When the background pass last checked this source (per-source cadence).
    public var lastCheckedAt: Date?

    public init(repo: GitHubSource, variant: VariantSelector, mode: UpdateMode = .notify,
                lastSeenTrigger: String? = nil, lastSeenVersion: String? = nil,
                checkInterval: TimeInterval? = nil, lastCheckedAt: Date? = nil) {
        self.repo = repo
        self.variant = variant
        self.mode = mode
        self.lastSeenTrigger = lastSeenTrigger
        self.lastSeenVersion = lastSeenVersion
        self.checkInterval = checkInterval
        self.lastCheckedAt = lastCheckedAt
    }
}
