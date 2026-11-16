import Testing
import Foundation
@testable import XSideCore

/// Plays devicectl for the app's data container: the listing writes `--json-output`.
private final class ContainerRunner: CommandRunning, @unchecked Sendable {
    var listing: Data?
    var result = CommandResult(status: 0, stdout: Data(), stderr: "")
    private let lock = NSLock()
    private(set) var calls: [[String]] = []

    func run(_ executable: String, _ arguments: [String], cwd: URL?, timeout: Duration) async throws -> CommandResult {
        lock.withLock { calls.append(arguments) }
        if arguments.starts(with: ["devicectl", "device", "info", "files"]) {
            guard result.status == 0 else { return result }
            if let listing, let i = arguments.firstIndex(of: "--json-output") {
                try listing.write(to: URL(fileURLWithPath: arguments[i + 1]))
            }
            return result
        }
        return result
    }
}

@Suite struct AppDataContainerTests {
    private func container(_ runner: ContainerRunner) -> AppDataContainer { AppDataContainer(runner: runner) }

    @Test func listFiles_parsesEntriesWithSizeAndDate() async throws {
        let runner = ContainerRunner()
        let files: [[String: Any]] = [
            ["relativePath": "Documents", "resources": ["isDirectory": true], "metadata": [:]],
            ["relativePath": "Documents/a.db", "resources": ["isDirectory": false],
             "metadata": ["size": 1234, "lastModDate": "2026-11-09T09:00:00.000Z"]],
        ]
        runner.listing = try JSONSerialization.data(withJSONObject: ["result": ["files": files]])
        let entries = try #require(try await container(runner).listFiles(signedBundleID: "com.x.app.T1", deviceID: "D1"))
        #expect(entries.count == 2)
        #expect(entries[0].isDirectory)
        #expect(entries[1].relativePath == "Documents/a.db")
        #expect(entries[1].size == 1234)
        #expect(entries[1].modified == ISO8601DateFormatter().date(from: "2026-11-09T09:00:00Z"))
        #expect(runner.calls[0] == ["devicectl", "device", "info", "files", "--device", "D1", "--domain-type", "appDataContainer",
                                    "--domain-identifier", "com.x.app.T1", "--json-output", runner.calls[0].last!])
    }

    @Test func listFiles_returnsNilWhenListingUnavailable() async throws {
        let runner = ContainerRunner()
        runner.result = CommandResult(status: 1, stdout: Data(), stderr: "ERROR: not supported")
        #expect(try await container(runner).listFiles(signedBundleID: "b", deviceID: "D1") == nil)
        let ok = ContainerRunner()
        ok.listing = Data("{\"result\":{}}".utf8)
        #expect(try await container(ok).listFiles(signedBundleID: "b", deviceID: "D1") == nil)
    }

    @Test func pull_buildsCopyFromArgs() async throws {
        let runner = ContainerRunner()
        try await container(runner).pull(signedBundleID: "b.T", deviceID: "D1", relativePath: "Documents/a.db", to: URL(fileURLWithPath: "/tmp/x/a.db"))
        #expect(runner.calls == [["devicectl", "device", "copy", "from", "--device", "D1", "--domain-type", "appDataContainer",
                                  "--domain-identifier", "b.T", "--source", "Documents/a.db", "--destination", "/tmp/x/a.db"]])
    }

    @Test func push_buildsCopyToArgs() async throws {
        let runner = ContainerRunner()
        try await container(runner).push(signedBundleID: "b.T", deviceID: "D1", from: URL(fileURLWithPath: "/tmp/x/a.db"), relativePath: "Documents/a.db")
        #expect(runner.calls == [["devicectl", "device", "copy", "to", "--device", "D1", "--domain-type", "appDataContainer",
                                  "--domain-identifier", "b.T", "--source", "/tmp/x/a.db", "--destination", "Documents/a.db"]])
    }

    @Test func pull_failureThrows() async {
        let runner = ContainerRunner()
        runner.result = CommandResult(status: 1, stdout: Data(), stderr: "ERROR: The device is not currently reachable")
        await #expect(throws: XSideError.self) {
            try await container(runner).pull(signedBundleID: "b", deviceID: "D1", relativePath: "a", to: URL(fileURLWithPath: "/tmp/a"))
        }
    }

    @Test func terminate_buildsArgsAndToleratesNotRunning() async throws {
        let runner = ContainerRunner()
        runner.result = CommandResult(status: 1, stdout: Data(), stderr: "ERROR: Failed to terminate process: no process found with bundle identifier b.T (CoreDeviceError 1)")
        try await container(runner).terminate(signedBundleID: "b.T", deviceID: "D1")
        #expect(runner.calls == [["devicectl", "device", "process", "terminate", "--device", "D1", "b.T"]])
    }

    @Test func terminate_toleratesNotRunning() async throws {
        let runner = ContainerRunner()
        runner.result = CommandResult(status: 1, stdout: Data(), stderr: "ERROR: process not found")
        try await container(runner).terminate(signedBundleID: "b.T", deviceID: "D1")
    }
}
