import Foundation

/// The section XSide adds to an app's page in the iOS Settings app (Settings > <App>): a group
/// titled `title` with one read-only line per row. Texts come ready to show, in XSide's language:
/// a Settings page can't compute anything, and it's rewritten at each refresh.
public struct SettingsSection: Sendable {
    public let title: String
    public let footer: String?
    public let rows: [(title: String, value: String)]

    public init(title: String, footer: String?, rows: [(title: String, value: String)]) {
        self.title = title
        self.footer = footer
        self.rows = rows
    }
}

/// Writes `SettingsSection`s into `<App>.app/Settings.bundle/Root.plist`.
public enum SettingsBundle {
    /// Every item XSide adds carries a key with this prefix, so a re-sign replaces them.
    static let keyPrefix = "io.github.xside.settings."

    struct NotAPage: Error {}

    /// Adds (or replaces) the section at the end of the app's page, creating the page if the app
    /// has none. The app's own items and keys stay as they were. Throws on a page it can't read,
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
        var group: [String: Any] = ["Type": "PSGroupSpecifier", "Title": section.title, "Key": keyPrefix + "group"]
        if let footer = section.footer { group["FooterText"] = footer }
        items.append(group)
        for (index, row) in section.rows.enumerated() {
            items.append(["Type": "PSTitleValueSpecifier", "Title": row.title,
                          "Key": keyPrefix + "row\(index)", "DefaultValue": row.value])
        }
        root["PreferenceSpecifiers"] = items
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        try data.write(to: rootURL, options: .atomic)
    }
}
