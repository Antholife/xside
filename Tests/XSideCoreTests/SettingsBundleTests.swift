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

/// XSide's own page, opened from the "Réglages XSide" row.
private func child(_ app: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: app.appendingPathComponent("Settings.bundle/XSide.plist"))
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

private func childItems(_ app: URL) throws -> [[String: Any]] {
    try #require(try child(app)["PreferenceSpecifiers"] as? [[String: Any]])
}

struct SettingsBundleTests {
    /// The app's page gets one row, "Réglages XSide", opening XSide's own page with the section.
    @Test func createsThePageWhenTheAppHasNone() throws {
        let app = try makeApp()
        try SettingsBundle.add(section, to: app)
        let items = try specifiers(app)
        #expect(items.count == 2)
        #expect(items[0]["Type"] as? String == "PSGroupSpecifier")
        // iOS already heads the page "<App> Settings": no second title, no footer here.
        #expect(items[0]["Title"] == nil && items[0]["FooterText"] == nil)
        #expect(items[1]["Type"] as? String == "PSChildPaneSpecifier")
        #expect(items[1]["File"] as? String == "XSide")
        #expect(items[1]["Title"] as? String == "io.github.xside.settings.title.group")
        #expect((items[1]["Key"] as? String)?.hasPrefix("io.github.xside.settings.") == true)
        // The row's id, so the dylib can open XSide's page directly (App-prefs:<id>&path=<this>).
        #expect(items[1]["id"] as? String == "io.github.xside.settings.pane")
        #expect(items[1]["Key"] as? String == "io.github.xside.settings.pane")
        let page = try child(app)
        #expect(page["Title"] as? String == "io.github.xside.settings.title.group")
        #expect(page["StringsTable"] as? String == "XSide")
        #expect(try root(app)["StringsTable"] as? String == "XSide")
        let rows = try childItems(app)
        #expect(rows.count == 3)
        #expect(rows[0]["Type"] as? String == "PSGroupSpecifier")
        #expect(rows[0]["Title"] == nil)
        #expect(rows[0]["FooterText"] as? String == "io.github.xside.settings.footer")
        #expect(rows[1]["Type"] as? String == "PSTitleValueSpecifier")
        #expect(rows[1]["Title"] as? String == "io.github.xside.settings.title.validUntil")
        #expect(rows[1]["DefaultValue"] as? String == "jeu. 12 nov.")
        #expect((rows[1]["Key"] as? String)?.hasPrefix("io.github.xside.settings.") == true)
        #expect(rows[2]["Title"] as? String == "io.github.xside.settings.title.refreshedOn")
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
        #expect(items.count == 3)
        #expect(items[0]["Key"] as? String == "dark")
        #expect(items[1]["Type"] as? String == "PSGroupSpecifier")
        #expect(items[2]["Type"] as? String == "PSChildPaneSpecifier")
        #expect(try root(app)["StringsTable"] as? String == "Root")
        #expect(try child(app)["StringsTable"] as? String == "Root") // the same table as the page
        #expect(try childItems(app).count == 3)
    }

    @Test func addingTwiceReplacesTheSection() throws {
        let app = try makeApp()
        try SettingsBundle.add(section, to: app)
        try SettingsBundle.add(SettingsSection(titleKey: "T", footerKey: nil, rows: [.value(titleKey: "V", key: "validUntil", defaultValue: "ven. 19 nov.")], strings: [:]), to: app)
        #expect(try specifiers(app).count == 2)
        #expect(try specifiers(app)[1]["Title"] as? String == "T")
        let rows = try childItems(app)
        #expect(rows.count == 2)
        #expect(rows[1]["DefaultValue"] as? String == "ven. 19 nov.")
        #expect(rows[0]["FooterText"] == nil)
    }

    /// XSide's page file is checked like the page: never written through a link or over a folder.
    @Test func refusesALinkedOrOddChildPage() throws {
        let app = try makeApp()
        let bundle = app.appendingPathComponent("Settings.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let elsewhere = try tempDir().appendingPathComponent("target.plist")
        try Data().write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("XSide.plist"), withDestinationURL: elsewhere)
        #expect(throws: (any Error).self) { try SettingsBundle.add(section, to: app) }
        #expect(try Data(contentsOf: elsewhere).isEmpty)
        let folder = try makeApp()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Settings.bundle/XSide.plist"),
                                                withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try SettingsBundle.add(section, to: folder) }
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

    private func xsideSection(language: String = "en") -> SettingsSection {
        SettingsSection.xside(validUntil: "12 nov.", refreshedOn: "5 nov.", version: "1.2", installedOn: "1 nov.",
                              inApp: InAppSettings.defaults(reminder: false, at: Date(timeIntervalSince1970: 0)),
                              language: language)
    }

    /// The app's own lproj folders (Settings.bundle mirrors only these).
    private func addAppLprojs(_ app: URL, _ names: [String]) throws {
        for name in names {
            try FileManager.default.createDirectory(at: app.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    private func lprojs(_ dir: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".lproj") })
    }

    /// Final review Important 2: titles are plain text in the installation's language, shown as they
    /// are when nothing translates them; an app without localizations gets no lproj at all.
    @Test func titlesArePlainTextAndNoLanguageIsAdded() throws {
        let app = try makeApp()
        try SettingsBundle.add(xsideSection(language: "fr"), to: app)
        #expect(try specifiers(app)[1]["Title"] as? String == "Réglages XSide")
        let rows = try childItems(app)
        #expect(rows.first { $0["Key"] as? String == "io.github.xside.settings.validUntil" }?["Title"] as? String == "Valable jusqu'au")
        #expect((rows[0]["FooterText"] as? String)?.hasPrefix("✦ Installée avec XSide") == true)
        #expect(lprojs(app.appendingPathComponent("Settings.bundle")).isEmpty)
        #expect(lprojs(app).isEmpty)
        let en = try makeApp()
        try SettingsBundle.add(xsideSection(language: "en"), to: en)
        #expect(try specifiers(en)[1]["Title"] as? String == "XSide Settings")
    }

    @Test func settingsSectionHasTogglesAndChoices() throws {
        let app = try makeApp()
        try SettingsBundle.add(xsideSection(), to: app)
        let items = try childItems(app)
        let p = "io.github.xside.settings."
        func item(_ key: String) throws -> [String: Any] { try #require(items.first { $0["Key"] as? String == p + key }) }
        #expect(items.count == 14)
        // First, the one action iOS Settings can offer: a switch the app turns back off at launch.
        #expect(items[1]["Key"] as? String == p + "refreshOnLaunch")
        #expect(items[1]["Type"] as? String == "PSToggleSwitchSpecifier")
        #expect(items[1]["DefaultValue"] as? Bool == false)
        #expect(items.dropFirst(2).prefix(6).allSatisfy { $0["Type"] as? String == "PSTitleValueSpecifier" })
        #expect(try item("connection")["DefaultValue"] as? String == "—")
        #expect(try item("version")["DefaultValue"] as? String == "1.2")
        for key in ["showValidity", "alertLate", "refreshCard", "reminder", "autoRefresh"] {
            #expect(try item(key)["Type"] as? String == "PSToggleSwitchSpecifier")
        }
        #expect(try item("showValidity")["DefaultValue"] as? Bool == true) // on by default (Anthony)
        #expect(try item("reminder")["DefaultValue"] as? Bool == false) // the installation's value
        #expect(try item("autoRefresh")["DefaultValue"] as? Bool == true)
        // "Messages XSide" is gone: the level is derived from the four switches.
        #expect(items.first { $0["Key"] as? String == p + "level" } == nil)
        let language = try item("language")
        #expect(language["Type"] as? String == "PSMultiValueSpecifier")
        #expect(language["Values"] as? [String] == ["automatic", "fr", "en"])
        #expect(language["Titles"] as? [String] == ["Automatic", "Français", "English"])
    }

    /// The app is localized in French and English: Settings.bundle gets those two folders (and
    /// only those), keyed by the plain English titles.
    @Test func settingsTitlesGetTheirOwnTableOtherwise() throws {
        let app = try makeApp()
        try addAppLprojs(app, ["fr.lproj", "en.lproj", "Base.lproj"])
        try SettingsBundle.add(xsideSection(), to: app)
        #expect(try root(app)["StringsTable"] as? String == "XSide")
        let bundle = app.appendingPathComponent("Settings.bundle")
        #expect(lprojs(bundle) == ["fr.lproj", "en.lproj"])
        let fr = try strings(bundle.appendingPathComponent("fr.lproj/XSide.strings"))
        let en = try strings(bundle.appendingPathComponent("en.lproj/XSide.strings"))
        #expect(fr["XSide Settings"] == "Réglages XSide")
        #expect(fr["Connection to the Mac"] == "Connexion au Mac")
        #expect(fr["Refresh at next launch"] == "Rafraîchir à la prochaine ouverture")
        #expect(en["Refresh at next launch"] == "Refresh at next launch")
        #expect(fr["Last refresh"] == "Dernier rafraîchissement")
        let footer = try #require(fr.keys.first { $0.hasPrefix("✦ Installed with XSide") })
        #expect(fr[footer]?.hasPrefix("✦ Installée avec XSide\n• Rafraîchie automatiquement depuis ton Mac\n• ") == true)
        #expect(en[footer]?.contains("\n• Your choices apply on this iPhone right away\n") == true)
        #expect(fr[footer]?.hasSuffix("github.com/Antholife/xside") == true)
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
        try addAppLprojs(app, ["English.lproj", "fr.lproj", "de.lproj"])
        try SettingsBundle.add(xsideSection(language: "fr"), to: app)
        #expect(try root(app)["StringsTable"] as? String == "Root")
        let fr = try strings(frDir.appendingPathComponent("Root.strings"))
        #expect(fr["dark.title"] == "Mode sombre") // the app's own entry kept
        #expect(fr["Réglages XSide"] == "Réglages XSide")
        // English.lproj mirrored (the app has it); a language XSide doesn't translate gets English.
        #expect(lprojs(bundle) == ["fr.lproj", "de.lproj", "English.lproj"])
        #expect(try strings(bundle.appendingPathComponent("English.lproj/Root.strings"))["Réglages XSide"] == "XSide Settings")
        let de = try strings(deDir.appendingPathComponent("Root.strings"))
        #expect(de["dark.title"] == "Dunkel")
        #expect(de["Réglages XSide"] == "XSide Settings")
        // The app's title still resolves in every lproj, including the ones XSide created.
        #expect(try strings(bundle.appendingPathComponent("English.lproj/Root.strings"))["dark.title"] != nil) // seeded from a copy
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("fr.lproj/XSide.strings").path))
    }

    /// A new fr.lproj/Root.strings must not hide the app's own titles (iOS reads one table per language).
    @Test func createdLprojsAreSeededWithTheAppsOwnTitles() throws {
        let app = try makeApp()
        let bundle = app.appendingPathComponent("Settings.bundle")
        let enDir = bundle.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: enDir, withIntermediateDirectories: true)
        let own: [String: Any] = ["StringsTable": "Root",
                                  "PreferenceSpecifiers": [["Type": "PSToggleSwitchSpecifier", "Key": "dark", "Title": "dark.title"]]]
        try PropertyListSerialization.data(fromPropertyList: own, format: .binary, options: 0)
            .write(to: bundle.appendingPathComponent("Root.plist"))
        try Data(#""dark.title" = "Dark mode";"#.utf8).write(to: enDir.appendingPathComponent("Root.strings"))
        try addAppLprojs(app, ["fr.lproj"])
        try SettingsBundle.add(xsideSection(), to: app)
        let fr = try strings(bundle.appendingPathComponent("fr.lproj/Root.strings"))
        #expect(fr["dark.title"] == "Dark mode")
        #expect(fr["XSide Settings"] == "Réglages XSide")
    }

    /// No StringsTable key means iOS reads "Root": XSide's keys go there, not to a table the page never names.
    @Test func rootStringsAreUsedWhenThePageNamesNoTable() throws {
        let app = try makeApp()
        let bundle = app.appendingPathComponent("Settings.bundle")
        let enDir = bundle.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: enDir, withIntermediateDirectories: true)
        let own: [String: Any] = ["PreferenceSpecifiers": [["Type": "PSToggleSwitchSpecifier", "Key": "dark", "Title": "dark.title"]]]
        try PropertyListSerialization.data(fromPropertyList: own, format: .binary, options: 0)
            .write(to: bundle.appendingPathComponent("Root.plist"))
        try Data(#""dark.title" = "Dark mode";"#.utf8).write(to: enDir.appendingPathComponent("Root.strings"))
        try SettingsBundle.add(xsideSection(), to: app)
        let en = try strings(enDir.appendingPathComponent("Root.strings"))
        #expect(en["dark.title"] == "Dark mode")
        #expect(en["XSide Settings"] == "XSide Settings")
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("en.lproj/XSide.strings").path))
        #expect(try root(app)["StringsTable"] as? String != "XSide")
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
