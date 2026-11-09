import Foundation
import Testing
@testable import XSideCore

private func installation(signed: SigningChoices? = nil, duo: Bool? = nil, iCloud: Bool? = nil,
                          without: Bool? = nil) -> Installation {
    Installation(deviceID: "d", installedAt: Date(), expiresAt: Date().addingTimeInterval(86_400),
                 withoutXSideFeatures: without, duoCompatibility: duo, iCloudSignedOut: iCloud, signedChoices: signed)
}

@Suite("Pending signing-time changes")
struct PendingSigningChangesTests {
    let none = SigningChoices(withoutXSideFeatures: false, duoCompatibility: false, iCloudSignedOut: false)

    @Test func nothingPendingWhenChoicesMatch() {
        #expect(installation(signed: none).pendingSigningChanges(wantsWithoutXSideFeatures: false).isEmpty)
    }

    @Test func moduleOffIsPendingUntilSigned() {
        #expect(installation(signed: none).pendingSigningChanges(wantsWithoutXSideFeatures: true) == [.xsideModule])
        let signed = SigningChoices(withoutXSideFeatures: true, duoCompatibility: false, iCloudSignedOut: false)
        #expect(installation(signed: signed, without: true).pendingSigningChanges(wantsWithoutXSideFeatures: true).isEmpty)
    }

    @Test func duoAndICloudCompareWithWhatWasSigned() {
        #expect(installation(signed: none, duo: true).pendingSigningChanges(wantsWithoutXSideFeatures: false) == [.duoCompatibility])
        #expect(installation(signed: none, iCloud: true).pendingSigningChanges(wantsWithoutXSideFeatures: false) == [.iCloudSignedOut])
        let both = SigningChoices(withoutXSideFeatures: false, duoCompatibility: true, iCloudSignedOut: true)
        // Turned off after being signed on: pending too.
        #expect(installation(signed: both).pendingSigningChanges(wantsWithoutXSideFeatures: false) == [.duoCompatibility, .iCloudSignedOut])
        #expect(installation(signed: both, duo: true, iCloud: true).pendingSigningChanges(wantsWithoutXSideFeatures: false).isEmpty)
    }

    @Test func optionThatCouldNotBeAddedIsNotPendingAgain() {
        // Asked at the last signing but missing: the choice still equals what was asked.
        let asked = SigningChoices(withoutXSideFeatures: false, duoCompatibility: true, iCloudSignedOut: false)
        var i = installation(signed: asked, duo: true)
        i.duoCompatibilityMissing = true
        #expect(i.pendingSigningChanges(wantsWithoutXSideFeatures: false).isEmpty)
    }

    @Test func olderStateOnlyKnowsTheModule() {
        #expect(installation(duo: true, iCloud: true).pendingSigningChanges(wantsWithoutXSideFeatures: false).isEmpty)
        #expect(installation(without: true).pendingSigningChanges(wantsWithoutXSideFeatures: false) == [.xsideModule])
        #expect(installation(without: true).pendingSigningChanges(wantsWithoutXSideFeatures: true).isEmpty)
    }

    @Test func signedChoicesSurviveEncoding() throws {
        let i = installation(signed: SigningChoices(withoutXSideFeatures: true, duoCompatibility: true, iCloudSignedOut: false))
        let back = try JSONDecoder().decode(Installation.self, from: JSONEncoder().encode(i))
        #expect(back.signedChoices == i.signedChoices)
    }
}
