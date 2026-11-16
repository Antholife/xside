import Testing
@testable import XSideCore

@Suite struct DowngradeTests {
    @Test func detects() {
        #expect(UpdateChecker.isDowngrade(installed: "1.8", candidate: "1.5"))
        #expect(!UpdateChecker.isDowngrade(installed: "1.5", candidate: "1.8"))
        #expect(!UpdateChecker.isDowngrade(installed: "1.8", candidate: "1.8"))
        #expect(!UpdateChecker.isDowngrade(installed: nil, candidate: "1.5"))
        #expect(!UpdateChecker.isDowngrade(installed: "1.8", candidate: nil))
        #expect(!UpdateChecker.isDowngrade(installed: "1.8", candidate: "v3"))
        #expect(!UpdateChecker.isDowngrade(installed: "", candidate: "1.5"))
    }
}
