import Foundation
import Testing
@testable import XSideCore

/// Step ③'s tweak drafts: what each device's list gets at Install, and which converted tweak is
/// asked about again (mega review U1, U12).
struct TweakDraftTests {
    private let package = TweakPackage(id: "0123456789abcdef", kind: .deb, origin: .added, packageID: "com.example.tweak",
                                       name: "Tweak", version: "1.0", files: [], binaries: [], addedAt: Date(timeIntervalSince1970: 0))
    private let converted = TweakVerdict.converted([.hookingLibrary])

    private func stored(on: Set<String>, verdicts: [String: TweakVerdict] = [:], injectedOn: Set<String> = []) -> TweakDraft {
        TweakDraft(package: package, directory: URL(fileURLWithPath: "/tmp/x"), enabledDevices: on, force: [],
                   verdicts: verdicts, stored: true, listedDevices: ["A", "B"], seenDevices: ["A", "B"], injectedOn: injectedOn)
    }

    /// U1: a device with no verdict yet (the window classified for another selection) keeps the
    /// choice its list has; it isn't turned off without anyone asking.
    @Test func aDeviceNotJudgedYetKeepsItsStoredChoice() {
        let draft = stored(on: ["A"])
        #expect(draft.use(on: "A") == TweakUse(id: package.id, enabled: true))
        #expect(draft.use(on: "B") == TweakUse(id: package.id, enabled: false))
        // Judged: the verdict decides, as before.
        let judged = stored(on: ["A"], verdicts: ["A": .incompatible(.madeForAnotherApp(["x"]))])
        #expect(judged.use(on: "A") == TweakUse(id: package.id, enabled: false))
        #expect(stored(on: ["A"], verdicts: ["A": .compatible]).use(on: "A") == TweakUse(id: package.id, enabled: true))
    }

    /// U12: a converted tweak the last signing already put in on that device isn't asked about at
    /// every reinstall; a new one, or one new on that device, is.
    @Test func aConvertedTweakAlreadyInjectedThereIsNotAskedAgain() {
        #expect(stored(on: ["A"], verdicts: ["A": converted], injectedOn: ["A"]).conversionsToConfirm(on: "A") == nil)
        #expect(stored(on: ["A", "B"], verdicts: ["A": converted, "B": converted], injectedOn: ["A"])
                    .conversionsToConfirm(on: "B") == [.hookingLibrary])
        var added = stored(on: ["A"], verdicts: ["A": converted])
        added.stored = false
        #expect(added.conversionsToConfirm(on: "A") == [.hookingLibrary])
        #expect(stored(on: [], verdicts: ["A": converted]).conversionsToConfirm(on: "A") == nil) // off there
        #expect(stored(on: ["A"], verdicts: ["A": .compatible]).conversionsToConfirm(on: "A") == nil)
    }
}
