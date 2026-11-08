import Testing
import Foundation
@testable import XSideCore

private let section = SettingsSection(
    titleKey: "io.github.xside.settings.title.group", footerKey: "io.github.xside.settings.footer",
    rows: [.value(titleKey: "io.github.xside.settings.title.validUntil", key: "validUntil", defaultValue: "jeu. 12 nov."),
           .value(titleKey: "io.github.xside.settings.title.refreshedOn", key: "refreshedOn", defaultValue: "jeu. 5 nov.")],
    strings: ["fr": ["io.github.xside.settings.title.group": "Réglages XSide"],
              "en": ["io.github.xside.settings.title.group": "XSide Settings"]])

private func strings(_ url: URL) throws -> [String: String] {
    try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
}

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func makeApp() throws -> URL {
    let dir = try tempDir().appendingPathComponent("Demo.app")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func root(_ app: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: app.appendingPathComponent("Settings.bundle/Root.plist"))
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

private func specifiers(_ app: URL) throws -> [[String: Any]] {
    try #require(try root(app)["PreferenceSpecifiers"] as? [[String: Any]])
}

struct SettingsBundleTests {
    @Test func createsThePageWhenTheAppHasNone() throws {
        let app = try makeApp()
        try SettingsBundle.add(section, to: app)
        let items = try specifiers(app)
        #expect(items.count == 3)
        #expect(items[0]["Type"] as? String == "PSGroupSpecifier")
        #expect(items[0]["Title"] as? String == "io.github.xside.settings.title.group")
        #expect(items[0]["FooterText"] as? String == "io.github.xside.settings.footer")
        #expect(items[1]["Type"] as? String == "PSTitleValueSpecifier")
        #expect(items[1]["Title"] as? String == "io.github.xside.settings.title.validUntil")
        #expect(items[1]["DefaultValue"] as? String == "jeu. 12 nov.")
        #expect((items[1]["Key"] as? String)?.hasPrefix("io.github.xside.settings.") == true)
        #expect(items[2]["Title"] as? String == "io.github.xside.settings.title.refreshedOn")
    }

    @Test func appendsToTheAppsOwnPage() throws {
        let app = try makeApp()
        let bundle = app.appendingPathComponent("Settings.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let own: [String: Any] = ["StringsTable": "Root",
                                  "PreferenceSpecifiers": [["Type": "PSToggleSwitchSpecifier", "Key": "dark", "Title": "Dark"]]]
        // Binary, as many apps ship it.
        try PropertyListSerialization.data(fromPropertyList: own, format: .binary, options: 0)
            .write(to: bundle.appendingPathComponent("Root.plist"))
        try SettingsBundle.add(section, to: app)
        let items = try specifiers(app)
        #expect(items.count == 4)
        #expect(items[0]["Key"] as? String == "dark")
        #expect(items[1]["Title"] as? String == "io.github.xside.settings.title.group")
        #expect(try root(app)["StringsTable"] as? String == "Root")
    }

    @Test func addingTwiceReplacesTheSection() throws {
        let app = try makeApp()
        try SettingsBundle.add(section, to: app)
        try SettingsBundle.add(SettingsSection(titleKey: "T", footerKey: nil, rows: [.value(titleKey: "V", key: "validUntil", defaultValue: "ven. 19 nov.")], strings: [:]), to: app)
        let items = try specifiers(app)
        #expect(items.count == 2)
        #expect(items[1]["DefaultValue"] as? String == "ven. 19 nov.")
        #expect(items[0]["FooterText"] == nil)
    }

    @Test func refusesWhatIsntAPage() throws {
        let app = try makeApp()
        try Data("x".utf8).write(to: app.appendingPathComponent("Settings.bundle"))
        #expect(throws: (any Error).self) { try SettingsBundle.add(section, to: app) }
        let other = try makeApp()
        let bundle = other.appendingPathComponent("Settings.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: bundle.appendingPathComponent("Root.plist"))
        #expect(throws: (any Error).self) { try SettingsBundle.add(section, to: other) }
    }

    /// A link could make XSide write outside the app.
    @Test func refusesALinkedPage() throws {
        let app = try makeApp()
        let elsewhere = try tempDir()
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Settings.bundle"),
                                                   withDestinationURL: elsewhere)
        #expect(throws: (any Error).self) { try SettingsBundle.add(section, to: app) }
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("Root.plist").path))
    }

    private func xsideSection() -> SettingsSection {
        SettingsSection.xside(validUntil: "12 nov.", refreshedOn: "5 nov.", version: "1.2", installedOn: "1 nov.",
                              inApp: InAppSettings.defaults(reminder: false, at: Date(timeIntervalSince1970: 0)))
    }

    @Test func settingsSectionHasTogglesAndChoices() throws {
        let app = try makeApp()
        try SettingsBundle.add(xsideSection(), to: app)
        let items = try specifiers(app)
        let p = "io.github.xside.settings."
        func item(_ key: String) throws -> [String: Any] { try #require(items.first { $0["Key"] as? String == p + key }) }
        #expect(items.count == 14)
        #expect(items.dropFirst().prefix(6).allSatisfy { $0["Type"] as? String == "PSTitleValueSpecifier" })
        #expect(try item("connection")["DefaultValue"] as? String == "—")
        #expect(try item("version")["DefaultValue"] as? String == "1.2")
        for key in ["showValidity", "alertLate", "refreshCard", "reminder", "autoRefresh"] {
            #expect(try item(key)["Type"] as? String == "PSToggleSwitchSpecifier")
        }
        #expect(try item("showValidity")["DefaultValue"] as? Bool == false)
        #expect(try item("reminder")["DefaultValue"] as? Bool == false) // the installation's value
        #expect(try item("autoRefresh")["DefaultValue"] as? Bool == true)
        let level = try item("level")
        #expect(level["Type"] as? String == "PSMultiValueSpecifier")
        #expect(level["Values"] as? [String] == ["all", "essentials", "none"])
        #expect(level["Titles"] as? [String] == [p + "level.all", p + "level.essentials", p + "level.none"])
        #expect(level["DefaultValue"] as? String == "all")
        #expect(try item("language")["Values"] as? [String] == ["automatic", "fr", "en"])
    }

    @Test func settingsTitlesGetTheirOwnTableOtherwise() throws {
        let app = try makeApp()
        try SettingsBundle.add(xsideSection(), to: app)
        #expect(try root(app)["StringsTable"] as? String == "XSide")
        let bundle = app.appendingPathComponent("Settings.bundle")
        let fr = try strings(bundle.appendingPathComponent("fr.lproj/XSide.strings"))
        let en = try strings(bundle.appendingPathComponent("en.lproj/XSide.strings"))
        let p = "io.github.xside.settings."
        #expect(fr[p + "title.group"] == "Réglages XSide")
        #expect(fr[p + "title.connection"] == "Connexion au Mac")
        #expect(fr[p + "title.lastRefresh"] == "Dernier rafraîchissement")
        #expect(fr[p + "level.essentials"] == "Essentiels")
        #expect(fr[p + "footer"]?.hasPrefix("✦ Installée avec XSide") == true)
        #expect(fr[p + "footer"]?.hasSuffix("github.com/Antholife/xside") == true)
        #expect(en[p + "title.group"] == "XSide Settings")
        #expect(en[p + "footer"]?.hasPrefix("✦ Installed with XSide") == true)
        #expect(Set(fr.keys) == Set(en.keys))
    }

    @Test func settingsTitlesUseTheAppsStringsTable() throws {
        let app = try makeApp()
        let bundle = app.appendingPathComponent("Settings.bundle")
        let frDir = bundle.appendingPathComponent("fr.lproj")
        let deDir = bundle.appendingPathComponent("de.lproj")
        for dir in [frDir, deDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let own: [String: Any] = ["StringsTable": "Root",
                                  "PreferenceSpecifiers": [["Type": "PSToggleSwitchSpecifier", "Key": "dark", "Title": "dark.title"]]]
        try PropertyListSerialization.data(fromPropertyList: own, format: .binary, options: 0)
            .write(to: bundle.appendingPathComponent("Root.plist"))
        try Data(#""dark.title" = "Mode sombre";"#.utf8).write(to: frDir.appendingPathComponent("Root.strings"))
        try Data(#""dark.title" = "Dunkel";"#.utf8).write(to: deDir.appendingPathComponent("Root.strings"))
        try SettingsBundle.add(xsideSection(), to: app)
        #expect(try root(app)["StringsTable"] as? String == "Root")
        let p = "io.github.xside.settings."
        let fr = try strings(frDir.appendingPathComponent("Root.strings"))
        #expect(fr["dark.title"] == "Mode sombre") // the app's own entry kept
        #expect(fr[p + "title.group"] == "Réglages XSide")
        // en.lproj created; a language XSide doesn't translate falls back to English, its own entries kept.
        #expect(try strings(bundle.appendingPathComponent("en.lproj/Root.strings"))[p + "title.group"] == "XSide Settings")
        let de = try strings(deDir.appendingPathComponent("Root.strings"))
        #expect(de["dark.title"] == "Dunkel")
        #expect(de[p + "title.group"] == "XSide Settings")
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("fr.lproj/XSide.strings").path))
    }

    /// The old page formats (a file, a bad plist, a link) stay refused, with the v2 section too.
    @Test func oldPageFormatsStillRefused() throws {
        let file = try makeApp()
        try Data("x".utf8).write(to: file.appendingPathComponent("Settings.bundle"))
        #expect(throws: (any Error).self) { try SettingsBundle.add(xsideSection(), to: file) }
        let link = try makeApp()
        let elsewhere = try tempDir()
        try FileManager.default.createSymbolicLink(at: link.appendingPathComponent("Settings.bundle"),
                                                   withDestinationURL: elsewhere)
        #expect(throws: (any Error).self) { try SettingsBundle.add(xsideSection(), to: link) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        let linkedRoot = try makeApp()
        let bundle = linkedRoot.appendingPathComponent("Settings.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("Root.plist"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("x.plist"))
        #expect(throws: (any Error).self) { try SettingsBundle.add(xsideSection(), to: linkedRoot) }
    }
}
