import Foundation

/// A tweak as the iPhone lists it (read-only): written at signing into the module's payload
/// (`XSideWelcome.tweaks`) and into the app's iOS Settings page (`TweaksPane`), so the list is
/// always the one of the copy installed.
public struct PhoneTweak: Equatable, Sendable {
    public var name: String
    public var version: String?
    public var author: String?
    /// The `.deb`'s description, in its author's language.
    public var summary: String?
    public var converted: Bool
    /// In the app's list but off on this device: not in the app (« désactivé sur cet appareil »).
    public var offHere: Bool

    public init(name: String, version: String?, author: String?, summary: String?, converted: Bool, offHere: Bool) {
        self.name = name
        self.version = version
        self.author = author
        self.summary = summary
        self.converted = converted
        self.offHere = offHere
    }
}

public enum PhoneTweaks {
    /// Caps, mirrored by the module's reader (`XSTweaksSanitized`, App/Welcome/XSSettingsCore.m).
    public static let maxCount = 64
    public static let maxName = 128
    public static let maxVersion = 64
    public static let maxAuthor = 128
    /// `TweakDescription.clean` keeps 1000 characters at most already.
    public static let maxSummary = 1000

    /// What the app got: the tweaks injected (by `results`), in load order, then `offHere` (the
    /// app's tweaks off on this device). Empty when none was injected: the iPhone lists nothing.
    /// Skipped ones aren't in the app and aren't listed. At most `maxCount`, injected first.
    public static func list(items: [TweakSigningItem], results: [String: TweakResult],
                            offHere: [TweakPackage]) -> [PhoneTweak] {
        var seen = Set<String>()
        var out: [PhoneTweak] = []
        for item in items where seen.insert(item.package.id).inserted {
            guard case .injected(let converted)? = results[item.package.id] else { continue }
            out.append(entry(item.package, converted: converted, offHere: false))
        }
        guard !out.isEmpty else { return [] }
        for p in offHere where seen.insert(p.id).inserted {
            out.append(entry(p, converted: false, offHere: true))
        }
        return Array(out.prefix(maxCount))
    }

    private static func entry(_ p: TweakPackage, converted: Bool, offHere: Bool) -> PhoneTweak {
        PhoneTweak(name: capped(p.name, maxName) ?? capped(p.packageID, maxName) ?? "?",
                   version: capped(p.version, maxVersion), author: capped(p.author, maxAuthor),
                   summary: capped(p.shownSummary, maxSummary), converted: converted, offHere: offHere)
    }

    /// Trimmed, nil when blank, at most `max` characters.
    static func capped(_ s: String?, _ max: Int) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(max))
    }

    /// The payload's `tweaks`: `{name, version?, author?, summary?, converted, off}` each.
    static func plist(_ tweaks: [PhoneTweak]) -> [[String: Any]] {
        tweaks.map { t in
            var d: [String: Any] = ["name": t.name, "converted": t.converted, "off": t.offHere]
            if let v = t.version { d["version"] = v }
            if let a = t.author { d["author"] = a }
            if let s = t.summary { d["summary"] = s }
            return d
        }
    }

    /// « version · auteur », what is known of it; « — » for nothing.
    public static func versionLine(version: String?, author: String?) -> String {
        let parts = [version, author].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

/// « Tweaks · N » on the app's iOS Settings page and the page it opens: one group per tweak in the
/// app (name, « · converti » when converted, a « Version » row, the description as the footer).
/// iOS can't fold a footer: the description is cut to about `footerLimit` characters. Titles are
/// plain text in the installation's language; `strings` translates them for the other one, as
/// `SettingsSection.plainText(in:)` does.
public struct TweaksPane: Equatable, Sendable {
    public struct Group: Equatable, Sendable {
        public var title: String
        public var version: String
        public var footer: String?
    }

    public let rowTitle: String
    public let title: String
    public let groups: [Group]
    public let strings: [String: [String: String]]

    static let footerLimit = 300

    /// nil when no tweak is in the app (those off on this device aren't listed here).
    public static func make(_ tweaks: [PhoneTweak], language: String) -> TweaksPane? {
        let shown = tweaks.filter { !$0.offHere }
        guard !shown.isEmpty else { return nil }
        let suffix = ["fr": " · converti", "en": " · converted"]
        let lang = language == "fr" ? "fr" : "en"
        var strings: [String: [String: String]] = [:]
        let groups = shown.map { t -> Group in
            var title = t.name
            if t.converted {
                title = t.name + suffix[lang]!
                for (l, s) in suffix { strings[l, default: [:]][title] = t.name + s }
            }
            return Group(title: title, version: PhoneTweaks.versionLine(version: t.version, author: t.author),
                         footer: t.summary.map(cut))
        }
        return TweaksPane(rowTitle: "Tweaks · \(shown.count)", title: "Tweaks", groups: groups, strings: strings)
    }

    static func cut(_ text: String) -> String {
        guard text.count > footerLimit else { return text }
        let head = String(text.prefix(footerLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return head + "…"
    }
}
