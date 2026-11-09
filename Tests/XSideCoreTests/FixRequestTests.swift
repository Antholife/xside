import Foundation
import Testing
@testable import XSideCore

struct FixRequestTests {
    @Test func titleNamesTheAppOnly() {
        #expect(FixRequest.title(appName: nil) == "Fix request")
        #expect(FixRequest.title(appName: "  ") == "Fix request")
        #expect(FixRequest.title(appName: "YouTube") == "Fix request: YouTube")
        #expect(FixRequest.title(appName: "Two\nlines") == "Fix request: Two lines")
        #expect(FixRequest.title(appName: String(repeating: "a", count: 200)).count == "Fix request: ".count + 60)
    }

    @Test func urlOpensTheFixFormWithAnEncodedTitle() throws {
        let url = FixRequest.url(appName: "Tom & Jerry+ #1 = é")
        #expect(url.absoluteString.hasPrefix("https://github.com/Antholife/xside/issues/new?template=fix_request.yml&title="))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.count == 2)
        #expect(items.first { $0.name == "title" }?.value == "Fix request: Tom & Jerry+ #1 = é")
        #expect(!url.absoluteString.contains(" ") && !url.absoluteString.contains("#"))
        #expect(FixRequest.url(appName: nil).absoluteString
                == "https://github.com/Antholife/xside/issues/new?template=fix_request.yml&title=Fix%20request")
    }
}

struct FixRequestCrashTests {
    private let facts = FixRequest.CrashFacts(appVersion: "6.9.0", iOSVersion: "27.3", xsideVersion: "1.2.0 (42)",
                                              xsideModule: true, duoCompatibility: true, duoModule: true,
                                              iCloudSignedOut: false)

    @Test func detailsSayWhatCrashedAndWhichFixesWereOn() {
        let d = CrashDiagnosis(cause: .duoLegacyModule, subject: "XSideDuoLegacy.dylib", duoCompatibilityOn: true,
                               exceptionType: "EXC_BAD_ACCESS", signal: "SIGSEGV",
                               topFrames: ["XSideDuoLegacy.dylib  XSAttach + 40"])
        let text = FixRequest.crashDetails(d, facts: facts, secrets: [], appIDs: [])
        #expect(text.contains("Cause: duoLegacyModule"))
        #expect(text.contains("Library: XSideDuoLegacy.dylib"))
        #expect(text.contains("Exception: EXC_BAD_ACCESS SIGSEGV"))
        #expect(text.contains("iOS: 27.3"))
        #expect(text.contains("XSide: 1.2.0 (42)"))
        #expect(text.contains("iPhone Duo compatibility: on (compatibility module)"))
        #expect(text.contains("Simulate signed-out iCloud: off"))
        #expect(text.contains("XSideDuoLegacy.dylib  XSAttach + 40"))
    }

    @Test func crashDetailsListTheTweaks() {
        let alpha = InjectedTweak(id: "0123456789abcdef", name: "Alpha\nEvil", packageID: "com.example.alpha", version: "1.2",
                                  imageNames: ["Alpha.dylib"],
                                  conversions: [.hookingLibrary, .jailbreakPaths, .dependencyAdded("Cephei")])
        let beta = InjectedTweak(id: "fedcba9876543210", name: "Beta", packageID: "com.example.beta", imageNames: ["Beta.dylib"])
        var f = facts
        f.tweaks = [alpha, beta].map(TweakCrashFix.reportLine)
        var d = CrashDiagnosis(cause: .tweakSupport, subject: "Cephei")
        d.shellCommand = true
        let text = FixRequest.crashDetails(d, facts: f, secrets: [], appIDs: [])
        #expect(text.contains("Tweaks: Alpha Evil 1.2 (converted: ElleKit, paths, dependency added: Cephei); Beta"))
        #expect(text.contains("Shell command: yes"))
        #expect(FixRequest.crashDetails(d, facts: facts, secrets: [], appIDs: []).contains("Tweaks: none"))
    }

    @Test func detailsKeepNothingPersonal() {
        let d = CrashDiagnosis(cause: .other, subject: "Demo",
                               topFrames: ["/private/var/containers/Bundle/Application/0A1B2C3D-0000-1111-2222-333344445555/Demo.app/Demo com.vendor.app.TEAM123456",
                                           "/Users/anthony/x  iPhone Duo de Anthony  TEAM123456"])
        let text = FixRequest.crashDetails(d, facts: facts, secrets: ["TEAM123456", "iPhone Duo de Anthony"],
                                           appIDs: ["com.vendor.app", "com.vendor.app.TEAM123456"])
        #expect(!text.contains("TEAM123456"))
        #expect(!text.contains("com.vendor.app"))
        #expect(!text.contains("Anthony") && !text.contains("anthony"))
        #expect(!text.contains("0A1B2C3D-0000-1111-2222-333344445555"))
        #expect(text.contains("<app>"))
    }

    @Test func crashURLUsesTheFixForm() throws {
        let url = FixRequest.crashURL(appName: "Duolingo", prompt: "Décris", details: "Cause: other")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "template" }?.value == "fix_request.yml")
        #expect(items.first { $0.name == "title" }?.value == "Fix request: Duolingo")
        #expect(items.first { $0.name == "expected" }?.value == "Décris")
        #expect(items.first { $0.name == "diagnosis" }?.value == "```\nCause: other\n```")
        let long = FixRequest.crashURL(appName: "A", prompt: "p", details: String(repeating: "frame\n", count: 4000))
        #expect(long.absoluteString.count <= IssueReport.maxURLLength)
    }
}
