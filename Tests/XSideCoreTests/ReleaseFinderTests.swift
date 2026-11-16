import Testing
import Foundation
@testable import XSideCore

@Suite struct ReleaseFinderTests {
    static let source = GitHubSource(owner: "dayanch96", repo: "YTKACE")
    static let base = "https://github.com/dayanch96/YTKACE/releases/download"

    static func asset(_ tag: String, _ name: String, size: Int = 1000, updated: String = "2026-11-01T10:00:00Z",
                      url: String? = nil) -> String {
        """
        {"name":"\(name)","size":\(size),"browser_download_url":"\(url ?? "\(base)/\(tag)/\(name)")","updated_at":"\(updated)"}
        """
    }

    static func release(_ tag: String, draft: Bool = false, pre: Bool = false, _ assets: [String]) -> String {
        """
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(pre),"assets":[\(assets.joined(separator: ","))]}
        """
    }

    static func json(_ releases: [String]) -> Data { Data("[\(releases.joined(separator: ","))]".utf8) }

    static let ipa = "YTKACE_1.1.8_YouTube_21.46.3.ipa"
    static let ipa16 = "YTKACE_1.1.8_YouTube_21.46.3_iOS16.ipa"
    static let rootless = "com.dvntm.ytkace_1.1.8_iphoneos-arm64_rootless.deb"
    static let roothide = "com.dvntm.ytkace_1.1.8_iphoneos-arm64e_roothide.deb"

    /// draft (newest), the real release, an older one.
    static let fixture = json([
        release("v1.1.9", draft: true, [asset("v1.1.9", "YTKACE_1.1.9_YouTube_21.47.0.ipa")]),
        release("v1.1.8", [asset("v1.1.8", ipa), asset("v1.1.8", ipa16),
                           asset("v1.1.8", rootless), asset("v1.1.8", roothide),
                           asset("v1.1.8", "notes.txt")]),
        release("v1.1.7", [asset("v1.1.7", "YTKACE_1.1.7_YouTube_21.45.0.ipa")]),
    ])

    static let plain = VariantSelector.make(chosen: ipa, others: [ipa16])

    @Test func installableAssets_filtersByKind_skipsDrafts_newestFirst() throws {
        let found = try ReleaseFinder.installableAssets(Self.fixture, source: Self.source, kind: .ipa)
        #expect(found.map(\.tag) == ["v1.1.8", "v1.1.8", "v1.1.7"])
        #expect(found.map(\.asset.name) == [Self.ipa, Self.ipa16, "YTKACE_1.1.7_YouTube_21.45.0.ipa"])
        #expect(found.allSatisfy { !$0.isPrerelease })
        let debs = try ReleaseFinder.installableAssets(Self.fixture, source: Self.source, kind: .deb)
        #expect(debs.map(\.asset.name) == [Self.rootless, Self.roothide])
    }

    @Test func installableAssets_readsPrerelease() throws {
        let data = Self.json([Self.release("v2", pre: true, [Self.asset("v2", Self.ipa)])])
        let found = try ReleaseFinder.installableAssets(data, source: Self.source, kind: .ipa)
        #expect(found.map(\.isPrerelease) == [true])
    }

    @Test func choose_picksMatchingVariant() throws {
        let r = try ReleaseFinder.choose(Self.fixture, source: Self.source, kind: .ipa, variant: Self.plain)
        guard case .found(let f) = r else { Issue.record("not found: \(r)"); return }
        #expect(f.tag == "v1.1.8")
        #expect(f.isPrerelease == false)
        #expect(f.asset.name == Self.ipa)
        #expect(f.asset.size == 1000)
        #expect(f.trigger == "v1.1.8|\(Self.ipa)|2026-11-01T10:00:00Z")
    }

    @Test func choose_ambiguousWhenTwoMatch() throws {
        // `ios16` alone is a stable token of neither IPA name only; "ytkace" matches both.
        let loose = VariantSelector(stableTokens: ["ytkace"], excludedTokens: [])
        let r = try ReleaseFinder.choose(Self.fixture, source: Self.source, kind: .ipa, variant: loose)
        guard case .ambiguous(let assets) = r else { Issue.record("not ambiguous: \(r)"); return }
        #expect(assets.map(\.name) == [Self.ipa, Self.ipa16])
    }

    @Test func choose_noneWhenNoMatch() throws {
        let v = VariantSelector(stableTokens: ["nothing"], excludedTokens: [])
        #expect(try ReleaseFinder.choose(Self.fixture, source: Self.source, kind: .ipa, variant: v) == .none)
        #expect(try ReleaseFinder.choose(Data("not json".utf8), source: Self.source, kind: .ipa, variant: Self.plain) == .none)
        #expect(try ReleaseFinder.choose(Data("[]".utf8), source: Self.source, kind: .ipa, variant: Self.plain) == .none)
    }

    @Test func choose_looksInOlderReleaseWhenNewestHasNoMatch() throws {
        let data = Self.json([
            Self.release("v3", [Self.asset("v3", Self.ipa16)]),
            Self.release("v2", [Self.asset("v2", Self.ipa)]),
        ])
        let r = try ReleaseFinder.choose(data, source: Self.source, kind: .ipa, variant: Self.plain)
        guard case .found(let f) = r else { Issue.record("not found: \(r)"); return }
        #expect(f.tag == "v2")
    }

    @Test func choose_followsPrereleaseButFlagsIt() throws {
        let data = Self.json([
            Self.release("v1.2.0-beta", pre: true, [Self.asset("v1.2.0-beta", Self.ipa)]),
            Self.release("v1.1.8", [Self.asset("v1.1.8", Self.ipa)]),
        ])
        let r = try ReleaseFinder.choose(data, source: Self.source, kind: .ipa, variant: Self.plain)
        guard case .found(let f) = r else { Issue.record("not found: \(r)"); return }
        #expect(f.tag == "v1.2.0-beta")
        #expect(f.isPrerelease == true)
    }

    @Test func choose_rejectsAssetFromForeignHost() throws {
        let evil = "https://evil.example/dayanch96/YTKACE/releases/download/v2/\(Self.ipa)"
        let data = Self.json([
            Self.release("v2", [Self.asset("v2", Self.ipa, url: evil)]),
            Self.release("v1", [Self.asset("v1", Self.ipa)]),
        ])
        let all = try ReleaseFinder.installableAssets(data, source: Self.source, kind: .ipa)
        #expect(all.map(\.tag) == ["v1"])
        let r = try ReleaseFinder.choose(data, source: Self.source, kind: .ipa, variant: Self.plain)
        guard case .found(let f) = r else { Issue.record("not found: \(r)"); return }
        #expect(f.tag == "v1")
    }

    @Test func installableAssets_dropsZeroSize() throws {
        let data = Self.json([Self.release("v2", [Self.asset("v2", Self.ipa, size: 0)])])
        #expect(try ReleaseFinder.installableAssets(data, source: Self.source, kind: .ipa).isEmpty)
    }
}
