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
        #expect(UpdateApply.tweakAutoAllowed(verdict: .compatible, stable: true, hasSigns: false))
    }
    @Test func tweakAutoAllowed_trueOnConverted() {
        #expect(UpdateApply.tweakAutoAllowed(verdict: .converted([]), stable: true, hasSigns: false))
    }
    @Test func tweakAutoAllowed_falseOnIncompatible() {
        #expect(!UpdateApply.tweakAutoAllowed(verdict: .incompatible(.notForIOS), stable: true, hasSigns: false))
    }
    @Test func tweakAutoAllowed_falseOnPrerelease() {
        #expect(!UpdateApply.tweakAutoAllowed(verdict: .compatible, stable: false, hasSigns: false))
        #expect(!UpdateApply.tweakAutoAllowed(verdict: .converted([]), stable: false, hasSigns: false))
    }
    @Test func tweakAutoAllowed_falseWhenSigns() {
        #expect(!UpdateApply.tweakAutoAllowed(verdict: .compatible, stable: true, hasSigns: true))
        #expect(!UpdateApply.tweakAutoAllowed(verdict: .converted([]), stable: true, hasSigns: true))
    }
    @Test func tweakWarningSigns_scanOfMachO() {
        let bad = ContentMachO.build(imports: ["_MSHookMessageEx"], strings: ["https://discord.com/api/webhooks/1"], signed: false)
        #expect(IPAContentScanner.warningSigns(machO: bad) == [.discordWebhook])
        let clean = ContentMachO.build(imports: ["_MSHookMessageEx"], signed: false)
        #expect(IPAContentScanner.warningSigns(machO: clean).isEmpty)
    }
    @Test func packageIDMatches_exact() {
        #expect(UpdateApply.packageIDMatches("com.a.tweak", oldPackageID: "com.a.tweak"))
        #expect(!UpdateApply.packageIDMatches("com.a.tweak2", oldPackageID: "com.a.tweak"))
        #expect(!UpdateApply.packageIDMatches("com.a.Tweak", oldPackageID: "com.a.tweak"))
    }

    // MARK: whole-package scan on a real analyzer layout

    private func lone(_ data: Data, storage: URL) async throws -> TweakPackage {
        let src = storage.deletingLastPathComponent().appendingPathComponent("Lone-\(UUID().uuidString).dylib")
        try data.write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }
        return try await TweakAnalyzer.analyze(src, into: storage, runner: ProcessRunner(), now: Date())
    }

    @Test func packageScan_findsASignThroughTheAnalyzersLayout() async throws {
        try await withTemporaryDirectory("scan") { dir in
            let storage = dir.appendingPathComponent("store")
            let bad = ContentMachO.build(imports: ["_MSHookMessageEx"], strings: ["https://discord.com/api/webhooks/1"], signed: false)
            let package = try await lone(bad, storage: storage)
            #expect(!package.binaries.isEmpty)
            let scan = IPAContentScanner.warningScan(of: package, in: storage)
            #expect(scan.complete)
            #expect(scan.signs == [.discordWebhook])
        }
    }

    @Test func packageScan_cleanIsComplete() async throws {
        try await withTemporaryDirectory("scan") { dir in
            let storage = dir.appendingPathComponent("store")
            let package = try await lone(ContentMachO.build(imports: ["_MSHookMessageEx"], signed: false), storage: storage)
            let scan = IPAContentScanner.warningScan(of: package, in: storage)
            #expect(scan.isClean)
        }
    }

    @Test func packageScan_missingBinaryOrNoBinariesIsIncomplete() async throws {
        try await withTemporaryDirectory("scan") { dir in
            let storage = dir.appendingPathComponent("store")
            var package = try await lone(ContentMachO.build(imports: ["_MSHookMessageEx"], signed: false), storage: storage)
            // A binary that is not where the scanner looks.
            package.binaries[0].path = "nowhere/missing.dylib"
            let missing = IPAContentScanner.warningScan(of: package, in: storage)
            #expect(!missing.complete)
            #expect(!missing.isClean)
            package.binaries = []
            let none = IPAContentScanner.warningScan(of: package, in: storage)
            #expect(!none.complete)
            #expect(!none.isClean)
            // Wrong storage root: nothing resolves.
            #expect(!IPAContentScanner.warningScan(of: package, in: dir.appendingPathComponent("other")).isClean)
        }
    }
}
