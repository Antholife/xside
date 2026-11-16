import Testing
import Foundation
@testable import XSideCore

@Suite struct UpdateCheckerTests {
    static let source = ReleaseFinderTests.source
    static let plain = ReleaseFinderTests.plain
    static let found = FoundRelease(
        tag: "v1.1.8", isPrerelease: false,
        asset: ReleaseAsset(name: ReleaseFinderTests.ipa, url: URL(string: "\(ReleaseFinderTests.base)/v1.1.8/\(ReleaseFinderTests.ipa)")!, size: 1000),
        trigger: "v1.1.8|\(ReleaseFinderTests.ipa)|2026-11-01T10:00:00Z")

    static func make(_ json: Data? = ReleaseFinderTests.fixture, version: String? = "1.1.8")
        -> (UpdateChecker, FakeFetcher, URL) {
        let fetcher = FakeFetcher()
        if let json { fetcher.serve(source.api.absoluteString, json) }
        fetcher.serve(found.asset.url.absoluteString, Data("x".utf8))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let checker = UpdateChecker(fetcher: fetcher, runner: NoRunner(), workDir: dir, readVersion: { _, _ in version })
        return (checker, fetcher, dir)
    }

    func src(last: String? = nil) -> UpdateSource {
        UpdateSource(repo: Self.source, variant: Self.plain, mode: .notify, lastSeenTrigger: last)
    }

    @Test func isNewer_semverOrdering() {
        #expect(UpdateChecker.isNewer("1.1.9", than: "1.1.8") == true)
        #expect(UpdateChecker.isNewer("1.10", than: "1.9") == true)
        #expect(UpdateChecker.isNewer("1.1.8", than: "1.1.9") == false)
        #expect(UpdateChecker.isNewer("1.1.8", than: "1.1.8") == false)
        #expect(UpdateChecker.isNewer("1.2", than: "1.2.0") == false)
        #expect(UpdateChecker.isNewer("1.2.1", than: "1.2") == true)
        #expect(UpdateChecker.isNewer("21.46.3", than: "v3.0") == nil)
        #expect(UpdateChecker.isNewer("abc", than: "1.0") == nil)
        #expect(UpdateChecker.isNewer("1.0", than: nil) == nil)
    }

    @Test func check_upToDateWhenTriggerUnchanged() async {
        let (c, f, _) = Self.make()
        let r = await c.check(source: src(last: Self.found.trigger), kind: .ipa, installedVersion: "1.0")
        #expect(r == .upToDate(trigger: Self.found.trigger))
        #expect(!f.fetched.contains(Self.found.asset.url))
    }

    @Test func check_availableWhenNewerStable() async {
        let (c, f, dir) = Self.make(version: "1.1.8")
        let r = await c.check(source: src(), kind: .ipa, installedVersion: "1.1.7")
        #expect(r == .available(Self.found, version: "1.1.8", stable: true))
        #expect(f.fetched.contains(Self.found.asset.url))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
    }

    @Test func check_notStableFlagsPrerelease() async {
        let json = ReleaseFinderTests.json([ReleaseFinderTests.release("v2", pre: true, [ReleaseFinderTests.asset("v2", ReleaseFinderTests.ipa)])])
        let (c, f, _) = Self.make(json)
        let url = "\(ReleaseFinderTests.base)/v2/\(ReleaseFinderTests.ipa)"
        f.serve(url, Data("x".utf8))
        let r = await c.check(source: src(), kind: .ipa, installedVersion: "1.0")
        guard case .available(let rel, let v, let stable) = r else { Issue.record("\(r)"); return }
        #expect(rel.tag == "v2"); #expect(v == "1.1.8"); #expect(stable == false)
    }

    @Test func check_upToDateWhenSameVersionDespiteNewTrigger() async {
        let (c, _, _) = Self.make(version: "1.1.8")
        let r = await c.check(source: src(last: "old|trigger"), kind: .ipa, installedVersion: "1.1.8")
        #expect(r == .upToDate(trigger: Self.found.trigger))
    }

    @Test func check_upToDateWhenNonComparable() async {
        let (c, _, _) = Self.make(version: nil)
        let r = await c.check(source: src(), kind: .ipa, installedVersion: "1.0")
        #expect(r == .upToDate(trigger: Self.found.trigger))
    }

    @Test func check_needsVariantChoiceOnAmbiguous() async {
        let (c, _, _) = Self.make()
        let other = UpdateSource(repo: Self.source, variant: VariantSelector(stableTokens: ["ytkace"], excludedTokens: []))
        let r = await c.check(source: other, kind: .ipa, installedVersion: "1.0")
        #expect(r == .needsVariantChoice)
    }

    @Test func check_failedOnFetchError() async {
        let (c, _, _) = Self.make(nil)
        let r = await c.check(source: src(), kind: .ipa, installedVersion: "1.0")
        guard case .failed = r else { Issue.record("\(r)"); return }
    }
}

private struct NoRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String], cwd: URL?, timeout: Duration) async throws -> CommandResult {
        throw CancellationError()
    }
}
