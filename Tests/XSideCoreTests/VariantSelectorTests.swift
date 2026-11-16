import Foundation
import Testing
@testable import XSideCore

@Suite struct VariantSelectorTests {
    @Test func tokens_dropsVersionsKeepsDistinguishers() {
        #expect(VariantSelector.tokens("YTKACE_1.1.8_YouTube_21.46.3.ipa") == ["ytkace", "youtube"])
        #expect(VariantSelector.tokens("YTKACE_1.1.8_YouTube_iOS16_21.33.6.ipa") == ["ytkace", "youtube", "ios16"])
    }

    @Test func make_excludesTokensOfOtherVariant() {
        let s = VariantSelector.make(chosen: "YTKACE_1.1.8_YouTube_21.46.3.ipa",
                                     others: ["YTKACE_1.1.8_YouTube_iOS16_21.33.6.ipa"])
        #expect(s.stableTokens == ["youtube", "ytkace"])
        #expect(s.excludedTokens.contains("ios16"))
    }

    @Test func matches_picksSameVariantNextRelease() {
        let s = VariantSelector.make(chosen: "YTKACE_1.1.8_YouTube_21.46.3.ipa",
                                     others: ["YTKACE_1.1.8_YouTube_iOS16_21.33.6.ipa"])
        #expect(s.matches("YTKACE_1.1.9_YouTube_21.47.0.ipa"))
        #expect(!s.matches("YTKACE_1.1.9_YouTube_iOS16_21.34.0.ipa"))
    }

    @Test func matches_debVariant() {
        let s = VariantSelector.make(chosen: "tweak_1.0_iphoneos-arm64_rootless.deb",
                                     others: ["tweak_1.0_iphoneos-arm64_roothide.deb"])
        #expect(s.matches("tweak_1.1_iphoneos-arm64_rootless.deb"))
        #expect(!s.matches("tweak_1.1_iphoneos-arm64_roothide.deb"))
    }

    @Test func matches_falseWhenNoStableTokens() {
        let s = VariantSelector(stableTokens: [], excludedTokens: [])
        #expect(!s.matches("anything_1.0.ipa"))
    }

    private let source = UpdateSource(
        repo: GitHubSource(owner: "o", repo: "r"),
        variant: VariantSelector(stableTokens: ["a"], excludedTokens: ["b"]),
        mode: .auto, lastSeenTrigger: "v1")

    private func package() -> TweakPackage {
        TweakPackage(id: "x", kind: .deb, origin: .added, packageID: "p", name: "N",
                     addedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func updateSource_codableRoundTrips() throws {
        let back = try JSONDecoder().decode(UpdateSource.self, from: JSONEncoder().encode(source))
        #expect(back == source)
        var p = package(); p.updateSource = source
        #expect(try JSONDecoder().decode(TweakPackage.self, from: JSONEncoder().encode(p)).updateSource == source)
    }

    @Test func tweakPackage_survivesMalformedUpdateSource() throws {
        var p = package(); p.updateSource = source
        var obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        obj["updateSource"] = "garbage"
        let d = try JSONDecoder().decode(TweakPackage.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(d.updateSource == nil)
        #expect(d.id == "x")
    }

    @Test func oldRecordWithoutUpdateSource_decodes() throws {
        let t = try JSONDecoder().decode(TweakPackage.self, from: JSONEncoder().encode(package()))
        #expect(t.updateSource == nil)
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","originalBundleID":"com.a","ipaPath":"a.ipa"}"#
        let r = try JSONDecoder().decode(AppRecord.self, from: Data(json.utf8))
        #expect(r.updateSource == nil)
    }
}
