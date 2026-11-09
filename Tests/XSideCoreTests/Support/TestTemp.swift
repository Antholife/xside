import Foundation

/// One scratch root per test process: every temporary folder or file a test creates goes under it,
/// and the whole root is removed when the process exits (so `swift test` leaves nothing in $TMPDIR).
/// A root left behind by a killed run (its pid no longer exists) is removed by the next run.
enum TestTemp {
    static let prefix = "xside-test-"

    static let root: URL = {
        let base = FileManager.default.temporaryDirectory
        sweepDeadRuns(in: base)
        let dir = base.appendingPathComponent("\(prefix)\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        atexit { TestTemp.removeRoot() }
        return dir
    }()

    fileprivate static func removeRoot() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)\(getpid())").path
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func sweepDeadRuns(in base: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where name.hasPrefix(prefix) {
            guard let pid = pid_t(name.dropFirst(prefix.count)), pid > 0 else { continue }
            if kill(pid, 0) == -1 && errno == ESRCH { try? fm.removeItem(atPath: base.appendingPathComponent(name).path) }
        }
    }
}

/// Runs `body` with a fresh folder that is removed afterwards, even when `body` throws.
func withTemporaryDirectory<T>(_ label: String = "dir", _ body: (URL) async throws -> T) async throws -> T {
    let dir = TestTemp.root.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}
