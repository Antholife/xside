import Testing
import Foundation
@testable import XSideCore

@Suite struct InfoPlistAdditionsTests {
    @Test func bonjourAndUsageAreAddedKeepingTheAppsOwn() {
        var plist: [String: Any] = ["NSBonjourServices": ["_other._tcp"]]
        let strings = InfoPlistAdditions.apply(to: &plist)
        #expect(plist["NSBonjourServices"] as? [String] == ["_other._tcp", "_xside._tcp"])
        #expect(plist["NSLocalNetworkUsageDescription"] as? String == "XSide asks your Mac to refresh this app.")
        #expect(strings["fr"]?["NSLocalNetworkUsageDescription"] == "XSide demande à ton Mac de rafraîchir cette app.")

        // Idempotent on a re-sign; the app's own reason is left as it is.
        var own: [String: Any] = ["NSBonjourServices": ["_xside._tcp"], "NSLocalNetworkUsageDescription": "Pour le jeu."]
        let again = InfoPlistAdditions.apply(to: &own)
        #expect(own["NSBonjourServices"] as? [String] == ["_xside._tcp"])
        #expect(own["NSLocalNetworkUsageDescription"] as? String == "Pour le jeu.")
        #expect(again["fr"]?["NSLocalNetworkUsageDescription"] == nil)
    }

    @Test func shortcutItemsAreAddedKeepingTheAppsOwn() {
        let theirs: [String: Any] = ["UIApplicationShortcutItemType": "com.app.search", "UIApplicationShortcutItemTitle": "Search"]
        var plist: [String: Any] = ["UIApplicationShortcutItems": [theirs]]
        InfoPlistAdditions.apply(to: &plist)
        InfoPlistAdditions.apply(to: &plist) // a re-sign doesn't duplicate
        let items = plist["UIApplicationShortcutItems"] as? [[String: Any]] ?? []
        #expect(items.map { $0["UIApplicationShortcutItemType"] as? String } == [
            "com.app.search", "io.github.xside.shortcut.refresh",
            "io.github.xside.shortcut.settings", "io.github.xside.shortcut.report"])
        #expect(items.dropFirst().map { $0["UIApplicationShortcutItemIconSymbolName"] as? String }
                == ["arrow.clockwise", "gearshape", "ladybug"])
    }

    @Test func shortcutTitlesAreLocalized() {
        var plist: [String: Any] = [:]
        let strings = InfoPlistAdditions.apply(to: &plist)
        let items = plist["UIApplicationShortcutItems"] as? [[String: Any]] ?? []
        let keys = items.compactMap { $0["UIApplicationShortcutItemTitle"] as? String }
        #expect(keys.count == 3)
        #expect(keys.map { strings["fr"]?[$0] } == ["Rafraîchir maintenant", "Réglages XSide", "Signaler un problème"])
        #expect(keys.map { strings["en"]?[$0] } == ["Refresh now", "XSide Settings", "Report a problem"])
    }
}
