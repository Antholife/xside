import Foundation

/// A link that opens a new GitHub issue on XSide's repo from one of its issue forms, with fields
/// filled in (`?template=<form>&<field id>=<value>`: blank issues are off on the repo). Files
/// can't be attached through a link: the diagnostics archive is dragged in by the person.
public enum IssueReport {
    public static let newIssue = "https://github.com/Antholife/xside/issues/new"
    /// GitHub (and browsers) refuse longer links.
    public static let maxURLLength = 7_500
    public static let cutMarker = "\n…"
    private static let fence = "```"

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
            let base = Self.uncut(text)
            // Shrunk in proportion to how much too long it is (encoded characters vary in length).
            let keep = Int(Double(base.count) * Double(maxURLLength) / Double(url.absoluteString.count) * 0.95)
            values[index].value = keep <= 0 ? "" : Self.cut(String(base.prefix(min(keep, base.count - 1))))
        }
    }

    /// `text` cut short: the marker, and the code block it ends in closed again.
    private static func cut(_ text: String) -> String {
        let open = text.components(separatedBy: fence).count % 2 == 0
        return text + cutMarker + (open ? "\n" + fence : "")
    }

    /// The text before `cut` added its ending.
    private static func uncut(_ text: String) -> String {
        if text.hasSuffix(cutMarker + "\n" + fence) { return String(text.dropLast(cutMarker.count + 1 + fence.count)) }
        if text.hasSuffix(cutMarker) { return String(text.dropLast(cutMarker.count)) }
        return text
    }

    /// `text` with each app's identifiers (`apps[n]`, any order) replaced by `<app-n+1>`, longest
    /// first so a signed id ("com.x.TEAM") isn't half-replaced by its original ("com.x").
    public static func maskApps(_ text: String, apps: [[String]]) -> String {
        let pairs = apps.enumerated().flatMap { index, ids in ids.map { ($0, "<app-\(index + 1)>") } }
            .filter { !$0.0.isEmpty }
            .sorted { $0.0.count > $1.0.count }
        return pairs.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    /// The last `lines` lines of `text`.
    public static func tail(_ text: String, lines: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
