import Testing
@testable import XSideCore

struct TrustGuideTests {
    @Test func firstInstallOnADevice() {
        #expect(TrustGuide.isDue(shown: .never, currentIdentity: "AA", deviceHasApps: false))
        #expect(TrustGuide.isDue(shown: .never, currentIdentity: "AA", deviceHasApps: true))
    }

    /// iOS forgets the trust once the developer's last app is deleted from the device.
    @Test func deviceWithoutAnyXSideAppLeft() {
        #expect(TrustGuide.isDue(shown: .identity("AA"), currentIdentity: "AA", deviceHasApps: false))
        #expect(TrustGuide.isDue(shown: .unknownIdentity, currentIdentity: "AA", deviceHasApps: false))
    }

    /// A new certificate must be trusted again.
    @Test func newCertificate() {
        #expect(TrustGuide.isDue(shown: .identity("AA"), currentIdentity: "BB", deviceHasApps: true))
        #expect(!TrustGuide.isDue(shown: .identity("aa"), currentIdentity: "AA", deviceHasApps: true))
    }

    @Test func alreadyTrusted() {
        #expect(!TrustGuide.isDue(shown: .identity("AA"), currentIdentity: "AA", deviceHasApps: true))
        // Shown by an older XSide (certificate not recorded): not shown again for that alone.
        #expect(!TrustGuide.isDue(shown: .unknownIdentity, currentIdentity: "AA", deviceHasApps: true))
        #expect(!TrustGuide.isDue(shown: .identity("AA"), currentIdentity: nil, deviceHasApps: true))
    }

    @Test func readsTheStoredValue() {
        #expect(TrustGuide.Shown(stored: nil) == .never)
        #expect(TrustGuide.Shown(stored: true) == .unknownIdentity)
        #expect(TrustGuide.Shown(stored: false) == .never)
        #expect(TrustGuide.Shown(stored: "AB12") == .identity("AB12"))
    }
}
