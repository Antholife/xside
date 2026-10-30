import Foundation
@testable import XSideCore

struct FakeRunnerError: Error, CustomStringConvertible {
    let command: [String]
    var description: String { "FakeRunner: no stub for \(command.joined(separator: " "))" }
}

final class FakeRunner: CommandRunning, @unchecked Sendable {
    private struct Stub { let executable: String; let firstArg: String?; let result: CommandResult; let effect: (@Sendable ([String]) -> Void)? }
    private let lock = NSLock()
    private var stubs: [Stub] = []
    private var _calls: [[String]] = []
    private var _timeouts: [Duration] = []

    init() {}

    func stub(_ executable: String, firstArg: String? = nil, result: CommandResult,
              effect: (@Sendable ([String]) -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        stubs.append(Stub(executable: executable, firstArg: firstArg, result: result, effect: effect))
    }

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    /// Timeout passed with each call, in call order.
    var timeouts: [Duration] {
        lock.lock(); defer { lock.unlock() }
        return _timeouts
    }

    func run(_ executable: String, _ arguments: [String], cwd: URL?, timeout: Duration) async throws -> CommandResult {
        let match: Stub? = lock.withLock {
            _calls.append([executable] + arguments)
            _timeouts.append(timeout)
            // Most recent matching stub wins.
            return stubs.last(where: { $0.executable == executable && ($0.firstArg == nil || $0.firstArg == arguments.first) })
        }
        if let match { match.effect?(arguments); return match.result }
        throw FakeRunnerError(command: [executable] + arguments)
    }
}
