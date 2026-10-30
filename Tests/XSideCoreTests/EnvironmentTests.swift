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
        let result = await EnvironmentProbe(runner: r, fileExists: { _ in true }, xcodeAccounts: { Self.signedIn }).detect()
        #expect(result == .failure(.xcodeMissing))
    }

    @Test func commandLineToolsOnlyMapsToXcodeMissing() async {
        let r = FakeRunner()
        r.stub("/usr/bin/xcode-select", result: ok("/Library/Developer/CommandLineTools\n"))
        let probe = EnvironmentProbe(runner: r, fileExists: { $0 != "/Library/Developer/CommandLineTools/usr/bin/xcodebuild" },
                                     xcodeAccounts: { Self.signedIn })
        #expect(await probe.detect() == .failure(.xcodeMissing))
    }

    static var signedIn: [String: Any] { ["IDE.Identifiers.Prod": [["identifier": "x"]]] }

    @Test func readsAccountNameFromCertificateOrTeam() {
        #expect(EnvironmentProbe.appleID(fromIdentityName: "Apple Development: me@example.com (AB12CD34EF)") == "me@example.com")
        #expect(EnvironmentProbe.appleID(fromIdentityName: "Apple Development: Jane Doe (AB12CD34EF)") == nil)
        #expect(EnvironmentProbe.personalTeamName(["acct": [["teamName": "Jane Doe", "isFreeProvisioningTeam": true]]]) == "Jane Doe")
        #expect(EnvironmentProbe.personalTeamName(nil) == nil)
    }

    @Test func picksPersonalTeam() {
        let teams: [String: Any] = ["acct": [["teamID": "PAID000001", "isFreeProvisioningTeam": false],
                                             ["teamID": "FREE000001", "isFreeProvisioningTeam": true]]]
        #expect(EnvironmentProbe.personalTeamID(teams) == "FREE000001")
        #expect(EnvironmentProbe.personalTeamID(["acct": [["teamID": "ONLY000001"]]]) == "ONLY000001")
        #expect(EnvironmentProbe.personalTeamID(nil) == nil)
    }

    @Test func detectsSignedInAccount() {
        #expect(EnvironmentProbe.hasSignedInAccount(Self.signedIn) == true)
        #expect(EnvironmentProbe.hasSignedInAccount(["IDE.Identifiers.Prod": [Any]()]) == false)
        #expect(EnvironmentProbe.hasSignedInAccount(nil) == nil)
        #expect(EnvironmentProbe.hasSignedInAccount("garbage") == nil)
    }

    @Test func noAccountMapsToNotSignedInEvenWithCertificate() async {
        let r = FakeRunner()
        r.stub("/usr/bin/xcode-select", result: ok("/Applications/Xcode.app/Contents/Developer\n"))
        r.stub("/usr/bin/security", result: ok(Self.list))
        let result = await EnvironmentProbe(runner: r, fileExists: { _ in true },
                                            xcodeAccounts: { ["IDE.Identifiers.Prod": [Any]()] }).detect()
        #expect(result == .failure(.xcodeNotSignedIn))
    }

    /// An unreadable accounts key (moved in a new Xcode) leaves the decision to the certificate.
    @Test func unknownAccountsFallBackToCertificate() async {
        let r = FakeRunner()
        r.stub("/usr/bin/xcode-select", result: ok("/Applications/Xcode.app/Contents/Developer\n"))
        r.stub("/usr/bin/security", result: ok(Self.list))
        r.stub("/bin/sh", firstArg: "-c", result: ok("subject=UID=X, CN=Apple Development: x (LL), OU=TEAM123456, O=Me, C=US\n"))
        let result = await EnvironmentProbe(runner: r, fileExists: { _ in true }, xcodeAccounts: { nil }).detect()
        #expect((try? result.get())?.teamID == "TEAM123456")

        let none = FakeRunner()
        none.stub("/usr/bin/xcode-select", result: ok("/Applications/Xcode.app/Contents/Developer\n"))
        none.stub("/usr/bin/security", result: ok("     0 valid identities found\n"))
        #expect(await EnvironmentProbe(runner: none, fileExists: { _ in true }, xcodeAccounts: { nil }).detect()
                == .failure(.noSigningIdentity))
    }

    @Test func noIdentityMapsError() async {
        let r = FakeRunner()
        r.stub("/usr/bin/xcode-select", result: ok("/Applications/Xcode.app/Contents/Developer\n"))
        r.stub("/usr/bin/security", result: ok("     0 valid identities found\n"))
        let result = await EnvironmentProbe(runner: r, fileExists: { _ in true }, xcodeAccounts: { Self.signedIn }).detect()
        #expect(result == .failure(.noSigningIdentity))
    }

    @Test func detectsFullEnvironment() async {
        let r = FakeRunner()
        r.stub("/usr/bin/xcode-select", result: ok("/Applications/Xcode.app/Contents/Developer\n"))
        r.stub("/usr/bin/security", result: ok(Self.list))
        r.stub("/bin/sh", firstArg: "-c", result: ok("subject=UID=X, CN=Apple Development: x (LL), OU=TEAM123456, O=Me, C=US\n"))
        let result = await EnvironmentProbe(runner: r, fileExists: { _ in true }, xcodeAccounts: { Self.signedIn }).detect()
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
        _ = await EnvironmentProbe(runner: r, fileExists: { _ in true }, xcodeAccounts: { Self.signedIn }).detect()
        let cmd = r.calls.last?.last ?? ""
        #expect(cmd.contains("'Apple Development: O'\\''Neil (AB)'"))
    }
}
