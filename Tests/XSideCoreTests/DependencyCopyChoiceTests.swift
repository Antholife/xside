import Foundation
import Testing
@testable import XSideCore

/// Device test of round 3, F2 and F3: which copy of a dependency an installation uses (XSide's
/// embedded one unless it can't serve every tweak there; a .deb the person added still wins),
/// and the copies a removed tweak leaves behind.
struct DependencyCopyChoiceTests {
    typealias D = DependencyDirectoryTests
    static let atLeast1 = DebDependency(package: "ws.hbang.common", relation: ">=", version: "1.0")
    static let atLeast2 = DebDependency(package: "ws.hbang.common", relation: ">=", version: "2.0")
    static let below2 = DebDependency(package: "ws.hbang.common", relation: "<<", version: "2.0")

    static func tweak(_ id: String, _ name: String, needs: DebDependency) -> TweakPackage {
        let base = D.tweak(depends: [])
        return TweakPackage(id: id, kind: .deb, origin: .added, packageID: "com.example.\(name.lowercased())", name: name,
                            depends: [[needs]], files: base.files, binaries: base.binaries, addedAt: Date(timeIntervalSince1970: 0))
    }

    static func cephei(_ id: String, version: String, origin: TweakOrigin) -> TweakPackage {
        let b = TweakBinary(path: "usr/lib/libcephei.dylib", isEntry: false, filter: nil,
                            slices: [TweakSlice(arch: "arm64", platform: 2, minOS: "15.0")], linked: [],
                            mentionsJailbreakPaths: false, imageName: "libcephei.dylib")
        return TweakPackage(id: id, kind: .deb, origin: origin, packageID: "ws.hbang.common", name: "Cephei", version: version,
                            files: [b.path], binaries: [b], addedAt: Date(timeIntervalSince1970: 0))
    }

    static let embedded = cephei("ws.hbang.common", version: "2.0", origin: .embedded)
    static let downloaded = cephei("00000000000000d1", version: "1.17.1",
                                   origin: .downloaded(repo: "chariz", url: "u", sha256: String(repeating: "c", count: 64)))
    static let added = cephei("00000000000000e1", version: "1.17.1", origin: .added)
    static let toto = tweak("00000000000000t1", "Toto", needs: atLeast1)
    static let tata = tweak("00000000000000t2", "Tata", needs: below2)

    static func context(_ others: [TweakPackage]) -> TweakContext {
        TweakContext(originalBundleID: "com.example.app", executableName: "Example", deviceOS: "17.5",
                     others: others, embedded: [embedded])
    }

    static func status(_ p: TweakPackage, _ others: [TweakPackage]) -> DependencyStatus? {
        TweakClassifier.dependencies(p, context(others)).first?.1
    }

    @Test func aDownloadedCopyServesOnlyWhileXSidesCannot() {
        // toto alone: XSide's 2.0.
        #expect(Self.status(Self.toto, []) == .providedByXSide("Cephei 2.0"))
        // tata added (< 2.0) with the downloaded 1.17.1: one copy for both, the download.
        #expect(Self.status(Self.toto, [Self.tata, Self.downloaded]) == .addedByYou("Cephei"))
        #expect(Self.status(Self.tata, [Self.toto, Self.downloaded]) == .addedByYou("Cephei"))
        // tata removed, the download still there: toto is back on XSide's copy.
        #expect(Self.status(Self.toto, [Self.downloaded]) == .providedByXSide("Cephei 2.0"))
        #expect(TweakClassifier.verdict(Self.toto, Self.context([Self.downloaded])) != .incompatible(.missingDependency("Cephei")))
    }

    /// Retest, G2: XSide's copy is named with the version it embeds (from its package.json).
    @Test func xSidesCopyIsNamedWithItsVersion() {
        let c = TweakClassifier.classify(Self.toto, Self.context([]))
        #expect(c.verdict == .converted([.dependencyAdded("Cephei 2.0")]) || {
            if case .converted(let list) = c.verdict { return list.contains(.dependencyAdded("Cephei 2.0")) }
            return false
        }())
        // The conflict names the copy that was picked: XSide's, with its version.
        let toto2 = Self.tweak("00000000000000t3", "Toto", needs: Self.atLeast2)
        #expect(TweakClassifier.verdict(toto2, Self.context([Self.tata, Self.downloaded]))
                == .incompatible(.dependencyConflict("Cephei 2.0", ["≥ 2.0", "< 2.0"])))
    }

    @Test func aDebThePersonAddedStillWins() {
        #expect(Self.status(Self.toto, [Self.added]) == .addedByYou("Cephei"))
    }

    /// toto ≥ 2.0 and tata < 2.0: no copy serves both; the conflict is said on the tweaks.
    @Test func twoVersionsAskedAtOnceAreAConflict() {
        let toto2 = Self.tweak("00000000000000t3", "Toto", needs: Self.atLeast2)
        let totoVerdict = TweakClassifier.verdict(toto2, Self.context([Self.tata, Self.downloaded]))
        let tataVerdict = TweakClassifier.verdict(Self.tata, Self.context([toto2, Self.downloaded]))
        guard case .incompatible(.dependencyConflict) = totoVerdict else { Issue.record("toto: \(totoVerdict)"); return }
        guard case .incompatible(.dependencyConflict) = tataVerdict else { Issue.record("tata: \(tataVerdict)"); return }
        // « À régler » on both (each can be settled), the group rule unchanged.
        #expect(TweakGroups.group([.init(verdict: totoVerdict, isOn: true, isForced: false)]) == .toSettle)
    }

    // MARK: F3: what a removed tweak leaves

    @Test func removingATweakFreesTheCopyAddedForIt() {
        // tata removed: the download served it; toto is fine with XSide's copy.
        #expect(DependencyRows.copiesFreedByRemoving(Self.tata, listed: [Self.toto, Self.downloaded],
                                                     context: Self.context([])).map(\.id) == [Self.downloaded.id])
        // Another tweak there still needs < 2.0: kept.
        let other = Self.tweak("00000000000000t4", "Other", needs: Self.below2)
        #expect(DependencyRows.copiesFreedByRemoving(Self.tata, listed: [Self.toto, other, Self.downloaded],
                                                     context: Self.context([])).isEmpty)
        // A .deb the person added is theirs: never taken away with a tweak.
        #expect(DependencyRows.copiesFreedByRemoving(Self.tata, listed: [Self.added], context: Self.context([])).isEmpty)
        // A tweak that didn't need it frees nothing.
        let plain = TweakPackage(id: "00000000000000p1", kind: .deb, origin: .added, packageID: "com.example.plain",
                                 name: "Plain", files: D.tweak(depends: []).files, binaries: D.tweak(depends: []).binaries,
                                 addedAt: Date(timeIntervalSince1970: 0))
        #expect(DependencyRows.copiesFreedByRemoving(plain, listed: [Self.tata, Self.downloaded], context: Self.context([])).isEmpty)
    }
}

/// Retest, G1: a dependency's green result line says what was added for which tweak; it goes
/// once that no longer holds (the tweak removed, or the copy gone from the pool).
struct DependencyNoticeTests {
    @Test func aResultHoldsWhileTheTweakAndTheCopyAreThere() {
        let notice = DependencyNoticeSubject(tweakID: "tweak", packageID: "copy")
        #expect(notice.holds(present: ["tweak", "copy", "other"]))
        #expect(!notice.holds(present: ["copy"]))   // the tweak was removed
        #expect(!notice.holds(present: ["tweak"]))  // the copy left the pool
        // « à jour » names no copy: only the card it was asked on counts.
        #expect(DependencyNoticeSubject(tweakID: "dep", packageID: nil).holds(present: ["dep"]))
        #expect(!DependencyNoticeSubject(tweakID: "dep", packageID: nil).holds(present: []))
    }
}
