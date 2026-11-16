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

    @Test func applied_requiresStoredVersionToMatch() {
        #expect(UpdateApply.applied(storedVersion: "2.0", expected: "2.0"))
        #expect(!UpdateApply.applied(storedVersion: "1.0", expected: "2.0"))
        #expect(!UpdateApply.applied(storedVersion: nil, expected: "2.0"))
        #expect(UpdateApply.applied(storedVersion: nil, expected: nil))
        #expect(!UpdateApply.applied(storedVersion: "1.0", expected: nil))
    }

    @Test func tweakAutoAllowed_trueOnCompatibleStable() {
        #expect(UpdateApply.tweakAutoAllowed(verdict: .compatible, stable: true))
    }
    @Test func tweakAutoAllowed_trueOnConverted() {
        #expect(UpdateApply.tweakAutoAllowed(verdict: .converted([]), stable: true))
    }
    @Test func tweakAutoAllowed_falseOnIncompatible() {
        #expect(!UpdateApply.tweakAutoAllowed(verdict: .incompatible(.notForIOS), stable: true))
    }
    @Test func tweakAutoAllowed_falseOnPrerelease() {
        #expect(!UpdateApply.tweakAutoAllowed(verdict: .compatible, stable: false))
        #expect(!UpdateApply.tweakAutoAllowed(verdict: .converted([]), stable: false))
    }
    @Test func packageIDMatches_exact() {
        #expect(UpdateApply.packageIDMatches("com.a.tweak", oldPackageID: "com.a.tweak"))
        #expect(!UpdateApply.packageIDMatches("com.a.tweak2", oldPackageID: "com.a.tweak"))
        #expect(!UpdateApply.packageIDMatches("com.a.Tweak", oldPackageID: "com.a.tweak"))
    }
}
