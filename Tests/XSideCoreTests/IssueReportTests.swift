import Testing
import Foundation
@testable import XSideCore

struct IssueReportTests {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    /// Blank issues are off on the repo: the bug form, its fields filled in by id.
    @Test func fillsTheBugForm() throws {
        let url = IssueReport.url(template: "bug_report.yml",
                                  fields: [("version", "1.0.5 (130)"), ("logs", "Line & more ? #1 + 2")], cut: "logs")
        #expect(url.absoluteString.hasPrefix("https://github.com/Antholife/xside/issues/new?"))
        #expect(query(url)["template"] == "bug_report.yml")
        #expect(query(url)["version"] == "1.0.5 (130)")
        #expect(query(url)["logs"] == "Line & more ? #1 + 2")
    }

    /// GitHub refuses very long links: the body is cut, keeping its start, and says so.
    @Test func longBodiesAreCut() {
        let body = String(repeating: "é", count: 20_000)
        let url = IssueReport.url(template: "bug_report.yml", fields: [("version", "1.0.5"), ("logs", body)], cut: "logs")
        #expect(url.absoluteString.count <= IssueReport.maxURLLength)
        #expect(query(url)["version"] == "1.0.5")
        let sent = query(url)["logs"] ?? ""
        #expect(sent.hasPrefix("ééé"))
        #expect(sent.hasSuffix(IssueReport.cutMarker))
    }

    /// Review I3: the public issue doesn't list which apps the person sideloads.
    @Test func masksTheAppsInPublicText() {
        let text = "install com.google.ios.youtube as com.google.ios.youtube.TEAM on <device-1>; com.x.app done"
        let masked = IssueReport.maskApps(text, apps: [["com.google.ios.youtube", "com.google.ios.youtube.TEAM"], ["com.x.app"]])
        #expect(masked == "install <app-1> as <app-1> on <device-1>; <app-2> done")
    }

    /// The last lines matter most in a log.
    @Test func keepsTheLastLines() {
        let log = (1...100).map { "line \($0)" }.joined(separator: "\n")
        #expect(IssueReport.tail(log, lines: 3) == "line 98\nline 99\nline 100")
        #expect(IssueReport.tail("a\nb", lines: 5) == "a\nb")
    }
}
