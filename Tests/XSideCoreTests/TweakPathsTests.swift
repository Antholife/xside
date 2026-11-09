import Testing
import Foundation
@testable import XSideCore

/// The jailbreak-path redirect of `XSideTweakSupport.dylib`. Its C core
/// (`App/TweakSupport/XSTweakPathsCore.c`) runs the same fixture in `scripts/test-tweak-support.sh`.
@Suite struct TweakPathsTests {
    struct Fixture: Decodable {
        struct Case: Decodable { let path: String; let expect: String?; let why: String }
        let tweaksRoot: String
        let packages: [String]
        let exists: [String]
        let cases: [Case]
        let protectedNames: [String]
    }

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tweak-paths-fixture.json")
    }

    @Test func matchesTheSharedFixture() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL))
        let present = Set(fixture.exists)
        #expect(fixture.cases.count >= 30)
        for c in fixture.cases {
            let got = TweakPaths.redirect(c.path, packages: fixture.packages, exists: { present.contains($0) },
                                          tweaksRoot: fixture.tweaksRoot)
            #expect(got == c.expect, "\(c.why): \(c.path.prefix(80))")
        }
    }

    /// The C core keeps its own copy of the list; the fixture has a case for every name.
    @Test func protectedNamesAreTheClassifiersSystemLibraries() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL))
        #expect(fixture.protectedNames == TweakClassifier.iOSUsrLibNames.sorted())
        for name in fixture.protectedNames {
            #expect(fixture.cases.contains { $0.path == "/usr/lib/\(name).dylib" && $0.expect == nil }, "\(name)")
        }
    }

    @Test func coversEveryCopiedPrefix() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL))
        let redirected = fixture.cases.filter { $0.expect != nil }.map(\.path)
        for prefix in TweakAnalyzer.copiedPrefixes {
            #expect(redirected.contains { $0.hasPrefix("/" + prefix) || $0.hasPrefix("/var/jb/" + prefix) }, "\(prefix)")
        }
    }

    @Test func neverAsksAboutPathsItWouldRefuse() {
        var asked: [String] = []
        for path in ["/Library/../etc/passwd", "/private/var/mobile/x", "relative/path", "/var/jb", "/etc/hosts"] {
            _ = TweakPaths.redirect(path, packages: ["0123456789abcdef"], exists: { asked.append($0); return true },
                                    tweaksRoot: "/App.app/Frameworks/XSideTweaks")
        }
        #expect(asked.isEmpty)
    }

    @Test func aRootThatIsNotAbsoluteRedirectsNothing() {
        #expect(TweakPaths.redirect("/Library/Application Support/T/a.png", packages: ["0123456789abcdef"],
                                    exists: { _ in true }, tweaksRoot: "App.app/Frameworks/XSideTweaks") == nil)
        #expect(TweakPaths.redirect("/Library/Application Support/T/a.png", packages: ["0123456789abcdef"],
                                    exists: { _ in true }, tweaksRoot: "") == nil)
    }

    @Test func aPathWithANulByteIsRefused() {
        #expect(TweakPaths.redirect("/Library/Application Support/T/a\0.png", packages: ["0123456789abcdef"],
                                    exists: { _ in true }, tweaksRoot: "/R") == nil)
    }
}
