import Foundation
import Testing
@testable import XSideCore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

struct LogTests {
    @Test func masksEmailsHomeAndRegisteredValues() {
        let store = LogStore()
        store.register("FPFZBAJ3Z8", as: "team")
        store.register("00008110-001234560E01801E", as: "udid")
        store.register("iPhone de Anthony", as: "device-name")
        store.register("ab", as: "team") // too short: ignored

        let text = store.redact("""
            Apple Development: someone@icloud.com (FPFZBAJ3Z8) on 00008110-001234560E01801E \
            "iPhone de Anthony" in \(NSHomeDirectory())/Downloads, com.example.app.FPFZBAJ3Z8, ab
            """)
        #expect(text == """
            Apple Development: <email> (<team-1>) on <udid-1> "<device-name-1>" in ~/Downloads, \
            com.example.app.<team-1>, ab
            """)
    }

    @Test func masksASigningIdentity() {
        let store = LogStore()
        store.registerIdentity(name: "Apple Development: someone@icloud.com (LL6YVU88MW)",
                               sha1: "0123456789ABCDEF0123456789ABCDEF01234567")
        #expect(store.redact("find-certificate -c 'Apple Development: someone@icloud.com (LL6YVU88MW)' 0123456789ABCDEF0123456789ABCDEF01234567")
                == "find-certificate -c 'Apple Development: <email> (<person-1>)' <certificate-1>")
    }

    @Test func aValueKeepsItsPlaceholder() {
        let store = LogStore()
        store.register("device-aaaa", as: "device")
        store.register("device-bbbb", as: "device")
        store.register("device-aaaa", as: "device")
        #expect(store.redact("device-bbbb device-aaaa") == "<device-2> <device-1>")
    }

    @Test func writesNothingBeforeConfigure() throws {
        let store = LogStore()
        store.append(level: .notice, category: "test", redacted: "lost")
        #expect(store.files().isEmpty)
    }

    @Test func appendsLinesAndRotates() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LogStore(maxBytes: 200, keep: 3)
        store.configure(directory: dir)
        for i in 0..<20 { store.append(level: .info, category: "test", redacted: "line \(i) xxxxxxxxxxxxxxxx") }

        let files = store.files()
        #expect(files.map(\.lastPathComponent) == ["xside.log", "xside.1.log", "xside.2.log"])
        for file in files { #expect(try Data(contentsOf: file).count <= 200) }
        let newest = try String(contentsOf: files[0], encoding: .utf8)
        #expect(newest.contains("INFO   [test] line 19 "))
        #expect(!files.contains { $0.lastPathComponent == "xside.3.log" })
    }
}
