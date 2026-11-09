import Foundation
import Testing
@testable import XSideCore

struct MachOPatcherTests {
    private static let path = "@executable_path/Frameworks/XSideWelcome.dylib"

    private func file(_ data: Data) throws -> URL {
        let url = TestTemp.root.appendingPathComponent("xside-macho-\(UUID().uuidString)")
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
        let dir = TestTemp.root.appendingPathComponent("xside-real-\(UUID().uuidString)")
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

// MARK: - Library names: list, rewrite, remove by predicate, strings

extension MachOPatcherTests {
    private static let substrate = "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
    private static let libsubstrate = "/usr/lib/libsubstrate.dylib"
    private static let elleKit = "@executable_path/Frameworks/XSideTweaks/ElleKit.dylib"

    /// Offset of the slice at index `i` of a fat file (32-bit header).
    private func sliceOffset(_ d: Data, _ i: Int) -> Int {
        Int(d.subdata(in: 8 + 20 * i + 8..<8 + 20 * i + 12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
    }

    /// The (cmd, name) of each library command of the slice at `start`.
    private func libraries(_ d: Data, at start: Int = 0) -> [(cmd: UInt32, name: String)] {
        commands(d, at: start).filter { [0xC, 0x8000_0018].contains($0.cmd) }.map { ($0.cmd, dylibName(d, $0.pos)) }
    }

    @Test func listsLinkedDylibsOncePerName() throws {
        let thin = try file(FakeIPA.dylibMachO(linking: ["/usr/lib/libA.dylib", "/usr/lib/libB.dylib", "/usr/lib/libA.dylib"], padding: 0))
        #expect(try MachOPatcher.linkedDylibs(in: thin) == ["/usr/lib/libA.dylib", "/usr/lib/libB.dylib"])
        // arm64e first in the file: the arm64 slice's names still come first.
        let e = FakeIPA.dylibMachO(linking: ["/usr/lib/libE.dylib", "/usr/lib/libA.dylib"], padding: 0, cpuSubtype: 2)
        let a = FakeIPA.dylibMachO(linking: ["/usr/lib/libA.dylib"], padding: 0)
        let fat = try file(FakeIPA.fat([(0x0100000C, 2, e), (0x0100000C, 0, a)]))
        #expect(try MachOPatcher.linkedDylibs(in: fat) == ["/usr/lib/libA.dylib", "/usr/lib/libE.dylib"])
    }

    @Test func rewritesToAShorterNameInPlace() throws {
        let original = FakeIPA.dylibMachO(linking: [Self.substrate, "/usr/lib/libc++.1.dylib"], padding: 0)
        let url = try file(original)
        #expect(try MachOPatcher.rewriteDylibNames([Self.substrate: Self.elleKit], in: url) == [Self.substrate])
        let d = try Data(contentsOf: url)
        #expect(d.count == original.count)
        #expect(u32(d, 16) == u32(original, 16))
        #expect(u32(d, 20) == u32(original, 20))
        #expect(libraries(d).map(\.name) == [Self.elleKit, "/usr/lib/libc++.1.dylib"])
        #expect(libraries(d).map(\.cmd) == [0xC, 0x8000_0018])
        // Everything from the end of the load commands on (no free space here) is as it was.
        let end = 32 + Int(u32(original, 20))
        #expect(d.subdata(in: end..<d.count) == original.subdata(in: end..<original.count))
        #expect(try MachOPatcher.linkedDylibs(in: url) == [Self.elleKit, "/usr/lib/libc++.1.dylib"])
    }

    @Test func rewritesToALongerNameUsingFreeSpace() throws {
        let original = FakeIPA.dylibMachO(linking: [Self.libsubstrate, "/usr/lib/libz.1.dylib"], padding: 64)
        let url = try file(original)
        #expect(try MachOPatcher.rewriteDylibNames([Self.libsubstrate: Self.elleKit], in: url) == [Self.libsubstrate])
        let d = try Data(contentsOf: url)
        #expect(d.count == original.count)
        #expect(u32(d, 16) == u32(original, 16))
        #expect(u32(d, 20) == u32(original, 20) + 24)
        let cmds = commands(d)
        #expect(cmds.map(\.cmd) == [0x19, 0xC, 0x8000_0018, 0x1D])
        #expect(libraries(d).map(\.name) == [Self.elleKit, "/usr/lib/libz.1.dylib"])
        // Timestamp and versions kept; the moved command and the signature are byte for byte the same.
        let old = commands(original)
        #expect(d.subdata(in: cmds[1].pos + 12..<cmds[1].pos + 24) == original.subdata(in: old[1].pos + 12..<old[1].pos + 24))
        #expect(cmds[2].pos == old[2].pos + 24)
        #expect(d.subdata(in: cmds[2].pos..<cmds[3].pos + 16) == original.subdata(in: old[2].pos..<old[3].pos + 16))
        let section = 32 + Int(u32(original, 20)) + 64
        #expect(d.subdata(in: section..<d.count) == original.subdata(in: section..<original.count))
        #expect(d.subdata(in: 32 + Int(u32(d, 20))..<section).allSatisfy { $0 == 0 })
    }

    @Test func noRoomLeavesTheFileUnchanged() throws {
        let tight = FakeIPA.dylibMachO(linking: [Self.libsubstrate], padding: 8)
        let url = try file(tight)
        #expect(throws: MachOPatcher.Failure.noRoom) { try MachOPatcher.rewriteDylibNames([Self.libsubstrate: Self.elleKit], in: url) }
        #expect(try Data(contentsOf: url) == tight)
        // One slice with room, one without: neither is written.
        let roomy = FakeIPA.dylibMachO(linking: [Self.libsubstrate], padding: 256, cpuSubtype: 2)
        let fat = FakeIPA.fat([(0x0100000C, 2, roomy), (0x0100000C, 0, tight)])
        let fatURL = try file(fat)
        #expect(throws: MachOPatcher.Failure.noRoom) { try MachOPatcher.rewriteDylibNames([Self.libsubstrate: Self.elleKit], in: fatURL) }
        #expect(try Data(contentsOf: fatURL) == fat)
    }

    @Test func rewritesEverySliceOfAFatBinary() throws {
        let fat = FakeIPA.fat([(0x0100000C, 0, FakeIPA.dylibMachO(linking: [Self.libsubstrate], padding: 64)),
                               (0x0100000C, 2, FakeIPA.dylibMachO(linking: ["/usr/lib/libz.dylib", Self.libsubstrate], padding: 64, cpuSubtype: 2))])
        let url = try file(fat)
        #expect(try MachOPatcher.rewriteDylibNames([Self.libsubstrate: Self.elleKit], in: url) == [Self.libsubstrate])
        let d = try Data(contentsOf: url)
        #expect(d.count == fat.count)
        #expect(d.prefix(8 + 40) == fat.prefix(8 + 40))
        #expect(libraries(d, at: sliceOffset(d, 0)).map(\.name) == [Self.elleKit])
        #expect(libraries(d, at: sliceOffset(d, 1)).map(\.name) == ["/usr/lib/libz.dylib", Self.elleKit])
        #expect(libraries(d, at: sliceOffset(d, 1)).map(\.cmd) == [0xC, 0x8000_0018])
    }

    @Test func refusesA32BitSlice() throws {
        var thin32 = FakeIPA.dylibMachO(linking: [Self.substrate], padding: 64)
        thin32.replaceSubrange(0..<4, with: [0xCE, 0xFA, 0xED, 0xFE])
        let fat = FakeIPA.fat([(0x0100000C, 0, FakeIPA.dylibMachO(linking: [Self.substrate], padding: 64)), (12, 9, thin32)])
        let url = try file(fat)
        #expect(throws: MachOPatcher.Failure.unsupportedSlice) { try MachOPatcher.rewriteDylibNames([Self.substrate: Self.elleKit], in: url) }
        #expect(try Data(contentsOf: url) == fat)
        #expect(throws: MachOPatcher.Failure.unsupportedSlice) { try MachOPatcher.linkedDylibs(in: url) }
    }

    @Test func removesByPredicateOnlyWhenEverythingAfterIsMovable() throws {
        let ours = "@executable_path/Frameworks/XSideTweaks/"
        let original = FakeIPA.dylibMachO(linking: ["/usr/lib/libA.dylib", ours + "a.dylib", "/usr/lib/libB.dylib", ours + "b.dylib", ours + "c.dylib"], padding: 0)
        let url = try file(original)
        let isOurs: (String) -> Bool = { $0.hasPrefix(ours) }
        #expect(try MachOPatcher.removeDylibs(where: isOurs, from: url, movable: isOurs) == [ours + "b.dylib", ours + "c.dylib"])
        let d = try Data(contentsOf: url)
        #expect(d.count == original.count)
        #expect(libraries(d).map(\.name) == ["/usr/lib/libA.dylib", ours + "a.dylib", "/usr/lib/libB.dylib"])
        #expect(commands(d).last?.cmd == 0x1D)
        // The Set form goes through the predicate one.
        #expect(try MachOPatcher.removeDylibs([ours + "a.dylib"], from: url, movable: []) == [])
    }

    @Test func findsJailbreakPathStrings() throws {
        let url = try file(FakeIPA.dylibMachO(linking: [], padding: 0, strings: ["hello", "/var/jb/Library/Application Support/X/marker.txt"]))
        #expect(MachOPatcher.containsAny(["/Library/MobileSubstrate", "/var/jb"], in: url))
        #expect(!MachOPatcher.containsAny(["/Library/MobileSubstrate"], in: url))
        #expect(!MachOPatcher.containsAny([], in: url))
        #expect(!MachOPatcher.containsAny([""], in: url))
        // Past maxBytes is never read.
        let size = try Data(contentsOf: url).count
        #expect(!MachOPatcher.containsAny(["/var/jb"], in: url, maxBytes: size - 45))
        #expect(MachOPatcher.containsAny(["/var/jb"], in: url, maxBytes: size))
        #expect(!MachOPatcher.containsAny(["/var/jb"], in: url, maxBytes: 0))
        #expect(!MachOPatcher.containsAny(["/var/jb"], in: URL(fileURLWithPath: "/nonexistent/xside-\(UUID().uuidString)")))
    }

    /// A real iOS dylib from clang: otool sees the new names and codesign accepts the result.
    @Test(.enabled(if: MachOPatcherTests.hasIOSSDK)) func realDylibIsRewritten() async throws {
        let dir = TestTemp.root.appendingPathComponent("xside-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("t.c"), binary = dir.appendingPathComponent("t.dylib")
        try Data("#include <zlib.h>\nconst char *v(void) { return zlibVersion(); }\n".utf8).write(to: source)
        let runner = ProcessRunner()
        let build = try await runner.run("/usr/bin/xcrun", ["-sdk", "iphoneos", "clang", "-arch", "arm64", "-dynamiclib",
                                                            "-mios-version-min=15.0", "-lz", "-o", binary.path, source.path], cwd: nil)
        #expect(build.status == 0, "\(build.stderr)")
        #expect(try MachOPatcher.linkedDylibs(in: binary).contains("/usr/lib/libz.1.dylib"))
        let long = Self.elleKit + "/../libz-with-a-longer-name.dylib"
        #expect(try MachOPatcher.rewriteDylibNames(["/usr/lib/libz.1.dylib": long], in: binary) == ["/usr/lib/libz.1.dylib"])
        let otool = try await runner.run("/usr/bin/otool", ["-L", binary.path], cwd: nil)
        let listed = String(decoding: otool.stdout, as: UTF8.self)
        #expect(listed.contains(long) && !listed.contains("/usr/lib/libz.1.dylib"), "\(listed)")
        let sign = try await runner.run("/usr/bin/codesign", ["-f", "-s", "-", binary.path], cwd: nil)
        #expect(sign.status == 0, "\(sign.stderr)")
    }

    /// Review fix 1: a name stored past offset 24 (valid) that doesn't fit there but would at 24:
    /// the command keeps at least its size, never shrinks, and the rewrite succeeds without room.
    @Test func aNameAfterAGapIsRewrittenWithoutShrinking() throws {
        // libsubstrate (27) in an 88-byte command whose name starts at 64: 23 bytes there, 63 at 24.
        var d = FakeIPA.dylibMachO(linking: [Self.substrate], padding: 0)
        let c = commands(d)[1].pos
        withUnsafeBytes(of: UInt32(64).littleEndian) { d.replaceSubrange(c + 8..<c + 12, with: $0) }
        d.replaceSubrange(c + 24..<c + 88, with: Data(count: 40) + Array("/usr/lib/libz.1.dylib".utf8) + [0, 0, 0])
        let url = try file(d)
        #expect(try MachOPatcher.linkedDylibs(in: url) == ["/usr/lib/libz.1.dylib"])
        let new = "/usr/lib/a-name-of-forty-bytes-or-so.dylib"
        #expect(try MachOPatcher.rewriteDylibNames(["/usr/lib/libz.1.dylib": new], in: url) == ["/usr/lib/libz.1.dylib"])
        let after = try Data(contentsOf: url)
        #expect(after.count == d.count)
        #expect(u32(after, 20) == u32(d, 20))
        #expect(u32(after, c + 4) == 88)
        #expect(commands(after).map(\.cmd) == [0x19, 0xC, 0x1D])
        #expect(try MachOPatcher.linkedDylibs(in: url) == [new])
        let end = 32 + Int(u32(d, 20))
        #expect(after.subdata(in: end..<after.count) == d.subdata(in: end..<d.count))
    }

    /// Review fix 2: read in chunks; a needle across a chunk boundary is still found.
    @Test func findsAStringAcrossAChunkBoundary() throws {
        let data = FakeIPA.dylibMachO(linking: [], padding: 0, strings: ["/var/jb/usr/lib/x"])
        let url = try file(data)
        let at = data.range(of: Data("/var/jb".utf8))!.lowerBound
        for chunk in [1, 2, 3, 7, 16, at + 3, 1 << 20] {
            #expect(MachOPatcher.containsAny(["/Library/MobileSubstrate", "/var/jb"], in: url, maxBytes: data.count, chunkBytes: chunk), "\(chunk)")
            #expect(!MachOPatcher.containsAny(["/var/jb"], in: url, maxBytes: at + 6, chunkBytes: chunk), "\(chunk)")
            #expect(MachOPatcher.containsAny(["/var/jb"], in: url, maxBytes: at + 7, chunkBytes: chunk), "\(chunk)")
            #expect(!MachOPatcher.containsAny(["/var/jb/usr/lib/y"], in: url, chunkBytes: chunk), "\(chunk)")
        }
    }

    // MARK: Hostile input

    /// A FIFO (or anything not a regular file) is never read: no hang.
    @Test func containsAnyNeverReadsAFIFO() throws {
        let url = TestTemp.root.appendingPathComponent("xside-fifo-\(UUID().uuidString)")
        #expect(mkfifo(url.path, 0o600) == 0)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!MachOPatcher.containsAny(["/var/jb"], in: url))
    }

    @Test func hostileCommandSizesAreRefused() throws {
        let good = FakeIPA.dylibMachO(linking: [Self.substrate], padding: 64)
        let dylib = commands(good)[1].pos
        for size: UInt32 in [0, 4, 0xFFFF_FFF8, UInt32(good.count)] {
            var d = good
            withUnsafeBytes(of: size.littleEndian) { d.replaceSubrange(dylib + 4..<dylib + 8, with: $0) }
            let url = try file(d)
            #expect(throws: MachOPatcher.Failure.notMachO) { try MachOPatcher.rewriteDylibNames([Self.substrate: Self.elleKit], in: url) }
            #expect(throws: MachOPatcher.Failure.notMachO) { try MachOPatcher.linkedDylibs(in: url) }
            #expect(try Data(contentsOf: url) == d)
        }
        // sizeofcmds past the file, ncmds more than fits.
        for (field, value): (Int, UInt32) in [(20, 0xFFFF_FFF0), (16, 0x4000_0000), (16, 100)] {
            var d = good
            withUnsafeBytes(of: value.littleEndian) { d.replaceSubrange(field..<field + 4, with: $0) }
            let url = try file(d)
            #expect(throws: MachOPatcher.Failure.self) { try MachOPatcher.rewriteDylibNames([Self.substrate: Self.elleKit], in: url) }
            #expect(try Data(contentsOf: url) == d)
        }
    }

    @Test func truncatedFilesAreRefused() throws {
        let good = FakeIPA.dylibMachO(linking: [Self.substrate], padding: 64)
        for length in [0, 3, 31, 32, 100, 32 + Int(u32(good, 20)) - 1] {
            let url = try file(good.prefix(length))
            #expect(throws: MachOPatcher.Failure.self) { try MachOPatcher.rewriteDylibNames([Self.substrate: Self.elleKit], in: url) }
            #expect(throws: MachOPatcher.Failure.self) { try MachOPatcher.linkedDylibs(in: url) }
            #expect(try Data(contentsOf: url) == good.prefix(length))
        }
        // Commands intact but the section claimed past the end: a longer name finds no room.
        let cut = good.prefix(32 + Int(u32(good, 20)) + 8)
        let url = try file(cut)
        #expect(throws: MachOPatcher.Failure.noRoom) { try MachOPatcher.rewriteDylibNames([Self.libsubstrate: Self.elleKit, Self.substrate: Self.elleKit + "/longer/than/the/original/name/by/far"], in: url) }
        #expect(try Data(contentsOf: url) == cut)
    }

    /// A name offset outside its command, or a name with no NUL inside it: never matched, never listed.
    @Test func malformedNamesAreIgnored() throws {
        let good = FakeIPA.dylibMachO(linking: [Self.substrate], padding: 64)
        let c = commands(good)[1].pos, size = Int(u32(good, c + 4))
        var outside = good
        withUnsafeBytes(of: UInt32(size).littleEndian) { outside.replaceSubrange(c + 8..<c + 12, with: $0) }
        var below = good
        withUnsafeBytes(of: UInt32(8).littleEndian) { below.replaceSubrange(c + 8..<c + 12, with: $0) }
        var unterminated = good
        unterminated.replaceSubrange(c + 24..<c + size, with: Data(repeating: 0x41, count: size - 24))
        for d in [outside, below, unterminated] {
            let url = try file(d)
            #expect(try MachOPatcher.linkedDylibs(in: url) == [])
            #expect(try MachOPatcher.rewriteDylibNames([Self.substrate: Self.elleKit], in: url) == [])
            #expect(try Data(contentsOf: url) == d)
        }
        #expect(!MachOPatcher.loadsAnySlice(Self.substrate, in: try file(unterminated)))
    }

    /// Bytes the rewrite would grow into belong to something (here a second slice's header):
    /// refused, nothing written.
    @Test func growingIntoAnotherSliceIsRefused() throws {
        var a = FakeIPA.dylibMachO(linking: [Self.libsubstrate], padding: 256)
        let end = 32 + Int(u32(a, 20))
        var inner = Data()
        for v: UInt32 in [0xFEEDFACF, 0x0100000C, 0, 6, 0, 0, 0, 0] { withUnsafeBytes(of: v.littleEndian) { inner.append(contentsOf: $0) } }
        a.replaceSubrange(end + 8..<end + 8 + 32, with: inner)
        var fat = FakeIPA.fat([(0x0100000C, 0, a)])
        // A second fat entry pointing inside the first slice's free space.
        fat.replaceSubrange(4..<8, with: [0, 0, 0, 2])
        var entry = Data()
        for v: UInt32 in [0x0100000C, 2, UInt32(0x4000 + end + 8), 32, 14] { withUnsafeBytes(of: v.bigEndian) { entry.append(contentsOf: $0) } }
        fat.replaceSubrange(28..<48, with: entry)
        let url = try file(fat)
        #expect(throws: MachOPatcher.Failure.self) { try MachOPatcher.rewriteDylibNames([Self.libsubstrate: Self.elleKit], in: url) }
        #expect(try Data(contentsOf: url) == fat)
    }

    /// A slice whose header sits inside the fat header's arch table: refused.
    @Test func sliceInsideTheFatHeaderIsRefused() throws {
        var fat = FakeIPA.fat([(0x0100000C, 0, FakeIPA.dylibMachO(linking: [Self.substrate], padding: 64))])
        // The arch's cpusubtype field reads as a 64-bit magic; a second arch points at it.
        fat.replaceSubrange(4..<8, with: [0, 0, 0, 2])
        var entry = Data()
        for v: UInt32 in [0x0100000C, 0xCFFAEDFE, 0, 0, 0] { withUnsafeBytes(of: v.bigEndian) { entry.append(contentsOf: $0) } }
        withUnsafeBytes(of: UInt32(32).bigEndian) { entry.replaceSubrange(8..<12, with: $0) }
        fat.replaceSubrange(28..<48, with: entry)
        let url = try file(fat)
        #expect(throws: MachOPatcher.Failure.self) { try MachOPatcher.rewriteDylibNames([Self.substrate: Self.elleKit], in: url) }
        #expect(try Data(contentsOf: url) == fat)
    }
}

