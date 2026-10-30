import Foundation
@testable import XSideCore

/// Sends `/usr/bin/codesign` to a fake and everything else to the real ProcessRunner.
struct RoutingRunner: CommandRunning {
    let fake: FakeRunner
    let real = ProcessRunner()

    func run(_ executable: String, _ arguments: [String], cwd: URL?, timeout: Duration) async throws -> CommandResult {
        if executable == "/usr/bin/codesign" { return try await fake.run(executable, arguments, cwd: cwd, timeout: timeout) }
        return try await real.run(executable, arguments, cwd: cwd, timeout: timeout)
    }
}
