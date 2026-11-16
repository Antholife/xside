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
}
