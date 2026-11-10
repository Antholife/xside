import Foundation

/// The section XSide adds to an app's page in the iOS Settings app: a group followed by rows.
/// Every title is a key, looked up by iOS in the bundle's strings table in the device's language,
/// and `strings` carries the texts (language "fr"/"en" -> key -> text). XSide's own section uses
/// plain text in the installation's language as keys (`plainText(in:)`), so a title nothing
/// translates still reads right.
public struct SettingsSection: Sendable {
    public enum Row: Sendable {
        /// Read-only line; `key` (without the XSide prefix) is where the dylib rewrites the value
        /// at each launch, `defaultValue` what the Mac wrote at signing.
        case value(titleKey: String, key: String, defaultValue: String)
        case toggle(titleKey: String, key: String, defaultValue: Bool)
        /// `titleKeys` are shown, `values` are stored (same order).
        case choice(titleKey: String, key: String, titleKeys: [String], values: [String], defaultValue: String)
    }

    public let titleKey: String
    public let footerKey: String?
    public let rows: [Row]
    public let strings: [String: [String: String]]

    public init(titleKey: String, footerKey: String?, rows: [Row], strings: [String: [String: String]]) {
        self.titleKey = titleKey
        self.footerKey = footerKey
        self.rows = rows
        self.strings = strings
    }

    /// The same section with each key replaced by its text in `language` (the key itself when it
    /// has none), and `strings` keyed by those texts: iOS shows a key no table defines as it is,
    /// so an app without localizations gets readable titles and no lproj (final review
    /// Important 2), and the others get the translations in the folders they already have.
    public func plainText(in language: String) -> SettingsSection {
        let source = strings[language] ?? strings["en"] ?? [:]
        func text(_ key: String) -> String { source[key] ?? key }
        let rows = rows.map { row -> Row in
            switch row {
            case let .value(titleKey, key, defaultValue):
                return .value(titleKey: text(titleKey), key: key, defaultValue: defaultValue)
            case let .toggle(titleKey, key, defaultValue):
                return .toggle(titleKey: text(titleKey), key: key, defaultValue: defaultValue)
            case let .choice(titleKey, key, titleKeys, values, defaultValue):
                return .choice(titleKey: text(titleKey), key: key, titleKeys: titleKeys.map(text), values: values,
                               defaultValue: defaultValue)
            }
        }
        var plain: [String: [String: String]] = [:]
        for (lang, table) in strings {
            for (key, translation) in table { plain[lang, default: [:]][text(key)] = translation }
        }
        return SettingsSection(titleKey: text(titleKey), footerKey: footerKey.map(text), rows: rows, strings: plain)
    }
}

/// Writes a `SettingsSection` into the app's Settings.bundle: one row "Réglages XSide" on the app's
/// page (`Root.plist`), opening XSide's own page (`XSide.plist`) that holds the section.
public enum SettingsBundle {
    /// Every item XSide adds carries a key with this prefix, so a re-sign replaces them. The
    /// dylib reads and writes the app's defaults under `keyPrefix + row key`.
    static let keyPrefix = "io.github.xside.settings."

    /// The strings table XSide creates when the app's page has none.
    static let ownTable = "XSide"
    /// XSide's page in the bundle (`<name>.plist`), named by the row's `File`.
    static let paneFile = "XSide"
    /// The page « Tweaks · N » opens (`TweaksPane`).
    static let tweaksFile = "XSideTweaks"

    private static func hasStrings(named table: String, in bundle: URL) -> Bool {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? []).contains {
            $0.pathExtension == "lproj"
                && (try? fm.attributesOfItem(atPath: $0.appendingPathComponent("\(table).strings").path)[.type]
                    as? FileAttributeType) == .typeRegular
        }
    }

    struct NotAPage: Error {}

    /// Adds (or replaces) XSide's row at the end of the app's page, creating the page if the app
    /// has none, and writes XSide's page with the section. The app's own items and keys stay as
    /// they were. Titles are keys of the app's own `StringsTable` when its page has one (XSide's
    /// texts merged into each `<lang>.lproj`, the app's entries kept), else of a table of XSide's,
    /// `XSide`; XSide's page uses the same table. Throws on a page it can't read, or on links (a
    /// link could make it write outside the app).
    /// `tweaks`: a second row, « Tweaks · N », after XSide's, opening a page of its own; without
    /// `section` (no XSide module in the app) the row is alone. Either missing: its row and page go.
    /// Both missing: nothing is written.
    public static func add(_ section: SettingsSection?, tweaks: TweaksPane? = nil, to app: URL) throws {
        guard section != nil || tweaks != nil else { return }
        let fm = FileManager.default
        let bundle = app.appendingPathComponent("Settings.bundle")
        let rootURL = bundle.appendingPathComponent("Root.plist")
        let paneURL = bundle.appendingPathComponent(paneFile + ".plist")
        let tweaksURL = bundle.appendingPathComponent(tweaksFile + ".plist")
        var root: [String: Any] = [:]
        if let type = try? fm.attributesOfItem(atPath: bundle.path)[.type] as? FileAttributeType {
            guard type == .typeDirectory else { throw NotAPage() }
            if let rootType = try? fm.attributesOfItem(atPath: rootURL.path)[.type] as? FileAttributeType {
                guard rootType == .typeRegular else { throw NotAPage() }
                let data = try Data(contentsOf: rootURL)
                guard let read = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { throw NotAPage() }
                root = read
            }
            // Replaced only if it is a plain file (from an earlier signing).
            for url in [paneURL, tweaksURL] {
                if let type = try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
                   type != .typeRegular { throw NotAPage() }
            }
        } else {
            try fm.createDirectory(at: bundle, withIntermediateDirectories: false)
        }
        // The app's page: its own items, then a group (untitled: iOS heads the page "<App>
        // Settings" already, and the row says what it opens) with the one row.
        var items = (root["PreferenceSpecifiers"] as? [[String: Any]] ?? [])
            .filter { ($0["Key"] as? String)?.hasPrefix(keyPrefix) != true }
        items.append(["Type": "PSGroupSpecifier", "Key": keyPrefix + "group"])
        // "id" names the row for Settings' deep links: the dylib opens XSide's page directly with
        // "App-prefs:<bundle id>&path=<id>" (XSSettingsPaneURLString, undocumented).
        if let section {
            items.append(["Type": "PSChildPaneSpecifier", "Title": section.titleKey, "File": paneFile,
                          "Key": keyPrefix + "pane", "id": keyPrefix + "pane"])
        }
        // Read-only and static: nothing on the phone needs to run for it (XSide's module or not).
        if let tweaks {
            items.append(["Type": "PSChildPaneSpecifier", "Title": tweaks.rowTitle, "File": tweaksFile,
                          "Key": keyPrefix + "tweaks", "id": keyPrefix + "tweaks"])
        }

        // XSide's page: the section, its footer under the rows.
        var group: [String: Any] = ["Type": "PSGroupSpecifier", "Key": keyPrefix + "section"]
        if let footer = section?.footerKey { group["FooterText"] = footer }
        var rows: [[String: Any]] = [group]
        for row in section?.rows ?? [] {
            switch row {
            case let .value(titleKey, key, defaultValue):
                rows.append(["Type": "PSTitleValueSpecifier", "Title": titleKey,
                             "Key": keyPrefix + key, "DefaultValue": defaultValue])
            case let .toggle(titleKey, key, defaultValue):
                rows.append(["Type": "PSToggleSwitchSpecifier", "Title": titleKey,
                             "Key": keyPrefix + key, "DefaultValue": defaultValue])
            case let .choice(titleKey, key, titleKeys, values, defaultValue):
                rows.append(["Type": "PSMultiValueSpecifier", "Title": titleKey, "Key": keyPrefix + key,
                             "Titles": titleKeys, "Values": values, "DefaultValue": defaultValue])
            }
        }
        // The page's own table; with none named iOS reads "Root", so XSide's keys go there when the
        // app ships a Root.strings; only an app with no strings at all gets XSide's table.
        let table: String
        if let named = root["StringsTable"] as? String {
            table = named
        } else if hasStrings(named: "Root", in: bundle) {
            table = "Root"
        } else {
            table = ownTable
            root["StringsTable"] = table
        }
        root["PreferenceSpecifiers"] = items
        if let section {
            let pane: [String: Any] = ["Title": section.titleKey, "StringsTable": table, "PreferenceSpecifiers": rows]
            try PropertyListSerialization.data(fromPropertyList: pane, format: .xml, options: 0).write(to: paneURL, options: .atomic)
        } else if fm.fileExists(atPath: paneURL.path) {
            try fm.removeItem(at: paneURL) // a plain file (checked above), from an earlier signing
        }
        if let tweaks {
            var rows: [[String: Any]] = []
            for (i, g) in tweaks.groups.enumerated() {
                var group: [String: Any] = ["Type": "PSGroupSpecifier", "Title": g.title, "Key": keyPrefix + "tweak.\(i)"]
                if let footer = g.footer { group["FooterText"] = footer }
                rows.append(group)
                rows.append(["Type": "PSTitleValueSpecifier", "Title": "Version", "Key": keyPrefix + "tweak.\(i).version",
                             "DefaultValue": g.version])
            }
            let page: [String: Any] = ["Title": tweaks.title, "StringsTable": table, "PreferenceSpecifiers": rows]
            try PropertyListSerialization.data(fromPropertyList: page, format: .xml, options: 0).write(to: tweaksURL, options: .atomic)
        } else if fm.fileExists(atPath: tweaksURL.path) {
            try fm.removeItem(at: tweaksURL)
        }
        try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0).write(to: rootURL, options: .atomic)
        // After the pages: a strings file that can't be merged only leaves keys untranslated.
        // A table name with a path in it would make us write elsewhere.
        if !table.isEmpty, !table.contains("/"), !table.contains("..") {
            let info = (try? Data(contentsOf: app.appendingPathComponent("Info.plist")))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            // Translations in the languages the app already has, never more (its localization set
            // stays as it was). In the app's own table, an entry it already has for the same text wins.
            let appLanguages = ((try? fm.contentsOfDirectory(atPath: app.path)) ?? []).filter { $0.hasSuffix(".lproj") }.sorted()
            var texts = section?.strings ?? [:]
            texts.merge(tweaks?.strings ?? [:]) { $0.merging($1) { mine, _ in mine } }
            let ownKeys = table == ownTable ? [] : Set(texts.values.flatMap(\.keys))
            LocalizedStrings.merge(texts, into: bundle, table: table, keepExisting: ownKeys,
                                   developmentRegion: info?["CFBundleDevelopmentRegion"] as? String,
                                   mirroring: appLanguages)
        }
    }
}
