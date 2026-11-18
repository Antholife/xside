import Testing
import Foundation
@testable import XSideCore

/// A devicectl that lists three files in three folders (so three copies), and cancels the backup's
/// task while pulling the first.
private final class CancellingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _task: Task<BackupSnapshot?, Error>?
    private var _pulls: [URL] = []
    var task: Task<BackupSnapshot?, Error>? { get { lock.withLock { _task } } set { lock.withLock { _task = newValue } } }
    var pulls: [URL] { lock.withLock { _pulls } }

    func run(_ executable: String, _ arguments: [String], cwd: URL?, timeout: Duration) async throws -> CommandResult {
        let ok = CommandResult(status: 0, stdout: Data(), stderr: "")
        if arguments.starts(with: ["devicectl", "device", "info", "files"]) {
            let i = arguments.firstIndex(of: "--json-output")!
            let files = ["Documents/a", "Media/b", "Store/c"].map {
                ["relativePath": $0, "resources": ["isDirectory": false], "metadata": ["size": 1]] as [String: Any]
            }
            try JSONSerialization.data(withJSONObject: ["result": ["files": files]]).write(to: URL(fileURLWithPath: arguments[i + 1]))
            return ok
        }
        if arguments.starts(with: ["devicectl", "device", "copy", "from"]) {
            let dest = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "--destination")! + 1])
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dest.appendingPathComponent("f"))
            let first = lock.withLock { _pulls.append(dest); return _pulls.count == 1 }
            if first { task?.cancel() } // the user taps Cancel mid-backup; this copy still completes
        }
        return ok
    }
}

@Suite struct BackupCancelTests {
    @Test func cancel_stopsBetweenCopies_throwsAndLeavesNoSnapshotNorTemp() async throws {
        let runner = CancellingRunner()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppDataBackup(root: root)
        let service = BackupService(store: store, container: AppDataContainer(runner: runner))
        let task = Task { try await service.backUp(signedBundleID: "b.T", deviceID: "D", deviceName: "iPhone", appVersion: "1", includeCaches: true) }
        runner.task = task
        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {}
        #expect(runner.pulls.count == 1) // stopped before the 2nd of 3 copies
        let temp = try #require(runner.pulls.first?.deletingLastPathComponent().pathComponents.first { $0.hasPrefix("xside-backup-") })
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.appendingPathComponent(temp).path))
        #expect(await store.list(signedBundleID: "b.T", deviceID: "D").isEmpty)
    }

    @Test func sweepStaleTemps_removesOldBackupDirsOnly() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sw-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for n in ["xside-backup-old", "xside-backup-new", "other-old"] {
            try fm.createDirectory(at: root.appendingPathComponent(n), withIntermediateDirectories: true)
        }
        let old = Date().addingTimeInterval(-86_400)
        for n in ["xside-backup-old", "other-old"] { try fm.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(n).path) }
        BackupService.sweepStaleTemps(in: root, olderThan: 3600)
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("xside-backup-old").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("xside-backup-new").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("other-old").path))
    }
}
