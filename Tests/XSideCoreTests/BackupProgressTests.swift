import Testing
import Foundation
@testable import XSideCore

/// Plays devicectl over a scripted container tree: lists it (unless `listable` is false),
/// copies files out of it into the pull destination, and records every call in order.
private final class ProgressTreeRunner: CommandRunning, @unchecked Sendable {
    var tree: [String: String] = [:]
    var listable = true
    var fileOnly = false
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    private(set) var pulled: [String] = []

    func run(_ executable: String, _ arguments: [String], cwd: URL?, timeout: Duration) async throws -> CommandResult {
        lock.withLock { calls.append(arguments) }
        let ok = CommandResult(status: 0, stdout: Data(), stderr: "")
        if arguments.starts(with: ["devicectl", "device", "info", "files"]) {
            guard listable, let i = arguments.firstIndex(of: "--json-output") else { return CommandResult(status: 1, stdout: Data(), stderr: "nope") }
            var dirs = Set<String>()
            for p in tree.keys { var c = p; while c.contains("/") { c = String(c[..<c.lastIndex(of: "/")!]); dirs.insert(c) } }
            let files = (fileOnly ? [] : dirs.map { ["relativePath": $0, "resources": ["isDirectory": true], "metadata": [:]] as [String: Any] })
                + tree.map { ["relativePath": $0.key, "resources": ["isDirectory": false], "metadata": ["size": $0.value.count]] as [String: Any] }
            try JSONSerialization.data(withJSONObject: ["result": ["files": files]]).write(to: URL(fileURLWithPath: arguments[i + 1]))
            return ok
        }
        if arguments.starts(with: ["devicectl", "device", "info", "processes"]) {
            if let i = arguments.firstIndex(of: "--json-output") {
                try Data("{\"result\":{\"runningProcesses\":[]}}".utf8).write(to: URL(fileURLWithPath: arguments[i + 1]))
            }
            return ok
        }
        if arguments.starts(with: ["devicectl", "device", "copy", "from"]) {
            let src = arguments[arguments.firstIndex(of: "--source")! + 1]
            let dest = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "--destination")! + 1])
            lock.withLock { pulled.append(src) }
            // Like devicectl, the destination's parent must already exist.
            guard FileManager.default.fileExists(atPath: dest.deletingLastPathComponent().path) else {
                return CommandResult(status: 1, stdout: Data(), stderr: "no such destination directory")
            }
            for (p, content) in tree where src == "/" || p == src || p.hasPrefix(src + "/") {
                let rel = src == "/" ? p : (p == src ? "" : String(p.dropFirst(src.count + 1)))
                let target = rel.isEmpty ? dest : dest.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: target)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: target.path)
            }
        }
        return ok
    }
}

private final class Ticks: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [[Int64]] = []
    var all: [[Int64]] { lock.withLock { _all } }
    func add(_ d: Int, _ t: Int, _ bd: Int64, _ bt: Int64) { lock.withLock { _all.append([Int64(d), Int64(t), bd, bt]) } }
}

@Suite struct BackupProgressTests {
    private func make(_ runner: ProgressTreeRunner) -> (BackupService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bp-\(UUID().uuidString)")
        return (BackupService(store: AppDataBackup(root: root), container: AppDataContainer(runner: runner)), root)
    }

    @Test func reportsOneTickPerCopiedGroup_excludedNotCounted() async throws {
        let runner = ProgressTreeRunner()
        runner.tree = ["Documents/a": "1", "Documents/b": "22", "Library/Prefs/p": "333", "tmp/x": "4444", "Library/Caches/c": "55555"]
        let (service, root) = make(runner)
        defer { try? FileManager.default.removeItem(at: root) }
        let ticks = Ticks()
        _ = try await service.backUp(signedBundleID: "b.T", deviceID: "D", deviceName: "n", appVersion: nil,
                                     includeCaches: false, progress: { ticks.add($0, $1, $2, $3) })
        // Two copies — the whole « Documents/ » (a, b) then « Library/Prefs/ » (p); caches and tmp excluded.
        #expect(ticks.all.count == 2)
        #expect(ticks.all.last == [3, 3, 6, 6])
        #expect(ticks.all.map { $0[0] } == [2, 3])
    }

    @Test func fallbackWholePull_reportsUnknownTotalOnce() async throws {
        let runner = ProgressTreeRunner()
        runner.listable = false
        runner.tree = ["Documents/a": "1"]
        let (service, root) = make(runner)
        defer { try? FileManager.default.removeItem(at: root) }
        let ticks = Ticks()
        _ = try await service.backUp(signedBundleID: "b.T", deviceID: "D", deviceName: "n", appVersion: nil,
                                     includeCaches: false, progress: { ticks.add($0, $1, $2, $3) })
        #expect(ticks.all == [[0, 0, 0, 0]])
    }

    @Test func fraction_prefersBytes_fallsBackToFiles_nilWhenUnknown() {
        #expect(BackupProgress.fraction(filesDone: 1, filesTotal: 4, bytesDone: 50, bytesTotal: 100) == 0.5)
        #expect(BackupProgress.fraction(filesDone: 1, filesTotal: 4, bytesDone: 0, bytesTotal: 0) == 0.25)
        #expect(BackupProgress.fraction(filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0) == nil)
    }

    @Test func monotonic_neverDecreases_unknownKeepsCurrent() {
        #expect(BackupProgress.monotonic(current: nil, new: 0.3) == 0.3)
        #expect(BackupProgress.monotonic(current: 0.5, new: 0.3) == 0.5)
        #expect(BackupProgress.monotonic(current: 0.5, new: 0.8) == 0.8)
        #expect(BackupProgress.monotonic(current: 0.5, new: nil) == 0.5)
    }
}
