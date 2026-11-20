import Testing
import Foundation
@testable import XSideCore

@Suite struct UpdateCheckerTests {
    static let source = ReleaseFinderTests.source
    static let plain = ReleaseFinderTests.plain
    /// The newest non-draft release matching `plain` in the fixture.
    static let newestTag = "v1.1.8"

    static func make(_ json: Data? = ReleaseFinderTests.fixture) -> (UpdateChecker, FakeFetcher, URL) {
        let fetcher = FakeFetcher()
        if let json { fetcher.serve(source.api.absoluteString, json) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (UpdateChecker(fetcher: fetcher, workDir: dir), fetcher, dir)
    }

    func src(installed: String? = nil, trigger: String? = nil) -> UpdateSource {
        UpdateSource(repo: Self.source, variant: Self.plain, mode: .notify, installedTag: installed, installedTrigger: trigger)
    }

    /// The fixture's newest release trigger (`tag|asset|updatedAt`).
    static let newestTrigger = "v1.1.8|\(ReleaseFinderTests.ipa)|2026-11-01T10:00:00Z"

    // MARK: Tag-based detection

    @Test func check_availableWhenNewestTagDiffersFromBaseline() async {
        let (c, f, _) = Self.make()
        let r = await c.check(source: src(installed: "v1.1.7"), kind: .ipa)
        guard case .available(let found, let version, let stable) = r else { Issue.record("\(r)"); return }
        #expect(found.tag == Self.newestTag)
        #expect(version == "1.1.8") // the tag, « v » dropped
        #expect(stable == true)
        // The check only reads the release list — it never downloads the asset.
        #expect(f.fetched == [Self.source.api])
    }

    @Test func check_upToDateWhenOnNewestTag() async {
        let (c, f, _) = Self.make()
        let r = await c.check(source: src(installed: Self.newestTag), kind: .ipa)
        #expect(r == .upToDate(trigger: "v1.1.8|\(ReleaseFinderTests.ipa)|2026-11-01T10:00:00Z"))
        #expect(f.fetched == [Self.source.api])
    }

    @Test func check_perDeviceBaselineOverridesTheSource() async {
        // The source's shared baseline is the newest tag (would be up to date), but THIS device is on
        // an older one: the override wins, so it's an update for that device (Anthony's iPhone v1 /
        // iPad v0 case).
        let (c, _, _) = Self.make()
        let r = await c.check(source: src(installed: Self.newestTag), kind: .ipa, installedTag: "v1.1.7")
        guard case .available(let found, _, _) = r else { Issue.record("\(r)"); return }
        #expect(found.tag == Self.newestTag)
    }

    @Test func check_perDeviceOnNewestIsUpToDateEvenIfSourceIsOlder() async {
        // The reverse: the source's shared baseline is older, but THIS device is on the newest.
        let (c, _, _) = Self.make()
        let r = await c.check(source: src(installed: "v1.1.7"), kind: .ipa, installedTag: Self.newestTag)
        guard case .upToDate = r else { Issue.record("\(r)"); return }
    }

    @Test func check_upToDateWhenSameTagAndSameTrigger() async {
        let (c, _, _) = Self.make()
        let r = await c.check(source: src(installed: "v1.1.8", trigger: Self.newestTrigger), kind: .ipa)
        guard case .upToDate = r else { Issue.record("\(r)"); return }
    }

    @Test func check_availableWhenSameTagButTriggerDiffers() async {
        // Rolling tag (e.g. `nightly`): same tag name, but a new build (trigger changed).
        let (c, _, _) = Self.make()
        let r = await c.check(source: src(installed: "v1.1.8", trigger: "v1.1.8|old.ipa|2025-01-01T00:00:00Z"), kind: .ipa)
        guard case .available(let found, _, _) = r else { Issue.record("\(r)"); return }
        #expect(found.tag == "v1.1.8")
    }

    @Test func check_upToDateWhenSameTagAndNoTriggerBaselineYet() async {
        // No trigger baseline learned yet: never a false update; the caller adopts the current one.
        let (c, _, _) = Self.make()
        guard case .upToDate = await c.check(source: src(installed: "v1.1.8", trigger: nil), kind: .ipa) else {
            Issue.record("expected upToDate"); return
        }
    }

    @Test func check_upToDateWhenNoBaseline() async {
        // No installedTag (older data): we can't tell, so never a false update.
        let (c, _, _) = Self.make()
        let r = await c.check(source: src(installed: nil), kind: .ipa)
        guard case .upToDate = r else { Issue.record("\(r)"); return }
    }

    @Test func check_prereleaseIsAvailableButNotStable() async {
        let json = ReleaseFinderTests.json([
            ReleaseFinderTests.release("v2", pre: true, [ReleaseFinderTests.asset("v2", ReleaseFinderTests.ipa)]),
            ReleaseFinderTests.release("v1.1.8", [ReleaseFinderTests.asset("v1.1.8", ReleaseFinderTests.ipa)]),
        ])
        let (c, _, _) = Self.make(json)
        let r = await c.check(source: src(installed: "v1.1.8"), kind: .ipa)
        guard case .available(let found, let v, let stable) = r else { Issue.record("\(r)"); return }
        #expect(found.tag == "v2"); #expect(v == "2"); #expect(stable == false)
    }

    @Test func check_needsVariantChoiceOnAmbiguous() async {
        let (c, _, _) = Self.make()
        let loose = UpdateSource(repo: Self.source, variant: VariantSelector(stableTokens: ["ytkace"], excludedTokens: []),
                                 installedTag: "v1.1.7")
        let r = await c.check(source: loose, kind: .ipa)
        #expect(r == .needsVariantChoice)
    }

    @Test func check_upToDateWhenNoMatchingAsset() async {
        let (c, _, _) = Self.make()
        let s = UpdateSource(repo: Self.source, variant: VariantSelector(stableTokens: ["nothing"], excludedTokens: []),
                             installedTag: "v1.1.7")
        guard case .upToDate = await c.check(source: s, kind: .ipa) else { Issue.record("expected upToDate"); return }
    }

    @Test func check_failedOnFetchError() async {
        let (c, _, _) = Self.make(nil) // nothing served for the api
        guard case .failed = await c.check(source: src(installed: "v1"), kind: .ipa) else { Issue.record("expected failed"); return }
    }

    @Test func displayTag_dropsLeadingV() {
        #expect(UpdateChecker.displayTag("v1.1.8") == "1.1.8")
        #expect(UpdateChecker.displayTag("V2.0") == "2.0")
        #expect(UpdateChecker.displayTag("1.1.8") == "1.1.8")
        #expect(UpdateChecker.displayTag("") == "")
    }

    // MARK: Version helpers (used by the install downgrade guard)

    @Test func isNewer_semverOrdering() {
        #expect(UpdateChecker.isNewer("1.1.9", than: "1.1.8") == true)
        #expect(UpdateChecker.isNewer("1.10", than: "1.9") == true)
        #expect(UpdateChecker.isNewer("1.1.8", than: "1.1.9") == false)
        #expect(UpdateChecker.isNewer("1.1.8", than: "1.1.8") == false)
        #expect(UpdateChecker.isNewer("1.2", than: "1.2.0") == false)
        #expect(UpdateChecker.isNewer("1.2.1", than: "1.2") == true)
        #expect(UpdateChecker.isNewer("21.46.3", than: "v3.0") == nil)
        #expect(UpdateChecker.isNewer("1.0", than: nil) == nil)
    }

    @Test func isDowngrade_onlyWhenInstalledStrictlyNewer() {
        #expect(UpdateChecker.isDowngrade(installed: "21.46.3", candidate: "21.44.4"))
        #expect(!UpdateChecker.isDowngrade(installed: "21.44.4", candidate: "21.46.3"))
        #expect(!UpdateChecker.isDowngrade(installed: "21.44.4", candidate: "21.44.4"))
        #expect(!UpdateChecker.isDowngrade(installed: nil, candidate: "1.0"))
        #expect(!UpdateChecker.isDowngrade(installed: "1.0", candidate: nil))
    }

    @Test func isNewer_trimsNewline() {
        #expect(UpdateChecker.isNewer("1.2.0\n", than: "1.1") == true)
    }
}
