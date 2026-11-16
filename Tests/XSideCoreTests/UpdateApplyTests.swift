import Foundation
import Testing
@testable import XSideCore

@Suite struct UpdateApplyTests {
    private func content(signs: [WarningSign]) -> IPAContent {
        IPAContent(additions: [IPAAddition(name: "x", path: "Frameworks/x.dylib", size: 1, load: .launch, kind: .tweak,
                                       hasMetadata: true, signs: signs)],
                   accesses: [])
    }

    @Test func autoAllowed_trueOnCleanStable() {
        #expect(UpdateApply.autoAllowed(content: content(signs: []), stable: true))
    }
    @Test func autoAllowed_falseOnWarningSign() {
        #expect(!UpdateApply.autoAllowed(content: content(signs: [.discordWebhook]), stable: true))
    }
    @Test func autoAllowed_falseOnPrerelease() {
        #expect(!UpdateApply.autoAllowed(content: content(signs: []), stable: false))
    }
    @Test func autoAllowed_falseOnNilContent() {
        #expect(!UpdateApply.autoAllowed(content: nil, stable: true))
    }
    @Test func bundleIDMatches_exact() {
        #expect(UpdateApply.bundleIDMatches("com.a.b", originalBundleID: "com.a.b"))
        #expect(!UpdateApply.bundleIDMatches("com.a.b", originalBundleID: "com.a.B"))
        #expect(!UpdateApply.bundleIDMatches("com.a.b2", originalBundleID: "com.a.b"))
    }
}
