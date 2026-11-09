import Foundation

/// "Request a fix": a new GitHub issue on the idea form (.github/ISSUE_TEMPLATE/feature_request.yml),
/// its title prefilled with the app's name only (what the person sees on the device), never a
/// bundle id, a device name or anything else of theirs.
public enum FixRequest {
    public static let newIssue = "https://github.com/Antholife/xside/issues/new"
    public static let template = "feature_request.yml"
    /// Longest app name kept in the title.
    static let maxNameLength = 60

    /// The title: "Fix request" or "Fix request: <app>" (the app's display name, one line,
    /// trimmed and capped).
    public static func title(appName: String?) -> String {
        let name = (appName ?? "")
            .components(separatedBy: .newlines).joined(separator: " ")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "Fix request" }
        return "Fix request: " + String(name.prefix(maxNameLength))
    }

    public static func url(appName: String?) -> URL {
        var c = URLComponents(string: newIssue)!
        c.queryItems = [URLQueryItem(name: "template", value: template),
                        URLQueryItem(name: "title", value: title(appName: appName))]
        // `+`, `&`, `=` and `#` in a name must not change the query.
        c.percentEncodedQuery = c.queryItems!.map { item in
            "\(item.name)=\(item.value!.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!)"
        }.joined(separator: "&")
        return c.url!
    }
}

extension FixRequest {
    /// What the crash request says of the installation, besides the diagnosis.
    public struct CrashFacts: Equatable, Sendable {
        public var appVersion: String?
        public var iOSVersion: String?
        public var xsideVersion: String
        /// XSide's module was in the app.
        public var xsideModule: Bool
        /// iPhone Duo compatibility was on; `duoModule`: with the compatibility module.
        public var duoCompatibility: Bool
        public var duoModule: Bool
        public var iCloudSignedOut: Bool

        public init(appVersion: String?, iOSVersion: String?, xsideVersion: String, xsideModule: Bool,
                    duoCompatibility: Bool, duoModule: Bool, iCloudSignedOut: Bool) {
            self.appVersion = appVersion
            self.iOSVersion = iOSVersion
            self.xsideVersion = xsideVersion
            self.xsideModule = xsideModule
            self.duoCompatibility = duoCompatibility
            self.duoModule = duoModule
            self.iCloudSignedOut = iCloudSignedOut
        }
    }

    /// The crash, for the request (English, technical): cause, the library it names, exception,
    /// top frames, iOS and XSide versions, the fixes that were on. Everything goes through
    /// `CrashLogSanitizer` (with `secrets`: team id, device id and name…) and the app's
    /// identifiers (`appIDs`: original and signed bundle ids) become `<app>`.
    public static func crashDetails(_ d: CrashDiagnosis, facts f: CrashFacts, secrets: [String], appIDs: [String]) -> String {
        var lines = ["Cause: \(d.cause.rawValue)"]
        if let subject = d.subject { lines.append("Library: \(subject)") }
        if let library = d.library { lines.append("Expected in: \(library)") }
        let exception = [d.exceptionType, d.signal].compactMap { $0 }.joined(separator: " ")
        if !exception.isEmpty { lines.append("Exception: \(exception)") }
        if let termination = d.termination { lines.append("Termination: \(termination)") }
        if let v = f.appVersion ?? d.appVersion { lines.append("App version: \(v)") }
        lines.append("iOS: \(f.iOSVersion ?? "?")")
        lines.append("XSide: \(f.xsideVersion)")
        func onOff(_ on: Bool) -> String { on ? "on" : "off" }
        lines.append("XSide module: \(onOff(f.xsideModule))")
        lines.append("iPhone Duo compatibility: \(onOff(f.duoCompatibility))\(f.duoCompatibility && f.duoModule ? " (compatibility module)" : "")")
        lines.append("Simulate signed-out iCloud: \(onOff(f.iCloudSignedOut))")
        if !d.topFrames.isEmpty {
            lines.append("Top frames:")
            lines += d.topFrames.enumerated().map { "  \($0.offset)  \($0.element)" }
        }
        let text = CrashLogSanitizer.sanitize(lines.joined(separator: "\n"), secrets: secrets.filter { !$0.isEmpty })
        return IssueReport.maskApps(text, apps: [appIDs]).replacingOccurrences(of: "<app-1>", with: "<app>")
    }

    /// The request from a crash: the idea form, titled "Fix request: <app>", the person's own words
    /// to write (`prompt`, in their language) and the details in a code block (cut first when the
    /// link gets too long).
    public static func crashURL(appName: String?, prompt: String, details: String) -> URL {
        IssueReport.url(template: template,
                        fields: [("title", title(appName: appName)), ("idea", prompt),
                                 ("more", "```\n\(details)\n```")],
                        cut: "more")
    }
}
