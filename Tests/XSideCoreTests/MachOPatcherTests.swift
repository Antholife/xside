import Foundation
import Testing
@testable import XSideCore

struct MachOPatcherTests {
    private static let path = "@executable_path/Frameworks/XSideWelcome.dylib"

    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xside-macho-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    private func u32(_ d: Data, _ at: Int) -> UInt32 {
        d.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    /// (cmd, offset) of each load command of the thin slice at `start`.
    private func commands(_ d: Data, at start: Int = 0) -> [(cmd: UInt32, pos: Int)] {
        var pos = start + 32
        return (0..<Int(u32(d, start + 16))).map { _ in
            defer { pos += Int(u32(d, pos + 4)) }
            return (u32(d, pos), pos)
        }
    }

    private func dylibName(_ d: Data, _ command: Int) -> String {
        let start = command + Int(u32(d, command + 8))
        let end = command + Int(u32(d, command + 4))
        return String(decoding: d.subdata(in: start..<end).prefix { $0 != 0 }, as: UTF8.self)
    }

    @Test func addsWeakDylibToThinBinary() throws {
        let url = try file(FakeIPA.paddedMachO(padding: 256))
        #expect(try MachOPatcher.addWeakDylib(Self.path, to: url) == .added)
        let d = try Data(contentsOf: url)
        let cmds = commands(d)
        #expect(cmds.count == 2)
        #expect(cmds.last?.cmd == 0x8000_0018)
        #expect(dylibName(d, cmds.last!.pos) == Self.path)
    }

    /// Review M1: a section said to start past the end of the file (an untrusted .ipa) is refused,
    /// never read out of range (which would crash XSide).
    @Test func truncatedBinaryIsRefused() throws {
        let full = FakeIPA.paddedMachO(padding: 256)
        let url = try file(full.prefix(32 + 152 + 20))
        #expect(throws: MachOPatcher.Failure.self) { try MachOPatcher.addWeakDylib(Self.path, to: url) }
        #expect(try Data(contentsOf: url) == full.prefix(32 + 152 + 20))
    }

    @Test func patchIsIdempotent() throws {
        let url = try file(FakeIPA.paddedMachO(padding: 256))
        _ = try MachOPatcher.addWeakDylib(Self.path, to: url)
        let once = try Data(contentsOf: url)
        #expect(try MachOPatcher.addWeakDylib(Self.path, to: url) == .alreadyPresent)
        #expect(try Data(contentsOf: url) == once)
    }

    @Test func insertsBeforeCodeSignature() throws {
        let url = try file(FakeIPA.paddedMachO(padding: 256, codeSignatureLast: true))
        _ = try MachOPatcher.addWeakDylib(Self.path, to: url)
        let d = try Data(contentsOf: url)
        #expect(commands(d).map(\.cmd) == [0x19, 0x8000_0018, 0x1D])
        #expect(u32(d, 20) == UInt32(152 + 16 + 72)) // sizeofcmds: segment + signature + new (24 + 46 + NUL, rounded to 72)
    }

    @Test func patchesEveryFatSlice() throws {
        let slice = FakeIPA.paddedMachO(padding: 256)
        let fat = FakeIPA.fatMachO(slices: [slice, slice])
        let url = try file(fat)
        #expect(try MachOPatcher.addWeakDylib(Self.path, to: url) == .added)
        let d = try Data(contentsOf: url)
        #expect(d.prefix(8 + 20 * 2) == fat.prefix(8 + 20 * 2))
        for i in 0..<2 {
            let offset = d.subdata(in: 8 + 20 * i + 8..<8 + 20 * i + 12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
            let cmds = commands(d, at: Int(offset))
            #expect(cmds.last?.cmd == 0x8000_0018)
        }
    }

    @Test func noRoomIsReported() throws {
        let original = FakeIPA.paddedMachO(padding: 8)
        let url = try file(original)
        #expect(throws: MachOPatcher.Failure.noRoom) { try MachOPatcher.addWeakDylib(Self.path, to: url) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func rejectsNonMachO() throws {
        let url = try file(Data("hello".utf8))
        #expect(throws: MachOPatcher.Failure.notMachO) { try MachOPatcher.addWeakDylib(Self.path, to: url) }
    }

    @Test func rejectsA32BitSlice() throws {
        var thin32 = FakeIPA.paddedMachO(padding: 256)
        thin32.replaceSubrange(0..<4, with: [0xCE, 0xFA, 0xED, 0xFE]) // MH_MAGIC
        let url = try file(thin32)
        #expect(throws: MachOPatcher.Failure.unsupportedSlice) { try MachOPatcher.addWeakDylib(Self.path, to: url) }
    }

    /// A real iOS executable from clang: otool sees the command and codesign accepts the result.
    @Test(.enabled(if: MachOPatcherTests.hasIOSSDK)) func realBinaryLoadsTheCommand() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xside-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("main.c"), binary = dir.appendingPathComponent("app")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        let runner = ProcessRunner()
        let build = try await runner.run("/usr/bin/xcrun", ["-sdk", "iphoneos", "clang", "-arch", "arm64",
                                                            "-mios-version-min=15.0", "-o", binary.path, source.path], cwd: nil)
        #expect(build.status == 0, "\(build.stderr)")
        #expect(try MachOPatcher.addWeakDylib(Self.path, to: binary) == .added)
        let otool = try await runner.run("/usr/bin/otool", ["-L", binary.path], cwd: nil)
        #expect(String(decoding: otool.stdout, as: UTF8.self).contains(Self.path))
        let sign = try await runner.run("/usr/bin/codesign", ["-f", "-s", "-", binary.path], cwd: nil)
        #expect(sign.status == 0, "\(sign.stderr)")
    }

    static var hasIOSSDK: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["-sdk", "iphoneos", "--show-sdk-path"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
