import Testing
@testable import XSideCore

@Suite struct DownloadKeepTests {
    @Test func fileName_appAndTagWithOriginalExtension() {
        #expect(DownloadKeep.fileName(appName: "YTKACE", tag: "v1.1.8",
                                      assetName: "YTKACE_1.1.8_YouTube_21.46.3.ipa") == "YTKACE_1.1.8.ipa")
    }

    @Test func fileName_dropsLeadingVFromTag() {
        #expect(DownloadKeep.fileName(appName: "App", tag: "V2.0", assetName: "x.ipa") == "App_2.0.ipa")
    }

    @Test func fileName_blankAppKeepsAssetName() {
        #expect(DownloadKeep.fileName(appName: "   ", tag: "v1", assetName: "weird-name.ipa") == "weird-name.ipa")
        #expect(DownloadKeep.fileName(appName: nil, tag: "v1", assetName: "weird-name.ipa") == "weird-name.ipa")
    }

    @Test func fileName_sanitizesSeparatorsAndCollapsesSpaces() {
        #expect(DownloadKeep.fileName(appName: "My/App : Pro", tag: "v3", assetName: "a.ipa") == "My App Pro_3.ipa")
    }

    @Test func fileName_emptyTagStillNamesTheApp() {
        #expect(DownloadKeep.fileName(appName: "App", tag: "", assetName: "a.ipa") == "App.ipa")
    }

    @Test func fileName_blankAppStripsTraversalFromAssetName() {
        #expect(DownloadKeep.fileName(appName: nil, tag: "v1", assetName: "../../etc/passwd.ipa") == "passwd.ipa")
        #expect(DownloadKeep.fileName(appName: "  ", tag: "v1", assetName: "a/b/c.ipa") == "c.ipa")
    }

    @Test func fileName_assetNameReducingToNothingFallsBack() {
        #expect(DownloadKeep.fileName(appName: nil, tag: "v1", assetName: "..") == "download.ipa")
    }

    @Test func safeName_keepsLastComponentOnly() {
        #expect(DownloadKeep.safeName("../../x.ipa") == "x.ipa")
        #expect(DownloadKeep.safeName("plain.ipa") == "plain.ipa")
    }

    @Test func safeName_mapsDotsAndEmptyToFallback() {
        #expect(DownloadKeep.safeName("..") == "download.ipa")
        #expect(DownloadKeep.safeName(".") == "download.ipa")
        #expect(DownloadKeep.safeName("") == "download.ipa")
        #expect(DownloadKeep.safeName("/", fallback: "x.ipa") == "x.ipa")
    }

    @Test func disambiguate_returnsNameWhenFree() {
        #expect(DownloadKeep.disambiguate("App_1.ipa", existing: ["Other.ipa"]) == "App_1.ipa")
    }

    @Test func disambiguate_addsCounterBeforeExtension() {
        #expect(DownloadKeep.disambiguate("App_1.ipa", existing: ["App_1.ipa"]) == "App_1 (2).ipa")
        #expect(DownloadKeep.disambiguate("App_1.ipa", existing: ["App_1.ipa", "App_1 (2).ipa"]) == "App_1 (3).ipa")
    }
}
