import Foundation
import Testing
@testable import XSideCore

/// A tweak's `.deb` `Description`, shown on its card: read from the control, kept with the
/// stored tweak, and filled once for tweaks stored before XSide kept it (from the kept download).
struct TweakDescriptionTests {

    // MARK: Parsing

    @Test func multiLineDescriptionKeepsItsLinesAndDotLinesAreBlank() throws {
        let c = try DebControl.parse("""
        Package: a
        Description: Native PiP for YouTube
         Adds a PiP button to the video overlay.
         .
         Settings are in YouTube's settings.
        Depends: mobilesubstrate
        """)
        #expect(c.summary == "Native PiP for YouTube\nAdds a PiP button to the video overlay.\n\nSettings are in YouTube's settings.")
        #expect(c.depends.count == 1)
    }

    @Test func oneLineDescription() throws {
        #expect(try DebControl.parse("Package: a\nDescription: does things\n").summary == "does things")
    }

    @Test func missingOrEmptyDescriptionIsNil() throws {
        #expect(try DebControl.parse("Package: a\n").summary == nil)
        #expect(try DebControl.parse("Package: a\nDescription:   \n").summary == nil)
        #expect(try DebControl.parse("Package: a\nDescription:\n .\n .\n").summary == nil)
    }

    @Test func descriptionIsCappedAt1000Characters() throws {
        let long = String(repeating: "é", count: 3000)
        let c = try DebControl.parse("Package: a\nDescription: \(long)\n more\n")
        #expect(c.summary?.count == TweakDescription.maxLength)
        #expect(TweakDescription.maxLength == 1000)
        #expect(c.summary?.allSatisfy { $0 == "é" } == true)
    }

    @Test func controlCharactersAreDroppedButLineBreaksKept() throws {
        let c = try DebControl.parse("Package: a\nDescription: Ev\u{1B}[31mil\u{202E}x\u{7}\n line\u{0}two\u{2028}\n\tthird\u{200B}\n")
        #expect(c.summary == "Ev[31milx\nlinetwo\nthird")
        let s = try #require(c.summary)
        #expect(!s.unicodeScalars.contains { $0 != "\n" && ($0.properties.generalCategory == .control || $0.properties.generalCategory == .format) })
    }

    @Test func blankLinesAtTheEndsGoAndRunsOfDotLinesStay() throws {
        let c = try DebControl.parse("Package: a\nDescription:\n .\n First\n .\n .\n Second\n .\n")
        #expect(c.summary == "First\n\n\nSecond")
    }

    /// Mega review T4: the name and the author stay one line, capped.
    @Test func nameAndAuthorStayOneLine() throws {
        let c = try DebControl.parse("Package: a\nName: One\n two\nAuthor: Jane\n Doe <j@x>\nDescription: d\n e\n")
        #expect(c.name == "One")
        #expect(c.author == "Jane")
        #expect(c.summary == "d\ne")
    }

    // MARK: Stored with the tweak

    private func package(summary: String?) -> TweakPackage {
        TweakPackage(id: "0123456789abcdef", kind: .deb, origin: .added, packageID: "com.example.a", name: "A",
                     summary: summary, addedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func storedDescriptionRoundTrips() throws {
        let p = package(summary: "line one\n\nline two")
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(TweakPackage.self, from: data)
        #expect(back == p)
        #expect(back.summary == "line one\n\nline two")
    }

    @Test func olderJSONWithoutDescriptionLoads() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(package(summary: "x"))) as? [String: Any])
        json["summary"] = nil
        let back = try JSONDecoder().decode(TweakPackage.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.summary == nil)
        #expect(back.name == "A")
    }

    @Test func shownDescriptionHidesEmptyOnes() {
        #expect(package(summary: nil).shownSummary == nil)
        #expect(package(summary: "").shownSummary == nil)
        #expect(package(summary: " \n ").shownSummary == nil)
        #expect(package(summary: "Hi").shownSummary == "Hi")
    }

    @Test func analyzedDebKeepsItsDescriptionAndADylibHasNone() async throws {
        let dir = TestTemp.root.appendingPathComponent("desc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let deb = dir.appendingPathComponent("a.deb")
        try await FakeDeb.deb(control: "Package: com.example.a\nName: A\nDescription: Short\n Long\n .\n End\n",
                              files: [.file("./usr/lib/a.dylib", FakeIPA.dylibMachO(linking: [], padding: 64, strings: []))],
                              compression: "gz").write(to: deb)
        let p = try await TweakAnalyzer.analyze(deb, into: dir.appendingPathComponent("s1"), runner: ProcessRunner(), now: Date())
        #expect(p.summary == "Short\nLong\n\nEnd")

        let plain = dir.appendingPathComponent("b.deb")
        try await FakeDeb.deb(control: "Package: com.example.b\nName: B\n",
                              files: [.file("./usr/lib/b.dylib", FakeIPA.dylibMachO(linking: [], padding: 64, strings: []))],
                              compression: "gz").write(to: plain)
        let q = try await TweakAnalyzer.analyze(plain, into: dir.appendingPathComponent("s2"), runner: ProcessRunner(), now: Date())
        #expect(q.summary == "")
        #expect(q.shownSummary == nil)

        let dylib = dir.appendingPathComponent("C.dylib")
        try FakeIPA.dylibMachO(linking: [], padding: 64, strings: []).write(to: dylib)
        let d = try await TweakAnalyzer.analyze(dylib, into: dir.appendingPathComponent("s3"), runner: ProcessRunner(), now: Date())
        #expect(d.shownSummary == nil)
    }

    // MARK: Lazy migration

    private static func app(_ lib: AppLibrary, _ dir: URL, _ name: String) async throws -> AppRecord {
        let ipa = dir.appendingPathComponent("\(name).ipa")
        try Data(name.utf8).write(to: ipa)
        return try await lib.importIPA(ipa, info: AppInfo(bundleID: "com.example.\(name.lowercased())", name: name, version: "1.0",
                                                          executable: name), teamID: "TEAM123456")
    }

    /// Writes `state.json` as an older XSide would have: the tweaks without `summary`.
    private static func dropSummaries(_ lib: AppLibrary) throws {
        let url = lib.root.appendingPathComponent("state.json")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: #""summary" : "[^"]*",?\n"#, with: "", options: .regularExpression)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func tweaksStoredBeforeGetTheirDescriptionFromTheKeptDownloadOnce() async throws {
        let dir = TestTemp.root.appendingPathComponent("desc-mig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
        let record = try await Self.app(lib, dir, "YouTube")

        func deb(_ control: String, _ path: String) async throws -> URL {
            let u = dir.appendingPathComponent(UUID().uuidString + ".deb")
            try await FakeDeb.deb(control: control, files: [.file(path, FakeIPA.dylibMachO(linking: [], padding: 64, strings: [path]))],
                                  compression: "gz").write(to: u)
            return u
        }
        // Downloaded, its .deb kept: filled from it.
        let cephei = try await deb("Package: ws.hbang.common\nName: Cephei\nVersion: 1.17\nDescription: Support library\n .\n For tweaks.\n",
                                   "./usr/lib/libc.dylib")
        let sha = RepoClientTests.sha256(try Data(contentsOf: cephei))
        _ = try await lib.storeDownload(cephei, sha256: sha, packageID: "ws.hbang.common", version: "1.17", repo: "chariz", url: "u")
        let kept = try await lib.addTweak(cephei, origin: .downloaded(repo: "chariz", url: "u", sha256: sha), recordID: record.id,
                                          deviceIDs: ["iphone"], runner: ProcessRunner(), now: Date()).package
        // Downloaded, its .deb gone since: left empty.
        let gone = try await deb("Package: com.example.gone\nName: Gone\nDescription: never seen\n", "./usr/lib/g.dylib")
        let goneSHA = RepoClientTests.sha256(try Data(contentsOf: gone))
        let lost = try await lib.addTweak(gone, origin: .downloaded(repo: "chariz", url: "u2", sha256: goneSHA), recordID: record.id,
                                          deviceIDs: ["iphone"], runner: ProcessRunner(), now: Date()).package
        // Dropped by the person: XSide never kept its .deb.
        let dropped = try await lib.addTweak(try await deb("Package: com.example.drop\nName: Drop\nDescription: dropped\n", "./usr/lib/d.dylib"),
                                             recordID: record.id, deviceIDs: ["iphone"], runner: ProcessRunner(), now: Date()).package

        try Self.dropSummaries(lib)
        let old = AppLibrary(root: lib.root)
        let before = try #require(await old.records().first?.tweaks)
        #expect(before.allSatisfy { $0.summary == nil })

        let filled = await old.fillMissingTweakSummaries(runner: ProcessRunner())
        #expect(filled == 1)
        let after = try #require(await old.records().first?.tweaks)
        #expect(after.first { $0.id == kept.id }?.summary == "Support library\n\nFor tweaks.")
        #expect(after.first { $0.id == lost.id }?.summary == nil)
        #expect(after.first { $0.id == dropped.id }?.summary == nil)

        // Saved: a library opened again has it, and nothing is read a second time.
        let again = AppLibrary(root: lib.root)
        #expect(await again.records().first?.tweaks?.first { $0.id == kept.id }?.summary == "Support library\n\nFor tweaks.")
        #expect(await again.fillMissingTweakSummaries(runner: ProcessRunner()) == 0)
    }

    @Test func aKeptDownloadWithoutDescriptionIsMarkedLookedAt() async throws {
        let dir = TestTemp.root.appendingPathComponent("desc-mig2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
        let record = try await Self.app(lib, dir, "YouTube")
        let u = dir.appendingPathComponent("n.deb")
        try await FakeDeb.deb(control: "Package: com.example.n\nName: N\n",
                              files: [.file("./usr/lib/n.dylib", FakeIPA.dylibMachO(linking: [], padding: 64, strings: []))],
                              compression: "gz").write(to: u)
        let sha = RepoClientTests.sha256(try Data(contentsOf: u))
        _ = try await lib.storeDownload(u, sha256: sha, packageID: "com.example.n", version: "1", repo: "chariz", url: "u")
        let p = try await lib.addTweak(u, origin: .downloaded(repo: "chariz", url: "u", sha256: sha), recordID: record.id,
                                       deviceIDs: ["iphone"], runner: ProcessRunner(), now: Date()).package
        try Self.dropSummaries(lib)
        let old = AppLibrary(root: lib.root)
        #expect(await old.fillMissingTweakSummaries(runner: ProcessRunner()) == 1)
        #expect(await old.records().first?.tweaks?.first { $0.id == p.id }?.summary == "")
        #expect(await old.fillMissingTweakSummaries(runner: ProcessRunner()) == 0)
    }

    @Test func downloadUsageCarriesTheDescription() async throws {
        let dir = TestTemp.root.appendingPathComponent("desc-use-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lib = AppLibrary(root: dir.appendingPathComponent("lib"))
        let record = try await Self.app(lib, dir, "YouTube")
        let u = dir.appendingPathComponent("c.deb")
        try await FakeDeb.deb(control: "Package: ws.hbang.common\nName: Cephei\nDescription: Support library\n",
                              files: [.file("./usr/lib/c.dylib", FakeIPA.dylibMachO(linking: [], padding: 64, strings: []))],
                              compression: "gz").write(to: u)
        let sha = RepoClientTests.sha256(try Data(contentsOf: u))
        _ = try await lib.storeDownload(u, sha256: sha, packageID: "ws.hbang.common", version: "1", repo: "chariz", url: "u")
        _ = try await lib.addTweak(u, origin: .downloaded(repo: "chariz", url: "u", sha256: sha), recordID: record.id,
                                   deviceIDs: ["iphone"], runner: ProcessRunner(), now: Date())
        #expect(await lib.downloadUsage().first?.summary == "Support library")
    }
}
