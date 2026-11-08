import Foundation

/// Merges XSide's texts into the `<lang>.lproj/<table>.strings` files of a directory (an app, or
/// its Settings.bundle). Used for the Settings titles and the Info.plist texts (quick actions,
/// local-network reason), which iOS looks up by key in the device's language.
enum LocalizedStrings {
    private static let logger = Log("strings")

    /// Adds `strings` (language "fr" or "en" -> key -> text) to the table in every existing
    /// `.lproj` of `dir`, creating `fr.lproj` and `en.lproj` when missing. A `.lproj` for another
    /// language gets the English text, since iOS looks keys up in the one localization it picked
    /// and would otherwise show the raw key. Keys in `keepExisting` are left alone when the file
    /// already defines them (the app's own wording wins). A file XSide creates is seeded with the
    /// app's existing copy of the table (Base, then English, then `developmentRegion`, then any):
    /// iOS reads one table per language, so a bare new file would hide the app's own texts.
    /// Never throws: a file or folder it can't read, or that is a link, is skipped and logged, so
    /// the app is left as it was there.
    static func merge(_ strings: [String: [String: String]], into dir: URL, table: String,
                      keepExisting: Set<String> = [], developmentRegion: String? = nil) {
        let fm = FileManager.default
        guard type(dir) == .typeDirectory else { return }
        var lprojs: [String: URL] = [:]
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where item.pathExtension == "lproj" {
            lprojs[item.lastPathComponent] = item
        }
        let seed = seedEntries(lprojs, table: table, developmentRegion: developmentRegion)
        for language in ["fr", "en"] where lprojs["\(language).lproj"] == nil {
            let url = dir.appendingPathComponent("\(language).lproj")
            if (try? fm.createDirectory(at: url, withIntermediateDirectories: false)) != nil {
                lprojs[url.lastPathComponent] = url
            }
        }
        for (name, lproj) in lprojs {
            guard type(lproj) == .typeDirectory else {
                logger.notice("\(name) isn't a plain folder: no \(table) texts added there")
                continue
            }
            let language = name == "fr.lproj" || name.hasPrefix("fr-") || name.hasPrefix("fr_") ? "fr" : "en"
            guard let additions = strings[language] ?? strings["en"], !additions.isEmpty else { continue }
            let file = lproj.appendingPathComponent("\(table).strings")
            var entries: [String: Any] = [:]
            switch type(file) {
            case nil: entries = seed
            case .typeRegular?:
                guard let read = readTable(file) else {
                    logger.notice("\(name)/\(table).strings unreadable: XSide texts not added there")
                    continue
                }
                entries = read
            default:
                logger.notice("\(name)/\(table).strings isn't a regular file: XSide texts not added there")
                continue
            }
            for (key, text) in additions where !(keepExisting.contains(key) && entries[key] != nil) {
                entries[key] = text
            }
            do {
                try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
                    .write(to: file, options: .atomic)
            } catch {
                logger.notice("\(name)/\(table).strings not written: \(String(describing: error))")
            }
        }
    }

    private static func readTable(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// The app's own copy of the table to start a new file from: Base, English, the development
    /// region, then any other (by name, so the choice is stable). Read before anything is written.
    private static func seedEntries(_ lprojs: [String: URL], table: String, developmentRegion: String?) -> [String: Any] {
        let preferred = ["Base.lproj", "en.lproj"] + (developmentRegion.map { ["\($0).lproj"] } ?? [])
        for name in preferred + lprojs.keys.sorted() {
            guard let lproj = lprojs[name], type(lproj) == .typeDirectory else { continue }
            let file = lproj.appendingPathComponent("\(table).strings")
            if type(file) == .typeRegular, let read = readTable(file) { return read }
        }
        return [:]
    }

    /// The item's own type (a link is not followed); nil when nothing is there.
    private static func type(_ url: URL) -> FileAttributeType? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }
}
