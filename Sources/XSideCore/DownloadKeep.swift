import Foundation

/// Naming for the copies XSide keeps of the `.ipa` files it downloads, when the person turned that on
/// (Réglages > Fichiers téléchargés). Pure, so it is unit tested; the copy itself lives in `AppModel`.
public enum DownloadKeep {
    /// A file name for a kept download: "<app>_<version>.<ext>", the app name and tag sanitized to a
    /// safe, single-line name. When the app name is blank, the asset name is used but still reduced to
    /// a safe last-path component (asset names come from the release and are never trusted).
    public static func fileName(appName: String?, tag: String, assetName: String) -> String {
        let app = sanitize(appName ?? "")
        guard !app.isEmpty else { return safeName(assetName) }
        let version = sanitize(UpdateChecker.displayTag(tag))
        let ext = sanitize((assetName as NSString).pathExtension)
        let base = version.isEmpty ? app : "\(app)_\(version)"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// A single, safe file name from an untrusted proposal (e.g. a release asset name): its last path
    /// component only, path separators and control characters stripped, and `.`/`..`/empty mapped to
    /// `fallback`. Never contains a `/` or `\`, so appending it to a folder cannot escape that folder.
    public static func safeName(_ proposed: String, fallback: String = "download.ipa") -> String {
        let cleaned = sanitize((proposed as NSString).lastPathComponent)
        return (cleaned.isEmpty || cleaned == "." || cleaned == "..") ? fallback : cleaned
    }

    /// `name` made unique against `existing` by inserting " (2)", " (3)"… before the extension.
    public static func disambiguate(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// Replaces path-unsafe and control characters with a space, collapses runs of spaces, and trims.
    private static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let mapped = String(s.unicodeScalars.map { bad.contains($0) ? " " : Character($0) })
        let collapsed = mapped.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }
}
