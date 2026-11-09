import Foundation
import Testing
@testable import XSideCore

struct MachOThinnerTests {
    private let arm64: UInt32 = 0x0100000C
    private let armv7: UInt32 = 12

    private func file(_ data: Data) throws -> URL {
        let url = TestTemp.root.appendingPathComponent("macho-\(UUID().uuidString)")
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
        let app = TestTemp.root.appendingPathComponent("thin-\(UUID().uuidString).app")
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
        let app = TestTemp.root.appendingPathComponent("scan-\(UUID().uuidString).app")
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

    // MARK: - Hostile fat headers

    /// A fat header (32 or 64 bit) with the given entries (cpu, sub, offset, size, align), then `body`.
    private func hostileFat(is64: Bool = false, _ entries: [(UInt32, UInt32, UInt64, UInt64, UInt32)], body: Data = Data()) -> Data {
        var d = Data()
        func be32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func be64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        be32(is64 ? 0xCAFEBABF : 0xCAFEBABE); be32(UInt32(entries.count))
        for e in entries {
            be32(e.0); be32(e.1)
            if is64 { be64(e.2); be64(e.3); be32(e.4); be32(0) } else { be32(UInt32(e.2)); be32(UInt32(e.3)); be32(e.4) }
        }
        d.append(body)
        return d
    }

    /// The thinner must never grow a file past this, whatever the header asks for.
    private func expectBounded(_ out: Data?, from input: Data) {
        if let out { #expect(out.count <= input.count + 65_536) }
    }

    @Test func hugeAlignmentIsRefusedInsteadOfPaddingGigabytes() {
        let input = hostileFat([(armv7, 9, 0x70, 16, 4), (arm64, 0, 0x70, 16, 30), (arm64, 1, 0x70, 16, 30)],
                               body: Data(count: 0x60))
        #expect(input.count < 200)
        let out = MachOThinner.removingARM32(from: input)
        expectBounded(out, from: input)
        #expect(out == nil)
    }

    @Test func manyHugeAlignmentsDoNotTrapTheOffsetConversion() {
        let entries: [(UInt32, UInt32, UInt64, UInt64, UInt32)] =
            [(armv7, 9, 0x100, 16, 4)] + (0..<6).map { (arm64, UInt32($0), 0x100, 16, 30) }
        let input = hostileFat(entries, body: Data(count: 0x200))
        let out = MachOThinner.removingARM32(from: input)
        expectBounded(out, from: input)
        #expect(out == nil)
    }

    @Test func fat64HugeAlignmentIsRefused() {
        let input = hostileFat(is64: true, [(armv7, 9, 0x90, 16, 4), (arm64, 0, 0x90, 16, 29), (arm64, 1, 0x90, 16, 29)],
                               body: Data(count: 0x60))
        let out = MachOThinner.removingARM32(from: input)
        expectBounded(out, from: input)
        #expect(out == nil)
    }

    @Test func alignmentUpTo14IsStillAccepted() throws {
        let a = FakeIPA.machO(cpuType: arm64, cryptid: 0)
        let b = FakeIPA.machO(cpuType: arm64, cryptid: 0)
        let fat = FakeIPA.fat([(armv7, 9, FakeIPA.machO(cpuType: armv7, cryptid: 1)), (arm64, 0, a), (arm64, 2, b)])
        let out = try #require(MachOThinner.removingARM32(from: fat))
        #expect(try IPAInspector.sliceEntries(out).count == 2)
    }

    @Test func overlappingKeptSlicesAreRefused() {
        let input = hostileFat([(armv7, 9, 0x70, 16, 4), (arm64, 0, 0x70, 32, 4), (arm64, 1, 0x80, 32, 4)],
                               body: Data(count: 0x60))
        #expect(MachOThinner.removingARM32(from: input) == nil)
    }

    @Test func duplicateCpuAndSubtypeAreRefused() {
        let input = hostileFat([(armv7, 9, 0x70, 16, 4), (arm64, 0, 0x70, 16, 4), (arm64, 0, 0x80, 16, 4)],
                               body: Data(count: 0x60))
        #expect(MachOThinner.removingARM32(from: input) == nil)
    }

    @Test func sliceOverlappingTheHeaderIsRefused() {
        let input = hostileFat([(armv7, 9, 0x70, 16, 4), (arm64, 0, 0x10, 16, 4), (arm64, 1, 0x70, 16, 4)],
                               body: Data(count: 0x60))
        #expect(MachOThinner.removingARM32(from: input) == nil)
    }
}
