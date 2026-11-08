import Foundation

/// The section XSide adds to an app's page in the iOS Settings app: a group followed by rows.
/// Nothing is pre-translated: every title is a key, looked up by iOS in the bundle's strings table
/// in the device's language, and `strings` carries the texts (language "fr"/"en" -> key -> text).
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
}

/// Writes `SettingsSection`s into `<App>.app/Settings.bundle/Root.plist`.
public enum SettingsBundle {
    /// Every item XSide adds carries a key with this prefix, so a re-sign replaces them. The
    /// dylib reads and writes the app's defaults under `keyPrefix + row key`.
    static let keyPrefix = "io.github.xside.settings."

    /// The strings table XSide creates when the app's page has none.
    static let ownTable = "XSide"

    private static func hasStrings(named table: String, in bundle: URL) -> Bool {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? []).contains {
            $0.pathExtension == "lproj"
                && (try? fm.attributesOfItem(atPath: $0.appendingPathComponent("\(table).strings").path)[.type]
                    as? FileAttributeType) == .typeRegular
        }
    }

    struct NotAPage: Error {}

    /// Adds (or replaces) the section at the end of the app's page, creating the page if the app
    /// has none. The app's own items and keys stay as they were. Titles are keys of the app's own
    /// `StringsTable` when its page has one (XSide's texts merged into each `<lang>.lproj`, the
    /// app's entries kept), else of a table of XSide's, `XSide`. Throws on a page it can't read,
    /// or on links (a link could make it write outside the app).
    public static func add(_ section: SettingsSection, to app: URL) throws {
        let fm = FileManager.default
        let bundle = app.appendingPathComponent("Settings.bundle")
        let rootURL = bundle.appendingPathComponent("Root.plist")
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
        } else {
            try fm.createDirectory(at: bundle, withIntermediateDirectories: false)
        }
        var items = (root["PreferenceSpecifiers"] as? [[String: Any]] ?? [])
            .filter { ($0["Key"] as? String)?.hasPrefix(keyPrefix) != true }
        var group: [String: Any] = ["Type": "PSGroupSpecifier", "Title": section.titleKey, "Key": keyPrefix + "group"]
        if let footer = section.footerKey { group["FooterText"] = footer }
        items.append(group)
        for row in section.rows {
            switch row {
            case let .value(titleKey, key, defaultValue):
                items.append(["Type": "PSTitleValueSpecifier", "Title": titleKey,
                              "Key": keyPrefix + key, "DefaultValue": defaultValue])
            case let .toggle(titleKey, key, defaultValue):
                items.append(["Type": "PSToggleSwitchSpecifier", "Title": titleKey,
                              "Key": keyPrefix + key, "DefaultValue": defaultValue])
            case let .choice(titleKey, key, titleKeys, values, defaultValue):
                items.append(["Type": "PSMultiValueSpecifier", "Title": titleKey, "Key": keyPrefix + key,
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
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        try data.write(to: rootURL, options: .atomic)
        // After the page itself: a strings file that can't be merged only leaves keys untranslated.
        // A table name with a path in it would make us write elsewhere.
        if !table.isEmpty, !table.contains("/"), !table.contains("..") {
            let info = (try? Data(contentsOf: app.appendingPathComponent("Info.plist")))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            LocalizedStrings.merge(section.strings, into: bundle, table: table,
                                   developmentRegion: info?["CFBundleDevelopmentRegion"] as? String)
        }
    }
}
