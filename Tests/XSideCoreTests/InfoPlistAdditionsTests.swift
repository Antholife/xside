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

    /// Device feedback 3, E1 (Anthony's ruling, reverses final review Important 1): XSide's quick
    /// actions are static Info.plist items again, so they show from the install, after the app's
    /// own static ones and only in the slots those leave. A re-sign replaces those of an earlier
    /// signing instead of doubling them.
    @Test func shortcutItemsAreAddedKeepingTheAppsOwn() {
        let theirs: [String: Any] = ["UIApplicationShortcutItemType": "com.app.search", "UIApplicationShortcutItemTitle": "Search"]
        let earlier: [String: Any] = ["UIApplicationShortcutItemType": "io.github.xside.shortcut.settings",
                                      "UIApplicationShortcutItemTitle": "io.github.xside.shortcut.settings.title"]
        var plist: [String: Any] = ["UIApplicationShortcutItems": [theirs, earlier]]
        InfoPlistAdditions.apply(to: &plist)
        InfoPlistAdditions.apply(to: &plist) // a re-sign doesn't duplicate
        let items = plist["UIApplicationShortcutItems"] as? [[String: Any]] ?? []
        #expect(items.map { $0["UIApplicationShortcutItemType"] as? String } == [
            "com.app.search", "io.github.xside.shortcut.settings",
            "io.github.xside.shortcut.refresh", "io.github.xside.shortcut.report"])
        #expect(items.dropFirst().map { $0["UIApplicationShortcutItemIconSymbolName"] as? String }
                == ["gearshape", "arrow.clockwise", "ladybug"])
    }

    /// iOS shows 4 quick actions at most: XSide fills what the app's static items leave,
    /// "Réglages XSide" lasting longest.
    @Test(arguments: [(0, 3), (1, 3), (2, 2), (3, 1), (4, 0), (6, 0)])
    func onlyTheFreeSlotsAreUsed(appItems: Int, added: Int) {
        let theirs = (0..<appItems).map { ["UIApplicationShortcutItemType": "com.app.\($0)", "UIApplicationShortcutItemTitle": "T"] }
        var plist: [String: Any] = ["UIApplicationShortcutItems": theirs]
        let strings = InfoPlistAdditions.apply(to: &plist)
        let items = plist["UIApplicationShortcutItems"] as? [[String: Any]] ?? []
        let ours = items.compactMap { $0["UIApplicationShortcutItemType"] as? String }.filter { $0.hasPrefix("io.github.xside.shortcut.") }
        #expect(ours == Array(["settings", "refresh", "report"].prefix(added)).map { "io.github.xside.shortcut.\($0)" })
        #expect(items.count == appItems + added)
        #expect((strings["fr"] ?? [:]).filter { $0.key != "NSLocalNetworkUsageDescription" }.count == added)
    }

    /// The titles are plain text in the installation's language (what shows when the app has no
    /// localization: XSide adds no lproj, final review Important 2); the app's own lprojs get the
    /// translations, keyed by that plain text as iOS looks them up.
    @Test func shortcutTitlesArePlainTextTranslatedByKey() {
        var plist: [String: Any] = [:]
        let strings = InfoPlistAdditions.apply(to: &plist, language: "fr")
        let titles = (plist["UIApplicationShortcutItems"] as? [[String: Any]] ?? []).compactMap { $0["UIApplicationShortcutItemTitle"] as? String }
        #expect(titles == ["Réglages XSide", "Rafraîchir maintenant", "Signaler un problème"])
        #expect(titles.map { strings["en"]?[$0] } == ["XSide Settings", "Refresh now", "Report a problem"])
        #expect(titles.map { strings["fr"]?[$0] } == titles)
        var english: [String: Any] = [:]
        InfoPlistAdditions.apply(to: &english)
        #expect((english["UIApplicationShortcutItems"] as? [[String: Any]])?.first?["UIApplicationShortcutItemTitle"] as? String == "XSide Settings")
    }

    /// Without XSide features nothing of XSide's stays: items of an earlier signing are removed.
    @Test func removingLeavesOnlyTheAppsItems() {
        let theirs: [String: Any] = ["UIApplicationShortcutItemType": "com.app.search"]
        var plist: [String: Any] = ["UIApplicationShortcutItems": [theirs, ["UIApplicationShortcutItemType": "io.github.xside.shortcut.refresh"]]]
        InfoPlistAdditions.removeShortcuts(from: &plist)
        #expect((plist["UIApplicationShortcutItems"] as? [[String: Any]])?.count == 1)
        var only: [String: Any] = ["UIApplicationShortcutItems": [["UIApplicationShortcutItemType": "io.github.xside.shortcut.refresh"]]]
        InfoPlistAdditions.removeShortcuts(from: &only)
        #expect(only["UIApplicationShortcutItems"] == nil)
        var none: [String: Any] = [:]
        InfoPlistAdditions.removeShortcuts(from: &none)
        #expect(none.isEmpty)
    }

    /// Final review Important 2: the plain value is the text in the installation's language (it is
    /// what shows when the app has no localization at all), the other languages go to the strings.
    @Test func usageIsPlainTextInTheGivenLanguage() {
        var plist: [String: Any] = [:]
        let strings = InfoPlistAdditions.apply(to: &plist, language: "fr")
        #expect(plist["NSLocalNetworkUsageDescription"] as? String == "XSide demande à ton Mac de rafraîchir cette app.")
        #expect(strings["en"]?["NSLocalNetworkUsageDescription"] == "XSide asks your Mac to refresh this app.")
    }
}

@Suite struct LocalizedStringsTests {
    private func dir(_ lprojs: [String]) throws -> URL {
        let dir = TestTemp.root.appendingPathComponent(UUID().uuidString)
        for name in lprojs {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func table(_ url: URL) throws -> [String: String] {
        try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }

    private func lprojs(_ dir: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".lproj") })
    }

    /// Final review Important 2: a new fr.lproj/en.lproj would make iOS take the app as localized
    /// in French and English (its own texts then missing). Only the folders already there get texts.
    @Test func noLprojIsCreated() throws {
        let app = try dir(["zh-Hans.lproj"])
        LocalizedStrings.merge(["fr": ["k": "français"], "en": ["k": "english"]], into: app, table: "InfoPlist")
        #expect(try lprojs(app) == ["zh-Hans.lproj"])
        #expect(try table(app.appendingPathComponent("zh-Hans.lproj/InfoPlist.strings"))["k"] == "english")
        let bare = try dir([])
        LocalizedStrings.merge(["fr": ["k": "français"], "en": ["k": "english"]], into: bare, table: "InfoPlist")
        #expect(try lprojs(bare).isEmpty)
    }

    /// Final review minor 7: "French.lproj" and "English.lproj" (older projects) are French and English.
    @Test func legacyLprojNamesKeepTheirLanguage() throws {
        let app = try dir(["French.lproj", "English.lproj", "fr_CA.lproj", "fr-BE.lproj", "de.lproj"])
        LocalizedStrings.merge(["fr": ["k": "français"], "en": ["k": "english"]], into: app, table: "InfoPlist")
        #expect(try lprojs(app) == ["French.lproj", "English.lproj", "fr_CA.lproj", "fr-BE.lproj", "de.lproj"])
        for name in ["French", "fr_CA", "fr-BE"] {
            #expect(try table(app.appendingPathComponent("\(name).lproj/InfoPlist.strings"))["k"] == "français")
        }
        #expect(try table(app.appendingPathComponent("English.lproj/InfoPlist.strings"))["k"] == "english")
        #expect(try table(app.appendingPathComponent("de.lproj/InfoPlist.strings"))["k"] == "english")
        #expect(LocalizedStrings.language(ofLproj: "French.lproj") == "fr" && LocalizedStrings.language(ofLproj: "fr.lproj") == "fr")
        #expect(LocalizedStrings.language(ofLproj: "Base.lproj") == nil)
    }

    /// Inside Settings.bundle (XSide's to manage), folders are added for the app's own languages
    /// only, one per language (an app's "French.lproj" is not doubled by a "fr.lproj"), each seeded
    /// with the app's copy of the table.
    @Test func mirroredLanguagesAreAddedOnce() throws {
        let bundle = try dir(["fr.lproj", "en.lproj"])
        try Data(#""dark" = "Dark";"#.utf8).write(to: bundle.appendingPathComponent("en.lproj/Root.strings"))
        LocalizedStrings.merge(["fr": ["k": "français"], "en": ["k": "english"]], into: bundle, table: "Root",
                               mirroring: ["French.lproj", "de.lproj", "Base.lproj", "English.lproj"])
        #expect(try lprojs(bundle) == ["fr.lproj", "en.lproj", "de.lproj"])
        let de = try table(bundle.appendingPathComponent("de.lproj/Root.strings"))
        #expect(de["k"] == "english" && de["dark"] == "Dark")
    }
}
