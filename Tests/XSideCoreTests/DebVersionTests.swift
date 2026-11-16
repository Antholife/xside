import Foundation
import Testing
@testable import XSideCore

struct DebVersionTests {
    @Test(arguments: [
        ("1.16", "2.0", ComparisonResult.orderedAscending),
        ("1.15.3", "1.16", .orderedAscending),
        ("1:0.1", "9.9", .orderedDescending),
        ("1.0~beta1", "1.0", .orderedAscending),
        ("1.0~~", "1.0~", .orderedAscending),
        ("1.0-1", "1.0-2", .orderedAscending),
        ("1.0a", "1.0", .orderedDescending),
        ("1.0a", "1.0+", .orderedAscending),
        ("1.01", "1.1", .orderedSame),
        ("1.9", "1.10", .orderedAscending),
        ("1.0", "1.0-0", .orderedSame),
        ("0:1.0", "1.0", .orderedSame),
        ("2:1.0", "1:9.0", .orderedDescending),
        ("1.0-1-2", "1.0-1-10", .orderedAscending),
        ("a:1", "1", .orderedDescending),
        ("1.0.1", "1.0", .orderedDescending),
        ("1.0~rc1-1", "1.0-1", .orderedAscending),
        ("", "0", .orderedSame),
        ("99999999999999999999999999.0", "99999999999999999999999998.0", .orderedDescending),
    ])
    func order(_ a: String, _ b: String, _ expected: ComparisonResult) {
        #expect(DebVersion.compare(a, b) == expected)
        let reverse: ComparisonResult = expected == .orderedAscending ? .orderedDescending
            : expected == .orderedDescending ? .orderedAscending : .orderedSame
        #expect(DebVersion.compare(b, a) == reverse)
    }

    @Test func hugeInputsDoNotTrap() {
        let big = String(repeating: "9", count: 200_000)
        #expect(DebVersion.compare(big + ":1", "1") == .orderedDescending)
        #expect(DebVersion.compare("é~\(big)", "é") == .orderedAscending)
    }

    @Test func isSatisfiedByEachRelation() {
        func dep(_ r: String?, _ v: String?) -> DebDependency { DebDependency(package: "x", relation: r, version: v) }
        #expect(dep(">=", "1.5").isSatisfied(by: "1.5"))
        #expect(!dep(">=", "1.5").isSatisfied(by: "1.4"))
        #expect(dep("<<", "2.0").isSatisfied(by: "1.9"))
        #expect(!dep("<<", "2.0").isSatisfied(by: "2.0"))
        #expect(dep(">>", "2.0").isSatisfied(by: "2.1"))
        #expect(!dep(">>", "2.0").isSatisfied(by: "2.0"))
        #expect(dep("<=", "2.0").isSatisfied(by: "2.0"))
        #expect(!dep("<=", "2.0").isSatisfied(by: "2.1"))
        #expect(dep("=", "2.0").isSatisfied(by: "2.00"))
        #expect(!dep("=", "2.0").isSatisfied(by: "2.1"))
        #expect(dep(nil, nil).isSatisfied(by: "anything"))
    }
}

@Suite struct DebVersionDpkgCasesTests {
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
}
