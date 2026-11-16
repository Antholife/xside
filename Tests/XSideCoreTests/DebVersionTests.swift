import Testing
import Foundation
@testable import XSideCore

@Suite struct DebVersionTests {
    static func lt(_ a: String, _ b: String) -> Bool {
        DebVersion.compare(a, b) == .orderedAscending && DebVersion.compare(b, a) == .orderedDescending
    }
    static func eq(_ a: String, _ b: String) -> Bool {
        DebVersion.compare(a, b) == .orderedSame && DebVersion.compare(b, a) == .orderedSame
    }

    @Test func basicNumeric() {
        #expect(Self.lt("1.0", "1.1"))
        #expect(Self.eq("1.0", "1.0"))
        #expect(Self.lt("1.9", "1.10"))
        #expect(Self.lt("1.0", "1.0.1"))
    }

    @Test func revisions() {
        #expect(Self.lt("1.0-1", "1.0-2"))
        #expect(Self.lt("1.0", "1.0-1"))
        #expect(Self.lt("1.0-1", "1.1"))
        #expect(Self.lt("1.1.8-1", "1.1.8-2"))
        #expect(Self.lt("1.1.8", "1.1.9-1"))
        #expect(Self.eq("1.0-0", "1.0"))
        // the revision is the part after the LAST dash
        #expect(Self.lt("1.0-1-1", "1.0-1-2"))
        #expect(Self.lt("1.0-2", "1.0-1-1"))  // upstream "1.0" < "1.0-1"
    }

    @Test func tilde() {
        #expect(Self.lt("1.0~beta", "1.0"))
        #expect(Self.lt("1.0~~", "1.0~"))
        #expect(Self.lt("1.0~", "1.0"))
        #expect(Self.lt("1.0~~", "1.0"))
        #expect(Self.lt("1.0~rc1", "1.0"))
        #expect(Self.lt("1.0~rc1", "1.0~rc2"))
        #expect(Self.lt("1.0~beta", "1.0~rc"))
        #expect(Self.lt("1.0~beta-1", "1.0-1"))
    }

    @Test func epoch() {
        #expect(Self.lt("1:9.9", "2:1.0"))
        #expect(Self.lt("1.0", "1:1.0"))
        #expect(Self.eq("0:1.0", "1.0"))
        #expect(Self.lt("1:1.0", "1:1.1"))
        #expect(Self.lt("1:1.0", "1:1.0-1"))
        #expect(Self.lt("9.9", "1:0.1"))
    }

    @Test func lettersAndMixed() {
        #expect(Self.lt("1.0a", "1.0b"))
        #expect(Self.lt("1.0", "1.0alpha"))
        #expect(Self.lt("1.0", "1.0a"))
        #expect(Self.lt("1.0a", "1.0+"))      // punctuation sorts after letters
        #expect(Self.lt("1.0a", "1.0.1"))     // '.' (+256) sorts after letters
        #expect(Self.lt("1.a", "1.1") == false)
        #expect(Self.lt("1.1", "1.a"))        // digit chunk vs alpha: "" < "a"
        #expect(Self.lt("1a1", "1a2"))
        #expect(Self.lt("1.0a", "1.0a1"))
        #expect(Self.lt("1.0+git1", "1.0+git2"))
    }

    @Test func leadingZeros() {
        #expect(Self.eq("1.01", "1.1"))
        #expect(Self.lt("1.002", "1.10"))
        #expect(Self.eq("1.0", "1.00"))
    }

    @Test func garbage() {
        #expect(DebVersion.compare("", "1.0") == nil)
        #expect(DebVersion.compare("1.0", "") == nil)
        #expect(DebVersion.compare("  ", "1.0") == nil)
        #expect(DebVersion.compare("x:1.0", "1.0") == nil)
        #expect(DebVersion.compare("1:", "1.0") == nil)
        #expect(DebVersion.compare("1.0-", "1.0") == nil)
        #expect(DebVersion.compare("-1", "1.0") == nil)
        #expect(DebVersion.compare("-1:2", "1.0") == nil)
    }
}
