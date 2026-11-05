import Foundation

/// Keeps an app's CFBundleName to plain characters. iOS refuses notifications to an app whose
/// CFBundleName has special characters ("Notifications are not allowed", UNErrorDomain 1): seen
/// 2026-11-05 with "YouTube +", and reported on Apple's forums for non-English names. The name
/// people see is CFBundleDisplayName, which keeps the original.
public enum BundleName {
    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-")

    /// The plain name to use instead of `name`, nil when `name` is fine as is. Accents are
    /// folded, other characters dropped; when nothing is left, the executable's name.
    public static func safe(_ name: String, executable: String) -> String? {
        guard name.unicodeScalars.contains(where: { !allowed.contains($0) }) else { return nil }
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let kept = String(String.UnicodeScalarView(folded.unicodeScalars.filter { allowed.contains($0) }))
        let collapsed = kept.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        if !collapsed.isEmpty { return collapsed }
        return executable
    }
}
