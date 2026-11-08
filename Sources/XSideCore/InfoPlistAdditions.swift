import Foundation

/// What XSide adds to an app's Info.plist at signing, besides the `XSideWelcome` payload: the
/// Bonjour service the dylib browses to find XSide on the Mac and the reason iOS shows for the
/// local-network permission. XSide's quick actions are not here: the dylib adds them as dynamic
/// items, only in the slots the app's own static and dynamic items leave (final review
/// Important 1: static ones pushed the app's dynamic items out), so the Info.plist loses those of
/// an earlier signing.
public enum InfoPlistAdditions {
    public static let bonjourService = "_xside._tcp"
    public static let shortcutTypePrefix = "io.github.xside.shortcut."
    public static let usageKey = "NSLocalNetworkUsageDescription"

    /// Texts by language ("fr", "en"): the usage reason.
    public struct Texts: Sendable, Equatable {
        public var usage: [String: String]

        public init(usage: [String: String]) {
            self.usage = usage
        }

        public static let standard = Texts(
            usage: ["fr": "XSide demande à ton Mac de rafraîchir cette app.",
                    "en": "XSide asks your Mac to refresh this app."])
    }

    /// Merges the additions into `plist`, keeping what the app declares: its Bonjour services, its
    /// own usage text (only set when absent) and its static quick actions (XSide's of an earlier
    /// signing removed). The plain usage value is in `language` ("fr" or "en"): it is what shows
    /// when the app has no localization of its own, since XSide adds none (final review
    /// Important 2). Returns the `InfoPlist.strings` entries for the app's existing lprojs
    /// (language -> key -> text).
    @discardableResult
    public static func apply(to plist: inout [String: Any], texts: Texts = .standard,
                             language: String = "en") -> [String: [String: String]] {
        var strings: [String: [String: String]] = [:]

        var services = (plist["NSBonjourServices"] as? [Any])?.compactMap { $0 as? String } ?? []
        if !services.contains(where: { $0.lowercased() == bonjourService }) { services.append(bonjourService) }
        plist["NSBonjourServices"] = services

        if plist[usageKey] == nil {
            plist[usageKey] = texts.usage[language] ?? texts.usage["en"] ?? texts.usage.values.first ?? ""
            for (language, text) in texts.usage { strings[language, default: [:]][usageKey] = text }
        }

        if let items = plist["UIApplicationShortcutItems"] as? [[String: Any]] {
            let own = items.filter {
                ($0["UIApplicationShortcutItemType"] as? String)?.hasPrefix(shortcutTypePrefix) != true
            }
            if own.count != items.count { plist["UIApplicationShortcutItems"] = own }
        }
        return strings
    }
}
