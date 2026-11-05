import Testing
import Foundation
@testable import XSideCore

private let section = SettingsSection(title: "Installée avec XSide", footer: "github.com/Antholife/xside",
                                      rows: [("Valable jusqu'au", "jeu. 12 nov."), ("Signée le", "jeu. 5 nov.")])

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
        #expect(items[0]["Title"] as? String == "Installée avec XSide")
        #expect(items[0]["FooterText"] as? String == "github.com/Antholife/xside")
        #expect(items[1]["Type"] as? String == "PSTitleValueSpecifier")
        #expect(items[1]["Title"] as? String == "Valable jusqu'au")
        #expect(items[1]["DefaultValue"] as? String == "jeu. 12 nov.")
        #expect((items[1]["Key"] as? String)?.hasPrefix("io.github.xside.settings.") == true)
        #expect(items[2]["Title"] as? String == "Signée le")
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
        #expect(items[1]["Title"] as? String == "Installée avec XSide")
        #expect(try root(app)["StringsTable"] as? String == "Root")
    }

    @Test func addingTwiceReplacesTheSection() throws {
        let app = try makeApp()
        try SettingsBundle.add(section, to: app)
        try SettingsBundle.add(SettingsSection(title: "T", footer: nil, rows: [("Valable jusqu'au", "ven. 19 nov.")]), to: app)
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
}
