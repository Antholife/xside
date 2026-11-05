import Foundation

/// A link that opens a new GitHub issue on XSide's repo from one of its issue forms, with fields
/// filled in (`?template=<form>&<field id>=<value>`: blank issues are off on the repo). Files
/// can't be attached through a link: the diagnostics archive is dragged in by the person.
public enum IssueReport {
    public static let newIssue = "https://github.com/Antholife/xside/issues/new"
    /// GitHub (and browsers) refuse longer links.
    public static let maxURLLength = 7_500
    public static let cutMarker = "\n…"

    /// The link, with the `cut` field shortened (from its end) until it fits `maxURLLength`.
    public static func url(template: String, fields: [(id: String, value: String)], cut: String) -> URL {
        var values = fields
        while true {
            var components = URLComponents(string: newIssue)!
            components.queryItems = [URLQueryItem(name: "template", value: template)]
                + values.map { URLQueryItem(name: $0.id, value: $0.value) }
            // "+" must not read as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            let url = components.url!
            guard url.absoluteString.count > maxURLLength,
                  let index = values.firstIndex(where: { $0.id == cut }), !values[index].value.isEmpty else { return url }
            let text = values[index].value
            let base = text.hasSuffix(cutMarker) ? String(text.dropLast(cutMarker.count)) : text
            // Shrunk in proportion to how much too long it is (encoded characters vary in length).
            let keep = Int(Double(base.count) * Double(maxURLLength) / Double(url.absoluteString.count) * 0.95)
            values[index].value = keep <= 0 ? "" : String(base.prefix(min(keep, base.count - 1))) + cutMarker
        }
    }

    /// The last `lines` lines of `text`.
    public static func tail(_ text: String, lines: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
