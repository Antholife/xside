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

    /// Final review Important 1: XSide's quick actions are dynamic (set by the library in the slots
    /// the app leaves, after its own dynamic ones), so the Info.plist gets none, and those of an
    /// earlier signing are taken out. The app's own static items stay as they were.
    @Test func noStaticShortcutItemsAreAdded() {
        let theirs: [String: Any] = ["UIApplicationShortcutItemType": "com.app.search", "UIApplicationShortcutItemTitle": "Search"]
        let earlier: [String: Any] = ["UIApplicationShortcutItemType": "io.github.xside.shortcut.settings",
                                      "UIApplicationShortcutItemTitle": "io.github.xside.shortcut.settings.title"]
        var plist: [String: Any] = ["UIApplicationShortcutItems": [theirs, earlier]]
        let strings = InfoPlistAdditions.apply(to: &plist)
        let items = plist["UIApplicationShortcutItems"] as? [[String: Any]] ?? []
        #expect(items.map { $0["UIApplicationShortcutItemType"] as? String } == ["com.app.search"])
        #expect(strings.values.allSatisfy { $0.keys.allSatisfy { !$0.contains("shortcut") } })
        var empty: [String: Any] = [:]
        InfoPlistAdditions.apply(to: &empty)
        #expect(empty["UIApplicationShortcutItems"] == nil)
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
