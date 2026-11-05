import Testing
import Foundation
@testable import XSideCore

struct IssueReportTests {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func opensANewIssueOnTheRepo() throws {
        let url = IssueReport.url(title: "Bug: install fails", body: "Line & more ? #1")
        #expect(url.absoluteString.hasPrefix("https://github.com/Antholife/xside/issues/new?"))
        #expect(query(url)["title"] == "Bug: install fails")
        #expect(query(url)["body"] == "Line & more ? #1")
    }

    /// GitHub refuses very long links: the body is cut, keeping its start, and says so.
    @Test func longBodiesAreCut() {
        let body = String(repeating: "é", count: 20_000)
        let url = IssueReport.url(title: "T", body: body)
        #expect(url.absoluteString.count <= IssueReport.maxURLLength)
        let sent = query(url)["body"] ?? ""
        #expect(sent.hasPrefix("ééé"))
        #expect(sent.hasSuffix(IssueReport.cutMarker))
    }

    /// The last lines matter most in a log.
    @Test func keepsTheLastLines() {
        let log = (1...100).map { "line \($0)" }.joined(separator: "\n")
        #expect(IssueReport.tail(log, lines: 3) == "line 98\nline 99\nline 100")
        #expect(IssueReport.tail("a\nb", lines: 5) == "a\nb")
    }
}
