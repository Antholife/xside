import Foundation
import Testing
@testable import XSideCore

struct WhatsNewTests {
    @Test func showsOnceAfterAnUpdateWithNotes() {
        #expect(WhatsNew.decide(current: "1.0.1", lastSeen: nil, setupDone: true, hasNotes: true) == .show)
        #expect(WhatsNew.decide(current: "1.0.1", lastSeen: "1.0.0", setupDone: true, hasNotes: true) == .show)
        #expect(WhatsNew.decide(current: "1.0.1", lastSeen: "1.0.1", setupDone: true, hasNotes: true) == .nothing)
    }

    @Test func aFreshInstallSeesNothingNew() {
        #expect(WhatsNew.decide(current: "1.0.1", lastSeen: nil, setupDone: false, hasNotes: true) == .markSeen)
    }

    @Test func aVersionWithoutNotesIsJustRemembered() {
        #expect(WhatsNew.decide(current: "1.0.2", lastSeen: "1.0.1", setupDone: true, hasNotes: false) == .markSeen)
    }

    // MARK: 1.2.0 notes (the items live in the app target: check the resources and the list)

    private static var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func strings(_ lang: String) throws -> [String: String] {
        let url = repo.appendingPathComponent("App/Resources/\(lang).lproj/Localizable.strings")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return plist as? [String: String] ?? [:]
    }

    @Test func whatsNew120ListsTweaks() throws {
        let view = try String(contentsOf: Self.repo.appendingPathComponent("Sources/XSideApp/Views/WhatsNewView.swift"),
                              encoding: .utf8)
        let en = try Self.strings("en"), fr = try Self.strings("fr")
        // One item per change, every one with a title and a text in both languages, and listed.
        let names = ["tweaks", "tweakClasses", "tweakConvert", "tweakLimits", "tweakDeps", "tweakDownload",
                     "tweakDownloads", "tweakCrash", "tweakLicences", "compat", "armv7", "request", "pending", "rowMenu",
                     "duo", "icloud", "crash"]
        for name in names {
            for part in ["title", "text"] {
                let key = "whatsNew.120.\(name).\(part)"
                #expect(en[key]?.isEmpty == false, "\(key) missing in English")
                #expect(fr[key]?.isEmpty == false, "\(key) missing in French")
            }
            #expect(view.contains("L(\"whatsNew.120.\(name).title\")"), "\(name) isn't listed in the 1.2.0 notes")
        }
        // Said plainly: C function hooks fail on iOS, and a system tweak needs a jailbreak.
        #expect(en["whatsNew.120.tweakLimits.text"]?.contains("C functions don't") == true)
        #expect(fr["whatsNew.120.tweakLimits.text"]?.contains("fonctions C non") == true)
        #expect(en["whatsNew.120.tweakClasses.text"]?.contains("jailbreak") == true)
        // Every 1.2.0 key the list uses exists in both languages.
        let used = view.components(separatedBy: "L(\"whatsNew.120.").dropFirst().compactMap { $0.components(separatedBy: "\"").first }
        #expect(used.count >= names.count * 2)
        for key in used {
            #expect(en["whatsNew.120.\(key)"] != nil && fr["whatsNew.120.\(key)"] != nil, "\(key)")
        }
    }
}
