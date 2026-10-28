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

public protocol CommandRunning: Sendable {
    /// `executable` is an absolute path, e.g. `/usr/bin/xcrun`.
    func run(_ executable: String, _ arguments: [String], cwd: URL?) async throws -> CommandResult
}

/// Collects data appended from a readability handler.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], cwd: URL?) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let out = DataBox()
        let err = DataBox()
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        func drain(_ pipe: Pipe, _ box: DataBox, _ done: DispatchSemaphore) {
            pipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                    done.signal()
                } else {
                    box.append(chunk)
                }
            }
        }
        drain(outPipe, out, outDone)
        drain(errPipe, err, errDone)

        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in
                // Wait until both pipes hit EOF so no output is lost.
                DispatchQueue.global().async {
                    outDone.wait()
                    errDone.wait()
                    cont.resume(returning: CommandResult(
                        status: p.terminationStatus,
                        stdout: out.value,
                        stderr: String(decoding: err.value, as: UTF8.self)))
                }
            }
            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
    }
}
