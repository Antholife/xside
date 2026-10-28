import Testing
import Foundation
@testable import XSideCore

private func ok(_ s: String) -> CommandResult {
    CommandResult(status: 0, stdout: Data(s.utf8), stderr: "")
}

struct EnvironmentTests {
    static let sha1 = "3F2A9C0B7D1E4F5A6B8C9D0E1F2A3B4C5D6E7F80"
    static let list = """
      1) \(sha1) "Apple Development: x@y.z (LL6YVU88MW)"
      2) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Distribution: Other (ZZ9YXW77VU)"
         2 valid identities found
    """

    @Test func parsesIdentityList() {
        let ids = EnvironmentProbe.parseIdentities(Self.list)
        #expect(ids.count == 2)
        #expect(ids[0].sha1 == Self.sha1)
        #expect(ids[0].name.hasPrefix("Apple Development:"))
    }

    @Test func extractsTeamFromOU() {
        #expect(EnvironmentProbe.teamID(fromSubject: "subject=UID=X, CN=Apple Development: a (B), OU=TEAM123456, O=Me, C=US") == "TEAM123456")
        #expect(EnvironmentProbe.teamID(fromSubject: "subject= /UID=X/CN=Apple Development: a (B)/OU=TEAM123456/O=Me/C=US") == "TEAM123456")
        #expect(EnvironmentProbe.teamID(fromSubject: "subject=CN=nothing") == nil)
    }

    @Test func missingXcodeMapsError() async {
        let r = FakeRunner()
        r.stub("/usr/bin/xcode-select", result: CommandResult(status: 2, stdout: Data(), stderr: "error"))
        let result = await EnvironmentProbe(runner: r).detect()
        #expect(result == .failure(.xcodeMissing))
    }

    @Test func noIdentityMapsError() async {
        let r = FakeRunner()
        r.stub("/usr/bin/xcode-select", result: ok("/Applications/Xcode.app/Contents/Developer\n"))
        r.stub("/usr/bin/security", result: ok("     0 valid identities found\n"))
        let result = await EnvironmentProbe(runner: r).detect()
        #expect(result == .failure(.noSigningIdentity))
    }

    @Test func detectsFullEnvironment() async {
        let r = FakeRunner()
        r.stub("/usr/bin/xcode-select", result: ok("/Applications/Xcode.app/Contents/Developer\n"))
        r.stub("/usr/bin/security", result: ok(Self.list))
        r.stub("/bin/sh", firstArg: "-c", result: ok("subject=UID=X, CN=Apple Development: x (LL), OU=TEAM123456, O=Me, C=US\n"))
        let result = await EnvironmentProbe(runner: r).detect()
        #expect(result == .success(SigningEnvironment(
            developerDir: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
            identitySHA1: Self.sha1,
            identityName: "Apple Development: x@y.z (LL6YVU88MW)",
            teamID: "TEAM123456")))
    }

    @Test func shellQuotesApostrophes() async {
        let r = FakeRunner()
        r.stub("/usr/bin/xcode-select", result: ok("/X\n"))
        r.stub("/usr/bin/security", result: ok("  1) \(Self.sha1) \"Apple Development: O'Neil (AB)\"\n"))
        r.stub("/bin/sh", firstArg: "-c", result: ok("subject=OU=T1\n"))
        _ = await EnvironmentProbe(runner: r).detect()
        let cmd = r.calls.last?.last ?? ""
        #expect(cmd.contains("'Apple Development: O'\\''Neil (AB)'"))
    }
}
