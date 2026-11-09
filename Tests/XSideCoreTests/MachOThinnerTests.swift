import Foundation
import Testing
@testable import XSideCore

struct MachOThinnerTests {
    private let arm64: UInt32 = 0x0100000C
    private let armv7: UInt32 = 12

    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macho-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test func armv7EncryptedWithArm64DecryptedIsAccepted() throws {
        let fat = FakeIPA.fat([(armv7, 9, FakeIPA.machO(cpuType: armv7, cryptid: 1)),
                               (arm64, 0, FakeIPA.machO(cpuType: arm64, cryptid: 0))])
        #expect(try IPAInspector.isEncrypted(try file(fat)) == false)
    }

    @Test func arm64EncryptedIsRefusedEvenWithArmv7Decrypted() throws {
        let fat = FakeIPA.fat([(armv7, 9, FakeIPA.machO(cpuType: armv7, cryptid: 0)),
                               (arm64, 0, FakeIPA.machO(cpuType: arm64, cryptid: 1))])
        #expect(try IPAInspector.isEncrypted(try file(fat)))
    }

    @Test func thinArm64DecryptedIsAcceptedAndEncryptedRefused() throws {
        #expect(try IPAInspector.isEncrypted(try file(FakeIPA.machO(cpuType: arm64, cryptid: 0))) == false)
        #expect(try IPAInspector.isEncrypted(try file(FakeIPA.machO(cpuType: arm64, cryptid: 1))))
    }

    @Test func strippingKeepsArm64IntactAndThinsASingleSlice() throws {
        let slice = FakeIPA.machO(cpuType: arm64, cryptid: 0)
        let fat = FakeIPA.fat([(armv7, 9, FakeIPA.machO(cpuType: armv7, cryptid: 1)),
                               (armv7, 11, FakeIPA.machO(cpuType: armv7, cryptid: 1)),
                               (arm64, 0, slice)])
        #expect(MachOThinner.removingARM32(from: slice) == nil) // thin: nothing to do
        #expect(MachOThinner.removingARM32(from: fat) == slice)
    }

    @Test func strippingKeepsAValidFatHeaderWhenSeveralSlicesRemain() throws {
        let a = FakeIPA.machO(cpuType: arm64, cryptid: 0)
        let e = FakeIPA.machO(cpuType: arm64, cryptid: 0)
        let fat = FakeIPA.fat([(armv7, 9, FakeIPA.machO(cpuType: armv7, cryptid: 1)), (arm64, 0, a), (0x0100000C, 2, e)])
        let out = try #require(MachOThinner.removingARM32(from: fat))
        let entries = try IPAInspector.sliceEntries(out)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.cpuType == arm64 })
        #expect(out.subdata(in: entries[0].offset..<entries[0].offset + a.count) == a)
        #expect(try IPAInspector.isEncrypted(try file(out)) == false)
    }

    @Test func strippingWholeBundleRewritesFilesAndLeavesBrokenOnesAlone() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("thin-\(UUID().uuidString).app")
        let fw = app.appendingPathComponent("Frameworks/X.framework")
        try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
        let slice = FakeIPA.machO(cpuType: arm64, cryptid: 0)
        let fat = FakeIPA.fat([(armv7, 9, FakeIPA.machO(cpuType: armv7, cryptid: 1)), (arm64, 0, slice)])
        try fat.write(to: app.appendingPathComponent("Main"))
        try fat.write(to: fw.appendingPathComponent("X"))
        let broken = Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2, 0, 0])
        try broken.write(to: app.appendingPathComponent("Broken"))
        defer { try? FileManager.default.removeItem(at: app) }
        let changed = MachOThinner.removeARM32Slices(under: app)
        #expect(changed.count == 2)
        #expect(try Data(contentsOf: app.appendingPathComponent("Main")) == slice)
        #expect(try Data(contentsOf: fw.appendingPathComponent("X")) == slice)
        #expect(try Data(contentsOf: app.appendingPathComponent("Broken")) == broken)
    }

    @Test func detectsLegacySlicesFromTheHeaderAndListsTheStepOnlyForThem() throws {
        let slice = FakeIPA.machO(cpuType: arm64, cryptid: 0)
        let fat = FakeIPA.fat([(armv7, 9, FakeIPA.machO(cpuType: armv7, cryptid: 1)), (arm64, 0, slice)])
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        try slice.write(to: app.appendingPathComponent("Main"))
        #expect(MachOThinner.hasARM32Slices(under: app) == false)
        try fat.write(to: app.appendingPathComponent("Old"))
        #expect(MachOThinner.hasARM32Slices(under: app))
        #expect(ProgressStep.list(includingWifiCheck: false).contains(.legacy32) == false)
        let steps = ProgressStep.list(includingWifiCheck: false, includingLegacy32: true)
        #expect(steps == [.preparing, .profile, .welcome, .legacy32, .signing, .installing])
        #expect(StepTimeline(steps: steps, stage: .step(.welcome)).status(of: .legacy32) == .pending)
        #expect(StepTimeline(steps: steps, stage: .step(.signing)).status(of: .legacy32) == .done)
    }
}
