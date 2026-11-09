import Foundation
import Testing
@testable import XSideCore

struct TweakDropTests {
    private func make(_ name: String, directory: Bool) throws -> URL {
        let url = TestTemp.root.appendingPathComponent("drop-\(UUID().uuidString)-\(name)")
        if directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        else { try Data().write(to: url) }
        return url
    }

    @Test func recognisesTweakFilesAndFolders() throws {
        #expect(TweakAnalyzer.looksLikeTweak(try make("a.deb", directory: false)))
        #expect(TweakAnalyzer.looksLikeTweak(try make("a.DYLIB", directory: false)))
        #expect(TweakAnalyzer.looksLikeTweak(try make("A.framework", directory: true)))
        #expect(TweakAnalyzer.looksLikeTweak(try make("A.bundle", directory: true)))
    }

    @Test func refusesTheRest() throws {
        #expect(!TweakAnalyzer.looksLikeTweak(try make("a.ipa", directory: false)))
        #expect(!TweakAnalyzer.looksLikeTweak(try make("a.deb", directory: true))) // a folder named .deb
        #expect(!TweakAnalyzer.looksLikeTweak(try make("A.framework", directory: false)))
        #expect(!TweakAnalyzer.looksLikeTweak(URL(string: "https://example.com/a.deb")!))
        #expect(!TweakAnalyzer.looksLikeTweak(URL(fileURLWithPath: "/nonexistent/a.deb")))
    }
}
