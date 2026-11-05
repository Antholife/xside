import Testing
@testable import XSideCore

/// iOS refuses notifications to an app whose CFBundleName has special characters
/// (UNErrorDomain 1, seen 2026-11-05 with "YouTube +"); the shown name is CFBundleDisplayName.
struct BundleNameTests {
    @Test func plainNamesStay() {
        #expect(BundleName.safe("YouTube", executable: "YouTube") == nil)
        #expect(BundleName.safe("Google Maps", executable: "Maps") == nil)
        #expect(BundleName.safe("App-2_v1.0", executable: "App") == nil)
    }

    @Test func specialCharactersGo() {
        #expect(BundleName.safe("YouTube +", executable: "YouTube") == "YouTube")
        #expect(BundleName.safe("Café Été", executable: "Cafe") == "Cafe Ete")
        #expect(BundleName.safe("Spotify++ (beta)", executable: "Spotify") == "Spotify beta")
    }

    @Test func nothingLeftFallsBackToTheExecutable() {
        #expect(BundleName.safe("📺 +", executable: "TV") == "TV")
        #expect(BundleName.safe("日本", executable: "Japan") == "Japan")
    }
}
