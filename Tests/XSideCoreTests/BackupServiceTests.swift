import Testing
import Foundation
@testable import XSideCore

/// Plays devicectl over a scripted container tree: lists it (unless `listable` is false),
/// copies files out of it into the pull destination, and records every call in order.
private final class TreeRunner: CommandRunning, @unchecked Sendable {
    var tree: [String: String] = [:]
    var listable = true
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
            let files = dirs.map { ["relativePath": $0, "resources": ["isDirectory": true], "metadata": [:]] as [String: Any] }
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

@Suite struct BackupServiceTests {
    private func make(_ runner: TreeRunner) -> (BackupService, AppDataBackup, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bs-\(UUID().uuidString)")
        let store = AppDataBackup(root: root)
        return (BackupService(store: store, container: AppDataContainer(runner: runner)), store, root)
    }

    private func files(_ dir: URL) -> Set<String> {
        var out = Set<String>()
        for case let rel as String in FileManager.default.enumerator(atPath: dir.path) ?? NSEnumerator() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(rel).path, isDirectory: &isDir), !isDir.boolValue { out.insert(rel) }
        }
        return out
    }

    @Test func backUp_excludesTmpAndCachesWhenOff() async throws {
        let runner = TreeRunner()
        runner.tree = ["Documents/f": "1", "tmp/x": "2", "Library/Caches/c": "3", "Library/Prefs/p": "4"]
        let (service, store, root) = make(runner)
        defer { try? FileManager.default.removeItem(at: root) }
        let off = try #require(try await service.backUp(signedBundleID: "b.T", deviceID: "D", deviceName: "iPhone", appVersion: "1", includeCaches: false))
        let offDir = await store.snapshotDir(off)
        #expect(files(offDir) == ["Documents/f", "Library/Prefs/p"])
        runner.tree["Documents/f"] = "changed"
        let on = try #require(try await service.backUp(signedBundleID: "b.T", deviceID: "D", deviceName: "iPhone", appVersion: "1", includeCaches: true))
        let onDir = await store.snapshotDir(on)
        #expect(files(onDir) == ["Documents/f", "Library/Prefs/p", "Library/Caches/c"])
    }

    @Test func backUp_returnsNilWhenUnchanged() async throws {
        let runner = TreeRunner()
        runner.tree = ["Documents/f": "1"]
        let (service, store, root) = make(runner)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await service.backUp(signedBundleID: "b.T", deviceID: "D", deviceName: "n", appVersion: nil, includeCaches: false)
        let second = try await service.backUp(signedBundleID: "b.T", deviceID: "D", deviceName: "n", appVersion: nil, includeCaches: false)
        #expect(second == nil)
        let all = await store.list()
        #expect(all.count == 1)
    }

    @Test func backUp_fullPullWhenListingNil() async throws {
        let runner = TreeRunner()
        runner.listable = false
        runner.tree = ["Documents/f": "1", "tmp/x": "2", "Library/Caches/c": "3"]
        let (service, store, root) = make(runner)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try #require(try await service.backUp(signedBundleID: "b.T", deviceID: "D", deviceName: "n", appVersion: nil, includeCaches: false))
        #expect(runner.pulled == ["/"])
        let sDir = await store.snapshotDir(s)
        #expect(files(sDir) == ["Documents/f"])
    }

    @Test func restore_terminatesThenPushes() async throws {
        let runner = TreeRunner()
        runner.tree = ["Documents/f": "1"]
        let (service, store, root) = make(runner)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try #require(try await service.backUp(signedBundleID: "b.T", deviceID: "D", deviceName: "n", appVersion: nil, includeCaches: false))
        _ = try await service.restore(s, toSignedBundleID: "b.T", deviceID: "D", executable: "App", clear: false)
        let kinds = runner.calls.compactMap { $0.count > 2 ? $0[2] : nil }
        let processes = try #require(runner.calls.firstIndex { $0.starts(with: ["devicectl", "device", "info", "processes"]) })
        let push = try #require(runner.calls.firstIndex { $0.starts(with: ["devicectl", "device", "copy", "to"]) })
        #expect(processes < push)
        #expect(!kinds.isEmpty)
        let call = runner.calls[push]
        let dir = await store.snapshotDir(s)
        #expect(call[call.firstIndex(of: "--source")! + 1] == dir.path)
    }

    @Test func restore_clearReportsOverlayWhenClearUnsupported() async throws {
        let runner = TreeRunner()
        runner.tree = ["Documents/f": "1"]
        let (service, _, root) = make(runner)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = try #require(try await service.backUp(signedBundleID: "b.T", deviceID: "D", deviceName: "n", appVersion: nil, includeCaches: false))
        let result = try await service.restore(s, toSignedBundleID: "b.T", deviceID: "D", executable: "App", clear: true)
        #expect(result == .overlay)
    }
}
