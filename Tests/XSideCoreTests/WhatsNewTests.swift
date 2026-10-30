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
}
