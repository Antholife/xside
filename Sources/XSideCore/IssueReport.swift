import Foundation

/// A link that opens a new GitHub issue on XSide's repo, filled in. Files can't be attached
/// through a link: the diagnostics archive is dragged in by the person.
public enum IssueReport {
    public static let newIssue = "https://github.com/Antholife/xside/issues/new"
    /// GitHub (and browsers) refuse longer links.
    public static let maxURLLength = 7_500
    public static let cutMarker = "\n…"

    /// The link, with `body` cut (from the end) until it fits `maxURLLength`.
    public static func url(title: String, body: String) -> URL {
        var text = body
        while true {
            var components = URLComponents(string: newIssue)!
            components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: text)]
            // "+" and "&" in values must not read as separators.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
            let url = components.url!
            if url.absoluteString.count <= maxURLLength || text.isEmpty { return url }
            let base = text.hasSuffix(cutMarker) ? String(text.dropLast(cutMarker.count)) : text
            // Shrunk in proportion to how much too long it is (encoded characters vary in length).
            let keep = Int(Double(base.count) * Double(maxURLLength) / Double(url.absoluteString.count) * 0.95)
            text = String(base.prefix(min(keep, base.count - 1))) + cutMarker
        }
    }

    /// The last `lines` lines of `text`.
    public static func tail(_ text: String, lines: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
