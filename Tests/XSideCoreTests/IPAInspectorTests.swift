import Testing
import Foundation
@testable import XSideCore

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

struct IPAInspectorTests {
    @Test func readsInfo() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let made = try FakeIPA.makeApp(at: root, bundleID: "com.example.demo", executable: "Demo",
                                       plistExtras: ["CFBundleName": "Nom", "CFBundleShortVersionString": "1.2"])
        let app = try IPAInspector.appBundle(in: root)
        #expect(app.lastPathComponent == made.lastPathComponent)
        let info = try IPAInspector.info(of: app)
        #expect(info == AppInfo(bundleID: "com.example.demo", name: "Nom", version: "1.2", executable: "Demo"))
        let root2 = try tempDir(); defer { try? FileManager.default.removeItem(at: root2) }
        let a2 = try FakeIPA.makeApp(at: root2, plistExtras: ["CFBundleName": "Nom", "CFBundleDisplayName": "Affiché"])
        #expect(try IPAInspector.info(of: a2).name == "Affiché")
    }

    @Test func detectsEncryption() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let enc = try FakeIPA.makeApp(at: root, encrypted: true)
        #expect(try IPAInspector.isEncrypted(enc.appendingPathComponent("Demo")) == true)
        let root2 = try tempDir(); defer { try? FileManager.default.removeItem(at: root2) }
        let clear = try FakeIPA.makeApp(at: root2, encrypted: false)
        #expect(try IPAInspector.isEncrypted(clear.appendingPathComponent("Demo")) == false)
    }

    @Test func fatBinaryEncryption() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let fat = FakeIPA.fatMachO(slices: [FakeIPA.thinMachO(cryptid: 0), FakeIPA.thinMachO(cryptid: 1)])
        let app = try FakeIPA.makeApp(at: root, executableData: fat)
        #expect(try IPAInspector.isEncrypted(app.appendingPathComponent("Demo")) == true)
        let clear = FakeIPA.fatMachO(slices: [FakeIPA.thinMachO(cryptid: 0), FakeIPA.thinMachO(cryptid: 0)])
        let f = root.appendingPathComponent("clear")
        try clear.write(to: f)
        #expect(try IPAInspector.isEncrypted(f) == false)
    }

    @Test func rejectsMalformedMachO() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let thin = FakeIPA.thinMachO(cryptid: 1)
        for (i, data) in [Data(), Data([1, 2, 3]), Data(count: 64), thin.prefix(40), thin.prefix(20),
                          FakeIPA.fatMachO(slices: [thin]).prefix(30)].enumerated() {
            let f = root.appendingPathComponent("m\(i)")
            try Data(data).write(to: f)
            #expect(throws: XSideError.self) { try IPAInspector.isEncrypted(f) }
        }
    }

    @Test func rejectsMalformedPayload() throws {
        // zero .app
        let r0 = try tempDir(); defer { try? FileManager.default.removeItem(at: r0) }
        try FileManager.default.createDirectory(at: r0.appendingPathComponent("Payload"), withIntermediateDirectories: true)
        #expect(throws: XSideError.self) { try IPAInspector.appBundle(in: r0) }
        // no Payload
        let rn = try tempDir(); defer { try? FileManager.default.removeItem(at: rn) }
        #expect(throws: XSideError.self) { try IPAInspector.appBundle(in: rn) }
        // two .app
        let r2 = try tempDir(); defer { try? FileManager.default.removeItem(at: r2) }
        try FakeIPA.makeApp(at: r2, name: "A")
        try FakeIPA.makeApp(at: r2, name: "B")
        #expect(throws: XSideError.self) { try IPAInspector.appBundle(in: r2) }
        // no CFBundleIdentifier
        let r3 = try tempDir(); defer { try? FileManager.default.removeItem(at: r3) }
        let app = try FakeIPA.makeApp(at: r3)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Demo"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        #expect(throws: XSideError.invalidIPA("Info.plist sans CFBundleIdentifier")) { try IPAInspector.info(of: app) }
    }
}
