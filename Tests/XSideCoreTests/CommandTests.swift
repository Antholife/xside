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
    #expect(XSideError.recordNotFound.key == "recordNotFound")
}

@Test func processRunnerStopsAtTimeout() async throws {
    let start = ContinuousClock.now
    await #expect(throws: XSideError.timedOut(tool: "sleep")) {
        try await ProcessRunner().run("/bin/sleep", ["5"], cwd: nil, timeout: .milliseconds(300))
    }
    #expect(ContinuousClock.now - start < .seconds(2))
}

@Test func processRunnerKillsWhatIgnoresSIGTERM() async throws {
    // The shell ignores SIGTERM and keeps respawning children: SIGKILL to the group after the grace.
    let start = ContinuousClock.now
    do {
        _ = try await ProcessRunner().run("/bin/sh", ["-c", "trap '' TERM; while :; do /bin/sleep 1; done"], cwd: nil,
                                          timeout: .milliseconds(300))
        Issue.record("expected timedOut")
    } catch let error as XSideError {
        #expect(error.key == "timedOut")
    }
    #expect(ContinuousClock.now - start < .seconds(8))
}

@Test func processRunnerStopsTheWholeProcessGroup() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xside-pg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let pidFile = dir.appendingPathComponent("pid")
    // A background grandchild that would outlive its parent, holding the pipes.
    await #expect(throws: XSideError.timedOut(tool: "sleep")) {
        try await ProcessRunner().run("/bin/sh", ["-c", "/bin/sleep 30 & echo $! > '\(pidFile.path)'; wait"],
                                      cwd: nil, timeout: .milliseconds(500))
    }
    let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    var gone = false
    for _ in 0..<40 where !gone {
        gone = kill(pid, 0) == -1 && errno == ESRCH
        if !gone { try await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(gone)
}

@Test func processRunnerDoesNotWaitForeverOnInheritedPipes() async throws {
    // The shell exits at once; its background child keeps stdout open for 30 s.
    let start = ContinuousClock.now
    let r = try await ProcessRunner().run("/bin/sh", ["-c", "echo hi; /bin/sleep 30 &"], cwd: nil, timeout: .seconds(60))
    #expect(r.status == 0)
    #expect(String(decoding: r.stdout, as: UTF8.self) == "hi\n")
    #expect(ContinuousClock.now - start < .seconds(8))
}

@Test func processRunnerReportsExitCodeAndCwd() async throws {
    let r = try await ProcessRunner().run("/bin/sh", ["-c", "pwd; exit 3"], cwd: URL(fileURLWithPath: "/usr"))
    #expect(r.status == 3)
    #expect(String(decoding: r.stdout, as: UTF8.self) == "/usr\n")
    await #expect(throws: (any Error).self) { try await ProcessRunner().run("/nonexistent/tool", [], cwd: nil) }
}

@Test func processRunnerStopsOnCancellation() async throws {
    let start = ContinuousClock.now
    let task = Task { try await ProcessRunner().run("/bin/sleep", ["5"], cwd: nil, timeout: .seconds(60)) }
    try await Task.sleep(for: .milliseconds(200))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(ContinuousClock.now - start < .seconds(2))
}

@Test func processRunnerNamesToolBehindXcrun() {
    #expect(ProcessRunner.toolName("/usr/bin/xcrun", ["devicectl", "list"]) == "devicectl")
    #expect(ProcessRunner.toolName("/usr/bin/codesign", ["-f"]) == "codesign")
    #expect(ProcessRunner.toolName("/bin/sh", ["-c", "/usr/bin/security find-certificate -p | openssl"]) == "security")
}

@Test func toolsGetTheirOwnTimeouts() async throws {
    let runner = FakeRunner()
    runner.stub("/usr/bin/xcrun", result: CommandResult(status: 0, stdout: Data(), stderr: ""))
    runner.stub("/usr/bin/script", result: CommandResult(status: 0, stdout: Data(), stderr: ""))
    runner.stub("/usr/bin/codesign", result: CommandResult(status: 0, stdout: Data(), stderr: ""))
    try await Installer(runner: runner).install(app: URL(fileURLWithPath: "/tmp/Fake.app"), deviceID: "X")
    try await DeviceService(runner: runner).pair("X")
    _ = try await runner.run("/usr/bin/codesign", [], cwd: nil)
    #expect(runner.timeouts == [CommandTimeout.deviceInstall, CommandTimeout.deviceQuery, CommandTimeout.standard])
}

@Test func processRunnerAppliesEnvironmentOverrides() async throws {
    let runner = ProcessRunner(environment: { ["DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer"] })
    let r = try await runner.run("/bin/sh", ["-c", "printf %s \"$DEVELOPER_DIR\"; printf ' %s' \"${HOME:+home}\""], cwd: nil)
    #expect(String(decoding: r.stdout, as: UTF8.self) == "/Applications/Xcode-beta.app/Contents/Developer home")
}

@Test func environmentOverridesReplaceInheritedValues() {
    let merged = ProcessRunner.environment(base: ["PATH=/usr/bin", "DEVELOPER_DIR=/old", "EMPTY="],
                                           overrides: ["DEVELOPER_DIR": "/new", "XSIDE": "1"])
    #expect(merged == ["PATH=/usr/bin", "EMPTY=", "DEVELOPER_DIR=/new", "XSIDE=1"])
    #expect(ProcessRunner.environment(base: ["A=1"], overrides: [:]) == ["A=1"])
}

@Test func taskDeveloperDirWinsOverTheRunners() async throws {
    let runner = ProcessRunner(environment: { ["DEVELOPER_DIR": "/app/choice"] })
    let r = try await CommandEnvironment.withDeveloperDir(URL(fileURLWithPath: "/job/snapshot")) {
        try await runner.run("/bin/sh", ["-c", "printf %s \"$DEVELOPER_DIR\""], cwd: nil)
    }
    #expect(String(decoding: r.stdout, as: UTF8.self) == "/job/snapshot")
}
