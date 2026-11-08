import Foundation

/// Merges XSide's texts into the `<lang>.lproj/<table>.strings` files of a directory (an app, or
/// its Settings.bundle). Used for the Settings titles and the Info.plist texts (quick actions,
/// local-network reason), which iOS looks up by key in the device's language.
enum LocalizedStrings {
    /// Adds `strings` (language "fr" or "en" -> key -> text) to the table in every existing
    /// `.lproj` of `dir`, creating `fr.lproj` and `en.lproj` when missing. A `.lproj` for another
    /// language gets the English text, since iOS looks keys up in the one localization it picked
    /// and would otherwise show the raw key. Keys in `keepExisting` are left alone when the file
    /// already defines them (the app's own wording wins). Never throws: a file or folder it can't
    /// read, or that is a link, is skipped, so the app is left as it was there.
    static func merge(_ strings: [String: [String: String]], into dir: URL, table: String,
                      keepExisting: Set<String> = []) {
        let fm = FileManager.default
        guard type(dir) == .typeDirectory else { return }
        var lprojs: [String: URL] = [:]
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where item.pathExtension == "lproj" {
            lprojs[item.lastPathComponent] = item
        }
        for language in ["fr", "en"] where lprojs["\(language).lproj"] == nil {
            let url = dir.appendingPathComponent("\(language).lproj")
            if (try? fm.createDirectory(at: url, withIntermediateDirectories: false)) != nil {
                lprojs[url.lastPathComponent] = url
            }
        }
        for (name, lproj) in lprojs {
            guard type(lproj) == .typeDirectory else { continue }
            let language = name == "fr.lproj" || name.hasPrefix("fr-") || name.hasPrefix("fr_") ? "fr" : "en"
            guard let additions = strings[language] ?? strings["en"], !additions.isEmpty else { continue }
            let file = lproj.appendingPathComponent("\(table).strings")
            var entries: [String: Any] = [:]
            switch type(file) {
            case nil: break
            case .typeRegular?:
                guard let data = try? Data(contentsOf: file),
                      let read = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }
                entries = read
            default: continue
            }
            for (key, text) in additions where !(keepExisting.contains(key) && entries[key] != nil) {
                entries[key] = text
            }
            if let out = try? PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0) {
                try? out.write(to: file, options: .atomic)
            }
        }
    }

    /// The item's own type (a link is not followed); nil when nothing is there.
    private static func type(_ url: URL) -> FileAttributeType? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }
}
