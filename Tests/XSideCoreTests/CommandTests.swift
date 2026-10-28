import Testing
import Foundation
@testable import XSideCore

@Test func processRunnerCapturesOutput() async throws {
    let r = try await ProcessRunner().run("/bin/echo", ["hi"], cwd: nil)
    #expect(r.status == 0)
    #expect(String(data: r.stdout, encoding: .utf8) == "hi\n")
}

@Test func processRunnerHandlesLargeOutput() async throws {
    let r = try await ProcessRunner().run("/bin/sh", ["-c", "/usr/bin/yes | head -c 2000000"], cwd: nil)
    #expect(r.status == 0)
    #expect(r.stdout.count == 2_000_000)
}

@Test func fakeRunnerRecordsAndFailsWithoutStub() async throws {
    let f = FakeRunner()
    f.stub("/usr/bin/xcrun", firstArg: "devicectl", result: CommandResult(status: 0, stdout: Data(), stderr: ""))
    _ = try await f.run("/usr/bin/xcrun", ["devicectl", "x"], cwd: nil)
    await #expect(throws: FakeRunnerError.self) { try await f.run("/usr/bin/xcrun", ["other"], cwd: nil) }
    #expect(f.calls.first == ["/usr/bin/xcrun", "devicectl", "x"])
}

@Test func errorKeyIgnoresPayload() {
    #expect(XSideError.invalidIPA("a").key == XSideError.invalidIPA("b").key)
    #expect(XSideError.commandFailed(tool: "x", status: 1).key == "commandFailed")
}
