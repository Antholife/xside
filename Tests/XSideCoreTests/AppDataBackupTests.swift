import Testing
import Foundation
@testable import XSideCore

private let fixedMTime = Date(timeIntervalSince1970: 1_700_000_000)

private func makeTree(_ files: [String: String], mtime: Date = fixedMTime) throws -> URL {
    let d = TestTemp.root.appendingPathComponent("tree-\(UUID().uuidString)", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    for (rel, content) in files {
        let u = d.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: u)
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: u.path)
    }
    return d
}

private func makeStore() -> AppDataBackup {
    AppDataBackup(root: TestTemp.root.appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true))
}

private func inode(_ u: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: u.path)[.systemFileNumber] as? NSNumber)?.intValue ?? -1
}

private func snap(_ store: AppDataBackup, _ src: URL, retention: Int = 3, at t: TimeInterval) async throws -> BackupSnapshot {
    try await store.createSnapshot(from: src, signedBundleID: "com.example.app", deviceID: "DEV1", deviceName: "iPhone",
                                   includedCaches: false, appVersion: "1.0", retention: retention,
                                   now: Date(timeIntervalSince1970: t))
}

@Test func createSnapshot_storesTreeAndIndexesIt() async throws {
    let store = makeStore()
    let src = try makeTree(["a.txt": "hello", "sub/b.txt": "world!!"])
    let s = try await snap(store, src, at: 1_800_000_000)
    let dir = await store.snapshotDir(s)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt").path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sub/b.txt").path))
    let all = await store.list()
    #expect(all.count == 1)
    #expect(all[0].byteSize == 12)
    #expect(all[0].fileCount == 2)
    #expect(all[0] == s)
}

@Test func createSnapshot_hardLinksUnchangedFiles() async throws {
    let store = makeStore()
    let src1 = try makeTree(["same.txt": "identical", "diff.txt": "version one"])
    let a = try await snap(store, src1, at: 1_800_000_000)
    let src2 = try makeTree(["same.txt": "identical", "diff.txt": "version two!"])
    let b = try await snap(store, src2, at: 1_800_000_100)
    let da = await store.snapshotDir(a), db = await store.snapshotDir(b)
    #expect(try inode(da.appendingPathComponent("same.txt")) == inode(db.appendingPathComponent("same.txt")))
    #expect(try inode(da.appendingPathComponent("diff.txt")) != inode(db.appendingPathComponent("diff.txt")))
}

@Test func retention_prunesOldestAndKeepsNewest() async throws {
    let store = makeStore()
    let src = try makeTree(["a.txt": "x"])
    let s1 = try await snap(store, src, retention: 2, at: 1_800_000_000)
    let s2 = try await snap(store, src, retention: 2, at: 1_800_000_100)
    let s3 = try await snap(store, src, retention: 2, at: 1_800_000_200)
    let all = await store.list()
    #expect(all.map(\.id) == [s3.id, s2.id])
    #expect(!FileManager.default.fileExists(atPath: await store.snapshotDir(s1).path))
}

@Test func prune_keepsHardLinkedFileReadableInNewerSnapshot() async throws {
    let store = makeStore()
    let src = try makeTree(["a.txt": "persistent"])
    _ = try await snap(store, src, retention: 2, at: 1_800_000_000)
    let s2 = try await snap(store, src, retention: 2, at: 1_800_000_100)
    let s3 = try await snap(store, src, retention: 2, at: 1_800_000_200)
    for s in [s2, s3] {
        let data = try Data(contentsOf: await store.snapshotDir(s).appendingPathComponent("a.txt"))
        #expect(String(decoding: data, as: UTF8.self) == "persistent")
    }
}

@Test func totalBytes_countsSharedInodesOnce() async throws {
    let store = makeStore()
    let src = try makeTree(["a.bin": String(repeating: "k", count: 1024)])
    for i in 0..<3 { _ = try await snap(store, src, at: 1_800_000_000 + Double(i) * 100) }
    let total = await store.totalBytes()
    #expect(total >= 1024 && total < 2048)
}

@Test func contentUnchanged_trueWhenSameSizesAndMtimes_falseOnEdit() throws {
    let a = try makeTree(["a.txt": "same", "s/b.txt": "more"])
    let b = try makeTree(["a.txt": "same", "s/b.txt": "more"])
    #expect(AppDataBackup.contentUnchanged(a, b))
    try Data("edit!".utf8).write(to: b.appendingPathComponent("a.txt"))
    #expect(!AppDataBackup.contentUnchanged(a, b))
}

@Test func snapshot_findsByID_nilWhenAbsent() async throws {
    let store = makeStore()
    let src = try makeTree(["a.txt": "x"])
    let s = try await snap(store, src, at: 1_800_000_000)
    #expect(await store.snapshot(s.id) == s)
    #expect(await store.snapshot("nope") == nil)
}
