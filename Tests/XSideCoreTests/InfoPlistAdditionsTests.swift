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
            "com.app.search", "io.github.xside.shortcut.settings",
            "io.github.xside.shortcut.refresh", "io.github.xside.shortcut.report"])
        #expect(items.dropFirst().map { $0["UIApplicationShortcutItemIconSymbolName"] as? String }
                == ["gearshape", "arrow.clockwise", "ladybug"])
    }

    /// iOS shows 4 quick actions at most: XSide fills what's left, "Réglages XSide" lasting longest.
    @Test(arguments: [(0, 3), (1, 3), (2, 2), (3, 1), (4, 0), (6, 0)])
    func onlyTheFreeSlotsAreUsed(appItems: Int, added: Int) {
        let theirs = (0..<appItems).map { ["UIApplicationShortcutItemType": "com.app.\($0)", "UIApplicationShortcutItemTitle": "T"] }
        var plist: [String: Any] = ["UIApplicationShortcutItems": theirs]
        let strings = InfoPlistAdditions.apply(to: &plist)
        let items = plist["UIApplicationShortcutItems"] as? [[String: Any]] ?? []
        let ours = items.compactMap { $0["UIApplicationShortcutItemType"] as? String }.filter { $0.hasPrefix("io.github.xside.shortcut.") }
        #expect(ours == Array(["settings", "refresh", "report"].prefix(added)).map { "io.github.xside.shortcut.\($0)" })
        #expect(items.count == appItems + added)
        #expect(strings["fr"]?.filter { $0.key.hasSuffix(".title") }.count ?? 0 == added)
    }

    @Test func shortcutTitlesAreLocalized() {
        var plist: [String: Any] = [:]
        let strings = InfoPlistAdditions.apply(to: &plist)
        let items = plist["UIApplicationShortcutItems"] as? [[String: Any]] ?? []
        let keys = items.compactMap { $0["UIApplicationShortcutItemTitle"] as? String }
        #expect(keys.count == 3)
        #expect(keys.map { strings["fr"]?[$0] } == ["Réglages XSide", "Rafraîchir maintenant", "Signaler un problème"])
        #expect(keys.map { strings["en"]?[$0] } == ["XSide Settings", "Refresh now", "Report a problem"])
    }
}

@Suite struct LocalizedStringsTests {
    @Test func createdFilesAreSeededFromTheAppsCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let base = dir.appendingPathComponent("Base.lproj")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data(#""CFBundleDisplayName" = "Demo";"#.utf8).write(to: base.appendingPathComponent("InfoPlist.strings"))
        LocalizedStrings.merge(["fr": ["k": "français"], "en": ["k": "english"]], into: dir, table: "InfoPlist")
        for (lproj, text) in [("fr.lproj", "français"), ("en.lproj", "english"), ("Base.lproj", "english")] {
            let d = try #require(try PropertyListSerialization.propertyList(
                from: Data(contentsOf: dir.appendingPathComponent("\(lproj)/InfoPlist.strings")), format: nil) as? [String: String])
            #expect(d["CFBundleDisplayName"] == "Demo")
            #expect(d["k"] == text)
        }
    }
}
