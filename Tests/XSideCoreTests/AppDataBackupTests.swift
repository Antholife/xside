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

@Test func contentUnchanged_trueWhenSameContentDifferentMtime_falseOnContentEdit() throws {
    let a = try makeTree(["a.txt": "same", "s/b.txt": "more"])
    let b = try makeTree(["a.txt": "same", "s/b.txt": "more"], mtime: Date(timeIntervalSince1970: 1_600_000_000))
    #expect(AppDataBackup.contentUnchanged(a, b))
    try Data("sane".utf8).write(to: b.appendingPathComponent("a.txt")) // same size, different bytes
    #expect(!AppDataBackup.contentUnchanged(a, b))
}

@Test func folderName_isAppData() {
    #expect(AppDataBackup.folderName == "app-data")
}

@Test func dedup_hardLinksIdenticalContentDespiteDifferentMtimes() async throws {
    let store = makeStore()
    let src = try makeTree(["n.txt": "nano", "m.txt": "other"])
    let a = try await snap(store, src, at: 1_800_000_000)
    setNanoMTime(src.appendingPathComponent("n.txt"), sec: 1_650_000_000, nsec: 5)
    let b = try await snap(store, src, at: 1_800_000_100)
    #expect(try inode(await store.snapshotDir(a).appendingPathComponent("n.txt"))
            == inode(await store.snapshotDir(b).appendingPathComponent("n.txt")))
    // same size, different content: not linked
    try Data("NANO".utf8).write(to: src.appendingPathComponent("n.txt"))
    let c = try await snap(store, src, at: 1_800_000_200)
    #expect(try inode(await store.snapshotDir(b).appendingPathComponent("n.txt"))
            != inode(await store.snapshotDir(c).appendingPathComponent("n.txt")))
}

@Test func snapshot_findsByID_nilWhenAbsent() async throws {
    let store = makeStore()
    let src = try makeTree(["a.txt": "x"])
    let s = try await snap(store, src, at: 1_800_000_000)
    #expect(await store.snapshot(s.id) == s)
    #expect(await store.snapshot("nope") == nil)
}

private func setNanoMTime(_ u: URL, sec: Int, nsec: Int) {
    var ts = [timespec(tv_sec: sec, tv_nsec: nsec), timespec(tv_sec: sec, tv_nsec: nsec)]
    #expect(utimensat(AT_FDCWD, u.path, &ts, 0) == 0)
}

@Test func createSnapshot_hardLinksFilesWithNanosecondMTime_acrossThreeSnapshots() async throws {
    let store = makeStore()
    let src = try makeTree(["n.txt": "nano"])
    setNanoMTime(src.appendingPathComponent("n.txt"), sec: 1_700_000_000, nsec: 123_456_789)
    let a = try await snap(store, src, at: 1_800_000_000)
    let b = try await snap(store, src, at: 1_800_000_100)
    let c = try await snap(store, src, at: 1_800_000_200)
    let ia = try inode(await store.snapshotDir(a).appendingPathComponent("n.txt"))
    #expect(try inode(await store.snapshotDir(b).appendingPathComponent("n.txt")) == ia)
    #expect(try inode(await store.snapshotDir(c).appendingPathComponent("n.txt")) == ia)
}

@Test func createSnapshot_skipsEscapingSymlinks_andWritesNothingOutside() async throws {
    let fm = FileManager.default
    let store = makeStore()
    let outside = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("secret".utf8).write(to: outside.appendingPathComponent("x"))
    let src = try makeTree(["ok.txt": "fine", "d/inner.txt": "in"])
    try fm.createSymbolicLink(atPath: src.appendingPathComponent("esc").path, withDestinationPath: "../../etc/x")
    try fm.createSymbolicLink(atPath: src.appendingPathComponent("abs").path, withDestinationPath: "/etc/hosts")
    try fm.createSymbolicLink(atPath: src.appendingPathComponent("dirlink").path, withDestinationPath: outside.path)
    try fm.createSymbolicLink(atPath: src.appendingPathComponent("d/up").path, withDestinationPath: "../../..")
    try fm.createSymbolicLink(atPath: src.appendingPathComponent("rel").path, withDestinationPath: "d/inner.txt")
    let before = try fm.contentsOfDirectory(atPath: outside.path)
    let s1 = try await snap(store, src, at: 1_800_000_000)
    let s2 = try await snap(store, src, at: 1_800_000_100)
    for s in [s1, s2] {
        let dir = await store.snapshotDir(s)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("ok.txt").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("d/inner.txt").path))
        for bad in ["esc", "abs", "dirlink", "d/up"] {
            #expect((try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent(bad).path)) == nil)
        }
        #expect((try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("rel").path)) == "d/inner.txt")
        #expect(s.fileCount == 2)
    }
    #expect(try fm.contentsOfDirectory(atPath: outside.path) == before)
    // Nothing escaped the store: only the backups folder was created under the library root.
    let libRoot = await store.snapshotDir(s1).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    #expect(try fm.contentsOfDirectory(atPath: libRoot.path) == [AppDataBackup.folderName])
}

@Test func createSnapshot_rejectsChainedSymlinkBypass_keepsPlainRelativeLink() async throws {
    let fm = FileManager.default
    let store = makeStore()
    let src = try makeTree(["d/inner.txt": "in", "ok.txt": "fine"])
    func link(_ name: String, _ dest: String) throws {
        try fm.createSymbolicLink(atPath: src.appendingPathComponent(name).path, withDestinationPath: dest)
    }
    try link("a", ".")
    try link("b", "a/..")          // resolves to the source root's parent
    try link("c", "a/d/inner.txt") // passes through the symlink "a"
    try link("plain", "d/inner.txt")
    let s = try await snap(store, src, at: 1_800_000_000)
    let dir = await store.snapshotDir(s)
    func dest(_ n: String) -> String? { try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent(n).path) }
    #expect(dest("b") == nil)
    #expect(dest("c") == nil)
    #expect(dest("plain") == "d/inner.txt")
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("ok.txt").path))
    let libRoot = dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    #expect(try fm.contentsOfDirectory(atPath: libRoot.path) == [AppDataBackup.folderName])
}
