import Foundation

/// What XSide adds to an app's Info.plist at signing, besides the `XSideWelcome` payload: the
/// Bonjour service the dylib browses to find XSide on the Mac, the reason iOS shows for the
/// local-network permission, and XSide's quick actions as static items. Static items show from
/// the install and go away with the module (the Info.plist is rewritten at each signing). Their
/// cost, accepted by the maintainer (device feedback 3, E1, reversing final review Important 1):
/// iOS lists static items before dynamic ones, so an app whose own quick actions are dynamic
/// shows fewer of them.
public enum InfoPlistAdditions {
    public static let bonjourService = "_xside._tcp"
    public static let shortcutTypePrefix = "io.github.xside.shortcut."
    public static let usageKey = "NSLocalNetworkUsageDescription"

    /// One quick action: `type` is `io.github.xside.shortcut.<name>`, what the dylib matches on.
    public struct Shortcut: Sendable, Equatable {
        public let name: String
        public let symbol: String
        public var type: String { shortcutTypePrefix + name }
    }

    /// In priority order: iOS shows 4 quick actions at most, and "Réglages XSide" is the one to keep.
    public static let shortcuts = [Shortcut(name: "settings", symbol: "gearshape"),
                                   Shortcut(name: "refresh", symbol: "arrow.clockwise"),
                                   Shortcut(name: "report", symbol: "ladybug")]
    static let maxShortcuts = 4

    /// Texts by language ("fr", "en"): the usage reason and the quick action titles (by name).
    public struct Texts: Sendable, Equatable {
        public var usage: [String: String]
        public var shortcutTitles: [String: [String: String]]

        public init(usage: [String: String], shortcutTitles: [String: [String: String]] = [:]) {
            self.usage = usage
            self.shortcutTitles = shortcutTitles
        }

        public static let standard = Texts(
            usage: ["fr": "XSide demande à ton Mac de rafraîchir cette app.",
                    "en": "XSide asks your Mac to refresh this app."],
            shortcutTitles: [
                "fr": ["settings": "Réglages XSide", "refresh": "Rafraîchir maintenant", "report": "Signaler un problème"],
                "en": ["settings": "XSide Settings", "refresh": "Refresh now", "report": "Report a problem"]])
    }

    /// Merges the additions into `plist`, keeping what the app declares: its Bonjour services, its
    /// own usage text (only set when absent) and its static quick actions (XSide's come after, as
    /// many as fit in iOS's 4, replacing those of an earlier signing). Plain values are in
    /// `language` ("fr" or "en"): they show as they are when the app has no localization of its
    /// own, since XSide adds none (final review Important 2). Returns the `InfoPlist.strings`
    /// entries for the app's existing lprojs (language -> key -> text), keyed by those plain
    /// values, which is how iOS looks the titles up.
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

        var items = appItems(plist)
        // Only the free slots (the app's own static items come first and keep theirs).
        let added = shortcuts.prefix(max(0, maxShortcuts - items.count))
        let plainTitles = texts.shortcutTitles[language] ?? texts.shortcutTitles["en"] ?? [:]
        for shortcut in added {
            let title = plainTitles[shortcut.name] ?? shortcut.name
            items.append(["UIApplicationShortcutItemType": shortcut.type,
                          "UIApplicationShortcutItemTitle": title,
                          "UIApplicationShortcutItemIconSymbolName": shortcut.symbol])
            for (other, titles) in texts.shortcutTitles {
                if let text = titles[shortcut.name] { strings[other, default: [:]][title] = text }
            }
        }
        if !items.isEmpty || plist["UIApplicationShortcutItems"] != nil { plist["UIApplicationShortcutItems"] = items }
        return strings
    }

    /// Takes XSide's quick actions of an earlier signing out (an app going without XSide features
    /// keeps only its own).
    public static func removeShortcuts(from plist: inout [String: Any]) {
        guard plist["UIApplicationShortcutItems"] != nil else { return }
        let items = appItems(plist)
        plist["UIApplicationShortcutItems"] = items.isEmpty ? nil : items
    }

    /// The app's own static items, XSide's left out.
    private static func appItems(_ plist: [String: Any]) -> [[String: Any]] {
        (plist["UIApplicationShortcutItems"] as? [[String: Any]] ?? []).filter {
            ($0["UIApplicationShortcutItemType"] as? String)?.hasPrefix(shortcutTypePrefix) != true
        }
    }
}
