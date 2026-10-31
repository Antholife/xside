import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public init(status: Int32, stdout: Data, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Deadlines per tool. A tool that hangs (device gone mid-transfer, Xcode waiting on a dialog)
/// is stopped and reported as `XSideError.timedOut` instead of blocking its job forever.
public enum CommandTimeout {
    /// `devicectl list devices`, `devicectl manage pair`.
    public static let deviceQuery: Duration = .seconds(45)
    /// `devicectl device install app` (a large app over Wi-Fi).
    public static let deviceInstall: Duration = .seconds(10 * 60)
    /// `xcodebuild` provisioning of the template project.
    public static let xcodebuild: Duration = .seconds(8 * 60)
    /// codesign, ditto, security, openssl, sips, xcode-select and anything not listed.
    public static let standard: Duration = .seconds(3 * 60)
    /// The app icon extraction helper.
    public static let iconHelper: Duration = .seconds(15)
}

public protocol CommandRunning: Sendable {
    /// `executable` is an absolute path, e.g. `/usr/bin/xcrun`. The process is stopped once
    /// `timeout` elapses (throwing `XSideError.timedOut`) or when the calling task is cancelled.
    func run(_ executable: String, _ arguments: [String], cwd: URL?, timeout: Duration) async throws -> CommandResult
}

extension CommandRunning {
    /// Runs with `CommandTimeout.standard`.
    public func run(_ executable: String, _ arguments: [String], cwd: URL?) async throws -> CommandResult {
        try await run(executable, arguments, cwd: cwd, timeout: CommandTimeout.standard)
    }
}

/// Environment variables for the subprocesses started by the current task (and its child tasks),
/// on top of the runner's own overrides. A job sets `DEVELOPER_DIR` once, when it starts, so all
/// its tools use the same Xcode even if the app's choice changes meanwhile.
public enum CommandEnvironment {
    @TaskLocal public static var overrides: [String: String] = [:]

    /// Runs `body` with every subprocess using `developerDir` as `DEVELOPER_DIR`.
    nonisolated(nonsending) public static func withDeveloperDir<T>(
        _ developerDir: URL, _ body: nonisolated(nonsending) () async throws -> T) async rethrows -> T {
        try await $overrides.withValue(overrides.merging(["DEVELOPER_DIR": developerDir.path]) { $1 }, operation: body)
    }
}

/// Collects data appended from a readability handler.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Lifecycle of one run, shared by the exit waiter, the deadline and the cancellation handler.
/// Every transition happens under the lock, and the continuation is resumed once.
///
/// The child leads its own process group (pgid == pid), so a stop reaches what it spawned too
/// (xcodebuild's helpers, the `security | openssl` pipeline). The leader is signalled only while
/// it isn't reaped (`exited` is set under the lock before `waitpid`), so its pid can't have been
/// reused. The SIGKILL after the grace targets the group even once the leader is gone: a group id
/// isn't reused while any member lives.
private final class RunState: @unchecked Sendable {
    enum Stop { case timedOut, cancelled }

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var exited = false
    private var stop: Stop?
    private var continuation: CheckedContinuation<CommandResult, any Error>?

    func setContinuation(_ c: CheckedContinuation<CommandResult, any Error>) {
        lock.withLock { continuation = c }
    }

    /// The process started. A stop requested before that (cancellation) is applied now: true
    /// when SIGTERM was sent.
    func launched(_ pid: pid_t) -> Bool {
        lock.withLock {
            self.pid = pid
            guard stop != nil, !exited else { return false }
            killpg(pid, SIGTERM)
            return true
        }
    }

    /// Called once the leader exited, before it is reaped.
    func markExited() -> Stop? {
        lock.withLock { exited = true; return stop }
    }

    /// Records the first stop reason and sends SIGTERM to the group if the leader runs. False when
    /// it already exited or another stop came first.
    func requestStop(_ reason: Stop) -> Bool {
        lock.withLock {
            guard stop == nil, !exited else { return false }
            stop = reason
            if pid > 0 { killpg(pid, SIGTERM) }
            return true
        }
    }

    /// SIGTERM now, SIGKILL to the group after `grace`.
    func stop(_ reason: Stop, grace: DispatchTimeInterval) {
        guard requestStop(reason) else { return }
        killLater(after: grace)
    }

    func killLater(after grace: DispatchTimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            lock.withLock { if pid > 0 { killpg(pid, SIGKILL) } }
        }
    }

    func resume(_ result: Result<CommandResult, any Error>) {
        let c: CheckedContinuation<CommandResult, any Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: result)
    }
}

/// Runs tools with `posix_spawn` (not `Process`, which can't start a new process group): stdin
/// is /dev/null, no other descriptor is inherited, signals are reset to their defaults.
public struct ProcessRunner: CommandRunning {
    /// Between SIGTERM and SIGKILL.
    static let killGrace: DispatchTimeInterval = .seconds(3)
    /// After a stop, how long the pipes may stay open (a child that inherited them) before the
    /// output collected so far is used.
    static let drainAfterStop: DispatchTimeInterval = .seconds(2)
    /// Same after a normal exit: a lingering grandchild holding the pipes can't hang the job.
    static let drainAfterExit: DispatchTimeInterval = .seconds(5)

    /// Variables set (or replaced) in every child's environment on top of XSide's own, read at
    /// each spawn: e.g. `DEVELOPER_DIR`, so every tool uses the Xcode chosen in Settings.
    private let environmentOverrides: @Sendable () -> [String: String]

    public init(environment: @escaping @Sendable () -> [String: String] = { [:] }) {
        environmentOverrides = environment
    }

    private static let log = Log("command")

    /// Logs the command line, then how it ended: exit code and duration, plus the end of its output
    /// when it failed.
    public func run(_ executable: String, _ arguments: [String], cwd: URL?,
                    timeout: Duration) async throws -> CommandResult {
        let line = Self.commandLine(executable, arguments)
        Self.log.info("$ \(line)")
        let start = ContinuousClock.now
        func elapsed() -> String {
            let d = ContinuousClock.now - start
            return String(format: "%.1fs", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        do {
            let result = try await execute(executable, arguments, cwd: cwd, timeout: timeout)
            if result.status == 0 {
                Self.log.info("exit 0 in \(elapsed()): \(Self.toolName(executable, arguments))")
            } else {
                var text = "exit \(result.status) in \(elapsed()): \(line)"
                if let tail = Self.tail(result.stderr) { text += "\n  stderr: \(tail)" }
                if let tail = Self.tail(String(decoding: result.stdout, as: UTF8.self)) { text += "\n  stdout: \(tail)" }
                Self.log.error(text)
            }
            return result
        } catch is CancellationError {
            Self.log.notice("cancelled after \(elapsed()): \(Self.toolName(executable, arguments))")
            throw CancellationError()
        } catch {
            Self.log.error("failed after \(elapsed()): \(line): \(error)")
            throw error
        }
    }

    /// `executable args…`, arguments with spaces quoted, long ones shortened.
    static func commandLine(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).map { argument in
            let short = argument.count > 300 ? argument.prefix(300) + "…" : Substring(argument)
            return short.contains(" ") || short.isEmpty ? "'\(short)'" : String(short)
        }.joined(separator: " ")
    }

    /// The last 2 000 characters of `text`, on one line, or nil when empty.
    static func tail(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let end = trimmed.count > 2_000 ? "…" + trimmed.suffix(2_000) : Substring(trimmed)
        return end.replacingOccurrences(of: "\n", with: "\n          ")
    }

    private func execute(_ executable: String, _ arguments: [String], cwd: URL?,
                         timeout: Duration) async throws -> CommandResult {
        try Task.checkCancellation()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let out = DataBox()
        let err = DataBox()
        let outDone = DispatchSemaphore(value: 0)
        let onChunk = CommandOutput.onChunk
        let errDone = DispatchSemaphore(value: 0)
        func drain(_ pipe: Pipe, _ box: DataBox, _ done: DispatchSemaphore) {
            pipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                    done.signal()
                } else {
                    box.append(chunk)
                    onChunk?(String(decoding: chunk, as: UTF8.self))
                }
            }
        }

        // The task's own variables (a job's `DEVELOPER_DIR`) win over the runner's.
        let overrides = environmentOverrides().merging(CommandEnvironment.overrides) { $1 }
        let state = RunState()
        let tool = Self.toolName(executable, arguments)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, any Error>) in
                state.setContinuation(cont)
                let pid: pid_t
                do {
                    pid = try Self.spawn(executable, arguments, cwd: cwd, overrides: overrides,
                                         stdout: outPipe.fileHandleForWriting.fileDescriptor,
                                         stderr: errPipe.fileHandleForWriting.fileDescriptor)
                } catch {
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    state.resume(.failure(error))
                    return
                }
                // Only the child writes now: EOF comes when it (and anything it spawned) is done.
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                drain(outPipe, out, outDone)
                drain(errPipe, err, errDone)
                // Cancelled before launch: the stop was recorded but nothing was signalled yet.
                if state.launched(pid) { state.killLater(after: Self.killGrace) }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    state.stop(.timedOut, grace: Self.killGrace)
                }

                Thread.detachNewThread {
                    // Wait for the exit without reaping, mark it under the lock, then reap.
                    var info = siginfo_t()
                    while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
                    let stopped = state.markExited()
                    var raw: Int32 = 0
                    var reaped: pid_t
                    repeat { reaped = waitpid(pid, &raw, 0) } while reaped == -1 && errno == EINTR
                    // No status to read (e.g. ECHILD): never report it as a success.
                    if reaped == -1 { raw = 0x7F00 } // decodes as exit status 127
                    let limit = DispatchTime.now() + (stopped == nil ? Self.drainAfterExit : Self.drainAfterStop)
                    _ = outDone.wait(timeout: limit)
                    _ = errDone.wait(timeout: limit)
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    switch stopped {
                    case .timedOut?: state.resume(.failure(XSideError.timedOut(tool: tool)))
                    case .cancelled?: state.resume(.failure(CancellationError()))
                    case nil:
                        state.resume(.success(CommandResult(
                            status: Self.exitStatus(raw),
                            stdout: out.value,
                            stderr: String(decoding: err.value, as: UTF8.self))))
                    }
                }
            }
        } onCancel: {
            state.stop(.cancelled, grace: Self.killGrace)
        }
    }

    /// Exit code, or the signal number for a process killed by a signal (like `Process`).
    static func exitStatus(_ raw: Int32) -> Int32 {
        raw & 0x7F == 0 ? (raw >> 8) & 0xFF : raw & 0x7F
    }

    /// `base` ("NAME=value" entries) with `overrides` applied: a variable set in both takes the
    /// override's value, the others are kept in order and the new ones are appended (sorted).
    static func environment(base: [String], overrides: [String: String]) -> [String] {
        guard !overrides.isEmpty else { return base }
        let kept = base.filter { entry in
            let name = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? entry
            return overrides[name] == nil
        }
        return kept + overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    /// The parent's environment as "NAME=value" entries.
    private static func currentEnvironment() -> [String] {
        var entries: [String] = []
        var pointer = environ
        while let entry = pointer.pointee {
            entries.append(String(cString: entry))
            pointer += 1
        }
        return entries
    }

    private static func spawn(_ executable: String, _ arguments: [String], cwd: URL?, overrides: [String: String],
                              stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd.path) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                     | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults)
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc: Int32
        if overrides.isEmpty {
            rc = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        } else {
            let envp: [UnsafeMutablePointer<CChar>?] = environment(base: currentEnvironment(), overrides: overrides)
                .map { strdup($0) } + [nil]
            defer { envp.forEach { free($0) } }
            rc = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        }
        guard rc == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(rc)) }
        return pid
    }

    /// Name reported by `timedOut`: the tool behind `xcrun`, the first command of `sh -c "…"`,
    /// else the executable's name.
    static func toolName(_ executable: String, _ arguments: [String]) -> String {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if name == "xcrun", let first = arguments.first { return first }
        if ["sh", "bash", "zsh"].contains(name), arguments.count > 1, arguments[0] == "-c",
           let word = arguments[1].split(whereSeparator: \.isWhitespace).first {
            return URL(fileURLWithPath: String(word)).lastPathComponent
        }
        return name
    }
}
