import Foundation

/// What XSide does when a newer release of an app's or tweak's GitHub source shows up.
public enum UpdateMode: String, Codable, Sendable { case notify, auto }

/// How often an app's source is checked, as the iPhone offers it: a fixed set the phone can list,
/// plus `custom` for any other `checkInterval` the Mac set (shown read-only on the phone, kept as
/// is). Rides in the synced settings (`InAppSettings.updateFrequency`); the Mac maps it to and from
/// `UpdateSource.checkInterval` (see `Library.applyCheckIn` and `setUpdateSource`).
public enum UpdateFrequency: String, Codable, Sendable {
    case global, sixHours, daily, weekly, atRefresh, never, custom

    /// The values the phone lists as an editable choice (in order); `custom` is not one of them.
    public static let choices: [UpdateFrequency] = [.global, .sixHours, .daily, .weekly, .atRefresh, .never]

    /// The frequency a stored `checkInterval` stands for (`nil` = follow the global default).
    public static func from(_ checkInterval: TimeInterval?) -> UpdateFrequency {
        guard let s = checkInterval else { return .global }
        if s == UpdateSchedule.atRefresh { return .atRefresh }
        if s <= 0 { return .never }
        switch s {
        case 21_600: return .sixHours
        case 86_400: return .daily
        case 604_800: return .weekly
        default: return .custom
        }
    }

    /// The `checkInterval` to store for this frequency; `custom` keeps `current` (the Mac's own
    /// value, which the phone can't name), so a phone that never touched it never changes it.
    public func checkInterval(current: TimeInterval?) -> TimeInterval? {
        switch self {
        case .global: nil
        case .atRefresh: UpdateSchedule.atRefresh
        case .never: 0
        case .sixHours: 21_600
        case .daily: 86_400
        case .weekly: 604_800
        case .custom: current
        }
    }
}

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
    /// The newest release tag the background pass has already announced (notify-dedup only).
    public var lastSeenTrigger: String?
    /// The release tag the person is currently on — the baseline a check compares against. A newer
    /// release in the repo = an update. Set when the source is added (the install sheet asks) and
    /// updated each time XSide installs an update.
    public var installedTag: String?
    /// The baseline release's GitHub title (e.g. « YTKACE v1.1.8 »), to show next to the tag. nil
    /// when the release had no title or it isn't known.
    public var installedName: String?
    /// The full trigger (`tag|asset|updatedAt`) of the baseline release. Lets a check catch a new
    /// build published under the SAME tag (a rolling tag like `nightly`), which the tag alone can't.
    /// `nil` until learned on the first check (or set when XSide installs an update).
    public var installedTrigger: String?
    /// How often the background pass checks this source, in seconds. `nil` = follow the global
    /// default; `<= 0` = never (manual checks only). Clamped up to `UpdateSchedule.minimumInterval`.
    public var checkInterval: TimeInterval?
    /// When the background pass last checked this source (per-source cadence).
    public var lastCheckedAt: Date?

    public init(repo: GitHubSource, variant: VariantSelector, mode: UpdateMode = .notify,
                lastSeenTrigger: String? = nil, installedTag: String? = nil, installedName: String? = nil,
                installedTrigger: String? = nil, checkInterval: TimeInterval? = nil, lastCheckedAt: Date? = nil) {
        self.repo = repo
        self.variant = variant
        self.mode = mode
        self.lastSeenTrigger = lastSeenTrigger
        self.installedTag = installedTag
        self.installedName = installedName
        self.installedTrigger = installedTrigger
        self.checkInterval = checkInterval
        self.lastCheckedAt = lastCheckedAt
    }
}
