import Foundation
@testable import XSideCore

struct FakeRunnerError: Error, CustomStringConvertible {
    let command: [String]
    var description: String { "FakeRunner: no stub for \(command.joined(separator: " "))" }
}

final class FakeRunner: CommandRunning, @unchecked Sendable {
    private struct Stub { let executable: String; let firstArg: String?; let result: CommandResult }
    private let lock = NSLock()
    private var stubs: [Stub] = []
    private var _calls: [[String]] = []

    init() {}

    func stub(_ executable: String, firstArg: String? = nil, result: CommandResult) {
        lock.lock(); defer { lock.unlock() }
        stubs.append(Stub(executable: executable, firstArg: firstArg, result: result))
    }

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func run(_ executable: String, _ arguments: [String], cwd: URL?) async throws -> CommandResult {
        let match: CommandResult? = lock.withLock {
            _calls.append([executable] + arguments)
            // Most recent matching stub wins.
            return stubs.last(where: { $0.executable == executable && ($0.firstArg == nil || $0.firstArg == arguments.first) })?.result
        }
        if let match { return match }
        throw FakeRunnerError(command: [executable] + arguments)
    }
}
