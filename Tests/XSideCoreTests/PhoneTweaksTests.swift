import Testing
import Foundation
@testable import XSideCore

private func package(_ id: String, name: String, version: String? = "1.0", author: String? = "Anthony",
                     summary: String? = nil) -> TweakPackage {
    TweakPackage(id: id, kind: .deb, origin: .added, packageID: "com.example." + id, name: name, version: version,
                 author: author, summary: summary, addedAt: Date(timeIntervalSince1970: 1_800_000_000))
}

private func item(_ p: TweakPackage) -> TweakSigningItem { TweakSigningItem(package: p, directory: "/tmp/" + p.id) }

struct PhoneTweaksTests {
    /// What the app got, in load order: injected ones (converted or not), skipped ones left out,
    /// then those off on this device.
    @Test func listsTheInjectedThenTheOffOnes() {
        let a = package("a", name: "XSPivotFix", summary: "Puts the tab back.")
        let b = package("b", name: "uYouPlus", version: "3.0.5", author: "MiRO92")
        let c = package("c", name: "Skipped")
        let d = package("d", name: "Shorts Remover", version: "2.0", author: nil)
        let list = PhoneTweaks.list(items: [item(a), item(b), item(c), item(a)],
                                    results: ["a": .injected(converted: false), "b": .injected(converted: true),
                                              "c": .skipped(.noRoom)],
                                    offHere: [d])
        #expect(list == [
            PhoneTweak(name: "XSPivotFix", version: "1.0", author: "Anthony", summary: "Puts the tab back.",
                       converted: false, offHere: false),
            PhoneTweak(name: "uYouPlus", version: "3.0.5", author: "MiRO92", summary: nil, converted: true, offHere: false),
            PhoneTweak(name: "Shorts Remover", version: "2.0", author: nil, summary: nil, converted: false, offHere: true),
        ])
    }

    @Test func nothingInjectedIsAnEmptyList() {
        let d = package("d", name: "Off")
        #expect(PhoneTweaks.list(items: [], results: [:], offHere: []).isEmpty)
        // Only off (or skipped) ones: the app has no tweak, nothing is listed.
        #expect(PhoneTweaks.list(items: [item(d)], results: ["d": .skipped(.failed)], offHere: [d]).isEmpty)
    }

    /// Capped in count and in length; a blank summary or version is left out.
    @Test func capsCountAndLengths() {
        let long = String(repeating: "é", count: 5000)
        let many = (0..<100).map { package("t\($0)", name: "T\($0)") }
        let results = Dictionary(uniqueKeysWithValues: many.map { ($0.id, TweakResult.injected(converted: false)) })
        let list = PhoneTweaks.list(items: many.map(item), results: results, offHere: [package("x", name: "X")])
        #expect(list.count == PhoneTweaks.maxCount)
        #expect(list.count == 64)
        #expect(list.allSatisfy { !$0.offHere })
        let big = package("b", name: long, version: long, author: long, summary: long)
        let blank = package("c", name: "C", version: "  ", author: "", summary: " \n ")
        let capped = PhoneTweaks.list(items: [item(big), item(blank)],
                                      results: ["b": .injected(converted: true), "c": .injected(converted: false)],
                                      offHere: [])
        #expect(capped[0].name.count == PhoneTweaks.maxName)
        #expect(capped[0].version?.count == PhoneTweaks.maxVersion)
        #expect(capped[0].author?.count == PhoneTweaks.maxAuthor)
        #expect(capped[0].summary?.count == PhoneTweaks.maxSummary)
        #expect(capped[1].version == nil && capped[1].author == nil && capped[1].summary == nil)
    }

    /// The payload entries the module reads (`XSideWelcome.tweaks`).
    @Test func plistEntries() {
        let t = [PhoneTweak(name: "A", version: "1.0", author: "Me", summary: "Does it.", converted: true, offHere: false),
                 PhoneTweak(name: "B", version: nil, author: nil, summary: nil, converted: false, offHere: true)]
        let p = PhoneTweaks.plist(t)
        #expect(p.count == 2)
        #expect(p[0]["name"] as? String == "A" && p[0]["version"] as? String == "1.0" && p[0]["author"] as? String == "Me")
        #expect(p[0]["summary"] as? String == "Does it." && p[0]["converted"] as? Bool == true && p[0]["off"] as? Bool == false)
        #expect(p[1]["version"] == nil && p[1]["author"] == nil && p[1]["summary"] == nil && p[1]["off"] as? Bool == true)
    }

    @Test func versionAndAuthorLine() {
        #expect(PhoneTweaks.versionLine(version: "1.0", author: "Anthony") == "1.0 · Anthony")
        #expect(PhoneTweaks.versionLine(version: "1.0", author: nil) == "1.0")
        #expect(PhoneTweaks.versionLine(version: nil, author: "Anthony") == "Anthony")
        #expect(PhoneTweaks.versionLine(version: nil, author: nil) == "—")
    }

    /// iOS Settings' page: injected tweaks only, one group each; the description cut to ~300 characters.
    @Test func settingsPane() throws {
        let long = String(repeating: "word ", count: 100)
        let tweaks = [PhoneTweak(name: "XSPivotFix", version: "1.0", author: "Anthony", summary: "Short.", converted: false, offHere: false),
                      PhoneTweak(name: "uYouPlus", version: "3.0.5", author: "MiRO92", summary: long, converted: true, offHere: false),
                      PhoneTweak(name: "Off", version: "2.0", author: nil, summary: nil, converted: false, offHere: true)]
        let fr = try #require(TweaksPane.make(tweaks, language: "fr"))
        #expect(fr.rowTitle == "Tweaks · 2")
        #expect(fr.title == "Tweaks")
        #expect(fr.groups.count == 2)
        #expect(fr.groups[0] == .init(title: "XSPivotFix", version: "1.0 · Anthony", footer: "Short."))
        #expect(fr.groups[1].title == "uYouPlus · converti")
        let footer = try #require(fr.groups[1].footer)
        #expect(footer.count <= 301 && footer.hasSuffix("…"))
        #expect(!footer.hasSuffix(" …"))
        // The other language through the strings table, keyed by the text shown.
        #expect(fr.strings["en"]?["uYouPlus · converti"] == "uYouPlus · converted")
        #expect(fr.strings["fr"]?["uYouPlus · converti"] == "uYouPlus · converti")
        let en = try #require(TweaksPane.make(tweaks, language: "en"))
        #expect(en.groups[1].title == "uYouPlus · converted")
        #expect(en.strings["fr"]?["uYouPlus · converted"] == "uYouPlus · converti")
        // No injected tweak: no pane.
        #expect(TweaksPane.make([tweaks[2]], language: "fr") == nil)
        #expect(TweaksPane.make([], language: "en") == nil)
    }
}
