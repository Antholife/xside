import Foundation

/// What XSide adds to an app's Info.plist at signing, besides the `XSideWelcome` payload: the
/// Bonjour service the dylib browses to find XSide on the Mac, the reason iOS shows for the
/// local-network permission, and the three quick actions on the icon.
public enum InfoPlistAdditions {
    public static let bonjourService = "_xside._tcp"
    public static let shortcutTypePrefix = "io.github.xside.shortcut."
    public static let usageKey = "NSLocalNetworkUsageDescription"

    /// One quick action: `type` is `io.github.xside.shortcut.<name>`, what the dylib matches on.
    public struct Shortcut: Sendable, Equatable {
        public let name: String
        public let symbol: String
        public var type: String { shortcutTypePrefix + name }
        /// Key of the title in `InfoPlist.strings`.
        public var titleKey: String { type + ".title" }
    }

    public static let shortcuts = [Shortcut(name: "refresh", symbol: "arrow.clockwise"),
                                   Shortcut(name: "settings", symbol: "gearshape"),
                                   Shortcut(name: "report", symbol: "ladybug")]

    /// Texts by language ("fr", "en"): the usage reason and the quick action titles (by title key).
    public struct Texts: Sendable, Equatable {
        public var usage: [String: String]
        public var shortcutTitles: [String: [String: String]]

        public init(usage: [String: String], shortcutTitles: [String: [String: String]]) {
            self.usage = usage
            self.shortcutTitles = shortcutTitles
        }

        public static let standard = Texts(
            usage: ["fr": "XSide demande à ton Mac de rafraîchir cette app.",
                    "en": "XSide asks your Mac to refresh this app."],
            shortcutTitles: [
                "fr": ["io.github.xside.shortcut.refresh.title": "Rafraîchir maintenant",
                       "io.github.xside.shortcut.settings.title": "Réglages XSide",
                       "io.github.xside.shortcut.report.title": "Signaler un problème"],
                "en": ["io.github.xside.shortcut.refresh.title": "Refresh now",
                       "io.github.xside.shortcut.settings.title": "XSide Settings",
                       "io.github.xside.shortcut.report.title": "Report a problem"]])
    }

    /// Merges the additions into `plist`, keeping what the app declares: its Bonjour services, its
    /// own usage text (only set when absent) and its static quick actions (XSide's come after,
    /// replacing those of an earlier signing). Returns the `InfoPlist.strings` entries to write
    /// (language -> key -> text) for the titles and the usage text XSide set.
    @discardableResult
    public static func apply(to plist: inout [String: Any], texts: Texts = .standard) -> [String: [String: String]] {
        var strings: [String: [String: String]] = [:]

        var services = (plist["NSBonjourServices"] as? [Any])?.compactMap { $0 as? String } ?? []
        if !services.contains(where: { $0.lowercased() == bonjourService }) { services.append(bonjourService) }
        plist["NSBonjourServices"] = services

        if plist[usageKey] == nil {
            // The plain value is the English fallback; each language's text comes from InfoPlist.strings.
            plist[usageKey] = texts.usage["en"] ?? texts.usage.values.first ?? ""
            for (language, text) in texts.usage { strings[language, default: [:]][usageKey] = text }
        }

        var items = (plist["UIApplicationShortcutItems"] as? [[String: Any]] ?? []).filter {
            ($0["UIApplicationShortcutItemType"] as? String)?.hasPrefix(shortcutTypePrefix) != true
        }
        for shortcut in shortcuts {
            items.append(["UIApplicationShortcutItemType": shortcut.type,
                          "UIApplicationShortcutItemTitle": shortcut.titleKey,
                          "UIApplicationShortcutItemIconSymbolName": shortcut.symbol])
        }
        plist["UIApplicationShortcutItems"] = items
        for (language, titles) in texts.shortcutTitles {
            for (key, text) in titles { strings[language, default: [:]][key] = text }
        }
        return strings
    }
}
