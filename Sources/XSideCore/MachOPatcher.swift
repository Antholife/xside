import Foundation

/// Adds a weak dylib load command to an executable, in place: how the welcome popup's library
/// gets loaded by an app (see `Resigner`). Weak, so a missing library never stops the app from
/// launching. Done before signing: `codesign -f` then signs the new layout.
public enum MachOPatcher {
    public enum Outcome: Equatable, Sendable {
        case added
        /// Every slice already loads that path (an IPA patched before): nothing written.
        case alreadyPresent
    }

    public enum Failure: Error, Equatable, Sendable {
        case notMachO
        /// A 32-bit slice: not something an iOS 15+ app ships.
        case unsupportedSlice
        /// Not enough free space between the load commands and the first section.
        case noRoom
    }

    static let loadDylib: UInt32 = 0xC
    static let loadWeakDylib: UInt32 = 0x8000_0018
    static let codeSignature: UInt32 = 0x1D
    static let segment64: UInt32 = 0x19
    private static let headerSize = 32

    /// Adds `LC_LOAD_WEAK_DYLIB dylibPath` to every 64-bit slice of `executable` that doesn't
    /// load it yet. All slices are checked before anything is written: on a failure the file is
    /// unchanged. Before an `LC_CODE_SIGNATURE` that ends the commands, else at their end.
    public static func addWeakDylib(_ dylibPath: String, to executable: URL) throws -> Outcome {
        guard var data = try? Data(contentsOf: executable),
              let starts = try? IPAInspector.sliceOffsets(data) else { throw Failure.notMachO }
        let command = dylibCommand(dylibPath)
        var toPatch: [(start: Int, commands: [(cmd: UInt32, pos: Int, size: Int)])] = []
        for start in starts {
            let commands = try loadCommands(data, at: start)
            if commands.contains(where: { [loadDylib, loadWeakDylib].contains($0.cmd) && name(data, $0) == dylibPath }) {
                continue
            }
            let end = start + headerSize + Int(u32(data, start + 20))
            // Inside the file too: an untrusted binary may claim anything.
            guard let firstData = firstSectionOffset(data, start: start, commands: commands),
                  start + firstData >= end + command.count,
                  start + firstData <= data.count, end + command.count <= data.count,
                  data[end..<end + command.count].allSatisfy({ $0 == 0 }) else { throw Failure.noRoom }
            toPatch.append((start, commands))
        }
        guard !toPatch.isEmpty else { return .alreadyPresent }
        for (start, commands) in toPatch {
            let end = start + headerSize + Int(u32(data, start + 20))
            if let last = commands.last, last.cmd == codeSignature, last.pos + last.size == end {
                let signature = data.subdata(in: last.pos..<end)
                data.replaceSubrange(last.pos..<end + command.count, with: command + signature)
            } else {
                data.replaceSubrange(end..<end + command.count, with: command)
            }
            put(&data, start + 16, u32(data, start + 16) + 1)
            put(&data, start + 20, u32(data, start + 20) + UInt32(command.count))
        }
        do { try data.write(to: executable, options: .atomic) } catch { throw Failure.notMachO }
        return .added
    }

    /// `dylib_command`: name right after the 24-byte header, NUL-terminated, size a multiple of 8.
    static func dylibCommand(_ path: String) -> Data {
        var name = Array(path.utf8) + [0]
        let size = (24 + name.count + 7) & ~7
        name += Array(repeating: 0, count: size - 24 - name.count)
        var d = Data()
        for v in [loadWeakDylib, UInt32(size), 24, 2, 0x0001_0000, 0x0001_0000] {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        d.append(contentsOf: name)
        return d
    }

    /// The commands of the slice at `start`, each size checked against `sizeofcmds` and the file.
    private static func loadCommands(_ data: Data, at start: Int) throws -> [(cmd: UInt32, pos: Int, size: Int)] {
        guard start + headerSize <= data.count else { throw Failure.notMachO }
        switch u32(data, start) {
        case 0xFEEDFACF: break
        case 0xFEEDFACE: throw Failure.unsupportedSlice
        default: throw Failure.notMachO
        }
        let ncmds = Int(u32(data, start + 16)), sizeofcmds = Int(u32(data, start + 20))
        let end = start + headerSize + sizeofcmds
        guard ncmds * 8 <= sizeofcmds, end <= data.count else { throw Failure.notMachO }
        var pos = start + headerSize
        var result: [(cmd: UInt32, pos: Int, size: Int)] = []
        for _ in 0..<ncmds {
            guard pos + 8 <= end else { throw Failure.notMachO }
            let size = Int(u32(data, pos + 4))
            guard size >= 8, pos + size <= end else { throw Failure.notMachO }
            result.append((u32(data, pos), pos, size))
            pos += size
        }
        return result
    }

    /// The smallest non-zero file offset of a section (relative to the slice): where the free
    /// space after the load commands ends.
    private static func firstSectionOffset(_ data: Data, start: Int,
                                           commands: [(cmd: UInt32, pos: Int, size: Int)]) -> Int? {
        var first: Int?
        for c in commands where c.cmd == segment64 && c.size >= 72 {
            let nsects = Int(u32(data, c.pos + 64))
            guard 72 + nsects * 80 <= c.size else { continue }
            for i in 0..<nsects {
                let offset = Int(u32(data, c.pos + 72 + i * 80 + 48))
                if offset > 0 { first = min(first ?? offset, offset) }
            }
        }
        return first
    }

    private static func name(_ data: Data, _ c: (cmd: UInt32, pos: Int, size: Int)) -> String? {
        guard c.size >= 24 else { return nil }
        let offset = Int(u32(data, c.pos + 8))
        guard offset >= 24, offset < c.size else { return nil }
        let bytes = data[(c.pos + offset)..<(c.pos + c.size)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func u32(_ data: Data, _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= data.count else { return 0 }
        return data[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    private static func put(_ data: inout Data, _ at: Int, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(at..<at + 4, with: $0) }
    }
}
