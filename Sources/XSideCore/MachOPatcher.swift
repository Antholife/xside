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
    static let rpath: UInt32 = 0x8000_001C
    static let headerSize = 32

    /// Adds `LC_LOAD_WEAK_DYLIB dylibPath` to every 64-bit slice of `executable` that doesn't
    /// load it yet. All slices are checked before anything is written: on a failure the file is
    /// unchanged. Before an `LC_CODE_SIGNATURE` that ends the commands, else at their end.
    public static func addWeakDylib(_ dylibPath: String, to executable: URL) throws -> Outcome {
        guard var data = try? Data(contentsOf: executable),
              let starts = try? IPAInspector.sliceOffsets(data) else { throw Failure.notMachO }
        let command = dylibCommand(dylibPath)
        var toPatch: [(start: Int, commands: [(cmd: UInt32, pos: Int, size: Int)])] = []
        var seen = Set<Int>()
        for start in starts where seen.insert(start).inserted {
            let commands = try loadCommands(data, at: start)
            if commands.contains(where: { [loadDylib, loadWeakDylib].contains($0.cmd) && dylibName(data, $0) == dylibPath }) {
                continue
            }
            let end = start + headerSize + Int(u32(data, start + 20))
            // Inside the file too: an untrusted binary may claim anything.
            guard let firstData = firstSectionOffset(data, start: start, commands: commands),
                  start + firstData >= end + command.count,
                  start + firstData <= data.count, end + command.count <= data.count,
                  data[end..<end + command.count].allSatisfy({ $0 == 0 }) else { throw Failure.noRoom }
            guard !u32(data, start + 16).addingReportingOverflow(1).overflow,
                  !u32(data, start + 20).addingReportingOverflow(UInt32(command.count)).overflow else { throw Failure.notMachO }
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

    /// Whether every 64-bit slice of `executable` already loads `dylibPath` (false when unreadable).
    public static func loadsDylib(_ dylibPath: String, in executable: URL) -> Bool {
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe),
              let starts = try? IPAInspector.sliceOffsets(data), !starts.isEmpty else { return false }
        return starts.allSatisfy { start in
            guard let commands = try? loadCommands(data, at: start) else { return false }
            return commands.contains { [loadDylib, loadWeakDylib].contains($0.cmd) && dylibName(data, $0) == dylibPath }
        }
    }

    /// Whether some 64-bit slice of `executable` loads `dylibPath` (false when unreadable).
    public static func loadsAnySlice(_ dylibPath: String, in executable: URL) -> Bool {
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe),
              let starts = try? IPAInspector.sliceOffsets(data) else { return false }
        return starts.contains { start in
            guard let commands = try? loadCommands(data, at: start) else { return false }
            return commands.contains { dylibLoads.contains($0.cmd) && dylibName(data, $0) == dylibPath }
        }
    }

    /// The free bytes between the load commands and the first section, in the slice that has
    /// the fewest: what a new load command can take.
    public static func freeSpace(in executable: URL) throws -> Int {
        guard let data = try? Data(contentsOf: executable),
              let starts = try? IPAInspector.sliceOffsets(data) else { throw Failure.notMachO }
        var smallest = Int.max
        for start in starts {
            let commands = try loadCommands(data, at: start)
            let end = headerSize + Int(u32(data, start + 20))
            guard let first = firstSectionOffset(data, start: start, commands: commands) else { throw Failure.noRoom }
            smallest = min(smallest, max(0, first - end))
        }
        return smallest == .max ? 0 : smallest
    }

    /// The `LC_RPATH` paths of every slice, in order, each once.
    public static func rpaths(in executable: URL) throws -> [String] {
        guard let data = try? Data(contentsOf: executable),
              let starts = try? IPAInspector.sliceOffsets(data) else { throw Failure.notMachO }
        var paths: [String] = []
        for start in starts {
            for c in try loadCommands(data, at: start) where c.cmd == rpath {
                if let path = rpathName(data, c), !paths.contains(path) { paths.append(path) }
            }
        }
        return paths
    }

    /// Removes the `LC_RPATH` commands whose path matches, in every slice: the commands after
    /// them move up and the freed bytes become free space. The file keeps its size and every
    /// byte past each slice's load commands stays where it was. All slices are read before
    /// anything is written (a slice the fat header lists twice is done once). Returns the paths
    /// removed (one per command).
    @discardableResult
    public static func removeRpaths(from executable: URL, where matches: (String) -> Bool) throws -> [String] {
        try removeCommands(from: executable) { data, commands in
            var drop: [Int: String] = [:]
            for (i, c) in commands.enumerated() where c.cmd == rpath {
                if let path = rpathName(data, c), matches(path) { drop[i] = path }
            }
            return drop
        }
    }

    /// Commands that make dyld load a library (their order is the ordinals binds refer to).
    static let dylibLoads: Set<UInt32> = [loadDylib, loadWeakDylib, 0x8000_001F /* REEXPORT */,
                                          0x20 /* LAZY_LOAD */, 0x8000_0023 /* LOAD_UPWARD */]

    /// Removes the load commands of `paths` (libraries XSide added at an earlier signing): see
    /// `removeDylibs(where:from:movable:)`.
    @discardableResult
    public static func removeDylibs(_ paths: Set<String>, from executable: URL, movable: Set<String>) throws -> [String] {
        try removeDylibs(where: paths.contains, from: executable, movable: movable.contains)
    }

    /// Removes the library commands whose name `matches`, in every slice, like `removeRpaths`.
    /// A command is removed only when every library command after it names a `movable` library
    /// (XSide's own, which nothing in the app binds to): the ordinals of the app's own libraries
    /// never change. A name that isn't NUL-terminated inside its command is never movable.
    /// Returns the paths removed (one per command).
    @discardableResult
    public static func removeDylibs(where matches: (String) -> Bool, from executable: URL,
                                    movable: (String) -> Bool) throws -> [String] {
        try removeCommands(from: executable) { data, commands in
            var drop: [Int: String] = [:]
            for (i, c) in commands.enumerated() where dylibLoads.contains(c.cmd) {
                guard let name = dylibName(data, c), matches(name) else { continue }
                let after = commands[(i + 1)...].filter { dylibLoads.contains($0.cmd) }
                if after.allSatisfy({ dylibName(data, $0).map(movable) == true }) { drop[i] = name }
            }
            return drop
        }
    }

    /// Every library the binary loads (`dylibLoads` commands), each name once: the arm64
    /// slice's first, then the other slices' in file order.
    public static func linkedDylibs(in binary: URL) throws -> [String] {
        guard let data = try? Data(contentsOf: binary, options: .mappedIfSafe),
              let starts = try? IPAInspector.sliceOffsets(data) else { throw Failure.notMachO }
        var unique: [Int] = []
        for start in starts where !unique.contains(start) { unique.append(start) }
        let isARM64 = { (start: Int) in u32(data, start + 4) == 0x0100_000C && u32(data, start + 8) & 0x00FF_FFFF != 2 }
        var names: [String] = []
        for start in unique.filter(isARM64) + unique.filter({ !isARM64($0) }) {
            for c in try loadCommands(data, at: start) where dylibLoads.contains(c.cmd) {
                if let name = dylibName(data, c), !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    /// Gives every library command whose name is a key of `map` the matching name, in every
    /// slice, keeping its `cmd`, timestamp and versions (`install_name_tool -change`). A name
    /// that fits stays in its command (same size); a longer one makes the command grow (to a
    /// multiple of 8) and the commands after it move, into the zeros between the load commands
    /// and the first section: `sizeofcmds` grows by the difference, nothing past that free space
    /// moves and the file keeps its size. All slices are planned before anything is written: a
    /// slice without the room throws `Failure.noRoom`, any other problem `notMachO` or
    /// `unsupportedSlice`, and the file is then unchanged. Returns the old names rewritten,
    /// each once, in order.
    public static func rewriteDylibNames(_ map: [String: String], in binary: URL) throws -> [String] {
        let map = map.filter { !$0.key.isEmpty && !$0.value.isEmpty && !$0.value.utf8.contains(0) }
        guard var data = try? Data(contentsOf: binary),
              let starts = try? IPAInspector.sliceOffsets(data) else { throw Failure.notMachO }
        let fatEnd = fatHeaderEnd(data)
        var edits: [(start: Int, area: Data, sizeofcmds: UInt32)] = []
        var rewritten: [String] = []
        var seen = Set<Int>()
        for start in starts where seen.insert(start).inserted {
            let commands = try loadCommands(data, at: start)
            // A slice whose header lies in the fat header's arch table: hostile.
            guard start >= fatEnd else { throw Failure.notMachO }
            guard !map.isEmpty else { continue }
            let begin = start + headerSize
            let end = begin + Int(u32(data, start + 20))
            var area = Data()
            var changed = false
            for c in commands {
                let command = data.subdata(in: c.pos..<c.pos + c.size)
                guard dylibLoads.contains(c.cmd), let name = dylibName(data, c), let new = map[name] else {
                    area.append(command)
                    continue
                }
                area.append(try renamed(command, to: new))
                changed = true
                if !rewritten.contains(name) { rewritten.append(name) }
            }
            guard changed else { continue }
            // Whatever followed the commands inside sizeofcmds (slack) moves with them.
            let lastEnd = commands.last.map { $0.pos + $0.size } ?? begin
            area.append(data.subdata(in: lastEnd..<end))
            let growth = area.count - (end - begin)
            guard growth >= 0, let grown = UInt32(exactly: growth) else { throw Failure.notMachO }
            if growth > 0 {
                // Only into zeros before the first section, inside the file: an untrusted
                // binary may claim anything.
                guard let first = firstSectionOffset(data, start: start, commands: commands),
                      start + first <= data.count, end + growth <= start + first,
                      data[end..<end + growth].allSatisfy({ $0 == 0 }) else { throw Failure.noRoom }
            }
            let (sizeofcmds, overflow) = u32(data, start + 20).addingReportingOverflow(grown)
            guard !overflow else { throw Failure.notMachO }
            edits.append((start, area, sizeofcmds))
        }
        guard !edits.isEmpty else { return [] }
        // Two slices whose rewritten commands overlap: not something to rewrite.
        let spans = edits.map { (begin: $0.start, end: $0.start + headerSize + $0.area.count) }.sorted { $0.begin < $1.begin }
        for (a, b) in zip(spans, spans.dropFirst()) where b.begin < a.end { throw Failure.notMachO }
        let size = data.count
        for edit in edits {
            let begin = edit.start + headerSize
            data.replaceSubrange(begin..<begin + edit.area.count, with: edit.area)
            put(&data, edit.start + 20, edit.sizeofcmds)
        }
        guard data.count == size else { throw Failure.notMachO }
        do { try data.write(to: binary, options: .atomic) } catch { throw Failure.notMachO }
        return rewritten
    }

    /// `command` (a `dylib_command` whose name was checked) naming `name`: in place when it fits
    /// (rest zeroed), else rebuilt with the name right after its 24-byte header.
    private static func renamed(_ command: Data, to name: String) throws -> Data {
        let bytes = Array(name.utf8)
        let offset = Int(u32(command, 8))
        guard command.count >= 24, offset >= 24, offset < command.count else { throw Failure.notMachO }
        if bytes.count < command.count - offset {
            var c = command
            c.replaceSubrange(offset..<command.count, with: bytes + Array(repeating: 0, count: command.count - offset - bytes.count))
            return c
        }
        let (needed, o1) = (24 + 1 + 7).addingReportingOverflow(bytes.count)
        guard !o1, let size = UInt32(exactly: needed & ~7) else { throw Failure.noRoom }
        var c = command.subdata(in: 0..<24)
        put(&c, 4, size)
        put(&c, 8, 24)
        c.append(contentsOf: bytes)
        c.append(Data(count: Int(size) - c.count))
        return c
    }

    /// Where a fat file's arch table ends (0 for a thin file).
    private static func fatHeaderEnd(_ data: Data) -> Int {
        guard data.count >= 8 else { return 0 }
        let be = { (at: Int) -> UInt32 in u32(data, at).byteSwapped }
        switch be(0) {
        case 0xCAFEBABE: return 8 + 20 * Int(be(4))
        case 0xCAFEBABF: return 8 + 32 * Int(be(4))
        default: return 0
        }
    }

    /// Whether the first `maxBytes` of `binary` contain one of `needles` (empty ones never
    /// match). Only a regular file is read (never a FIFO or device, which could block); false
    /// when unreadable.
    public static func containsAny(_ needles: [String], in binary: URL, maxBytes: Int = 256 * 1024 * 1024) -> Bool {
        let needles = needles.map { Data($0.utf8) }.filter { !$0.isEmpty }
        guard !needles.isEmpty, maxBytes > 0 else { return false }
        let fd = open(binary.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        let limit = Int(min(Int64(maxBytes), Int64(info.st_size)))
        guard limit > 0 else { return false }
        var data = Data(count: limit)
        var read = 0
        data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            while read < limit {
                let n = Darwin.read(fd, base + read, limit - read)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break } // end of file (it shrank) or an error: search what was read
                read += n
            }
        }
        guard read > 0 else { return false }
        let content = data.prefix(read)
        return needles.contains { content.range(of: $0) != nil }
    }

    /// Removes the commands `select` picks (index → what to report), in every slice: see `removeRpaths`.
    private static func removeCommands(from executable: URL,
                                       select: (Data, [(cmd: UInt32, pos: Int, size: Int)]) -> [Int: String]) throws -> [String] {
        guard var data = try? Data(contentsOf: executable),
              let starts = try? IPAInspector.sliceOffsets(data) else { throw Failure.notMachO }
        var plans: [(start: Int, commands: [(cmd: UInt32, pos: Int, size: Int)], drop: Set<Int>)] = []
        var removed: [String] = []
        var seen = Set<Int>()
        for start in starts where seen.insert(start).inserted {
            let commands = try loadCommands(data, at: start)
            let picked = select(data, commands)
            removed += picked.sorted { $0.key < $1.key }.map(\.value)
            if !picked.isEmpty { plans.append((start, commands, Set(picked.keys))) }
        }
        guard !plans.isEmpty else { return [] }
        // Two slices whose load commands overlap: not something to rewrite.
        let spans = plans.map { (begin: $0.start, end: $0.start + headerSize + Int(u32(data, $0.start + 20))) }
            .sorted { $0.begin < $1.begin }
        for (a, b) in zip(spans, spans.dropFirst()) where b.begin < a.end { throw Failure.notMachO }
        var edits: [(start: Int, kept: Data, ncmds: UInt32, sizeofcmds: UInt32)] = []
        for (start, commands, drop) in plans {
            let begin = start + headerSize
            let end = begin + Int(u32(data, start + 20))
            var kept = Data()
            var freed = 0
            for (i, c) in commands.enumerated() {
                if drop.contains(i) { freed += c.size } else { kept.append(data.subdata(in: c.pos..<c.pos + c.size)) }
            }
            // Whatever followed the commands inside sizeofcmds (slack) moves up with them; the
            // freed bytes become zeros at the end: the span keeps its exact length.
            let lastEnd = commands.last.map { $0.pos + $0.size } ?? begin
            kept.append(data.subdata(in: lastEnd..<end))
            kept.append(Data(count: (end - begin) - kept.count))
            let (ncmds, o1) = u32(data, start + 16).subtractingReportingOverflow(UInt32(drop.count))
            let (sizeofcmds, o2) = u32(data, start + 20).subtractingReportingOverflow(UInt32(freed))
            guard !o1, !o2, kept.count == end - begin else { throw Failure.notMachO }
            edits.append((start, kept, ncmds, sizeofcmds))
        }
        let size = data.count
        for edit in edits {
            let begin = edit.start + headerSize
            data.replaceSubrange(begin..<begin + edit.kept.count, with: edit.kept)
            put(&data, edit.start + 16, edit.ncmds)
            put(&data, edit.start + 20, edit.sizeofcmds)
        }
        guard data.count == size else { throw Failure.notMachO }
        do { try data.write(to: executable, options: .atomic) } catch { throw Failure.notMachO }
        return removed
    }

    /// The path of an `rpath_command` (its `lc_str` offset, NUL-terminated within the command).
    private static func rpathName(_ data: Data, _ c: (cmd: UInt32, pos: Int, size: Int)) -> String? {
        guard c.size >= 12 else { return nil }
        let offset = Int(u32(data, c.pos + 8))
        guard offset >= 12, offset < c.size else { return nil }
        return String(decoding: data[(c.pos + offset)..<(c.pos + c.size)].prefix { $0 != 0 }, as: UTF8.self)
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
    static func loadCommands(_ data: Data, at start: Int) throws -> [(cmd: UInt32, pos: Int, size: Int)] {
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
    static func firstSectionOffset(_ data: Data, start: Int,
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

    /// The library a `dylib_command` names (its `lc_str` offset, NUL-terminated within the command;
    /// nil otherwise).
    static func dylibName(_ data: Data, _ c: (cmd: UInt32, pos: Int, size: Int)) -> String? {
        guard c.size >= 24 else { return nil }
        let offset = Int(u32(data, c.pos + 8))
        guard offset >= 24, offset < c.size else { return nil }
        let bytes = data[(c.pos + offset)..<(c.pos + c.size)]
        // Not NUL-terminated inside the command: dyld refuses it, so do we.
        guard let nul = bytes.firstIndex(of: 0) else { return nil }
        return String(decoding: bytes[..<nul], as: UTF8.self)
    }

    static func u32(_ data: Data, _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= data.count else { return 0 }
        return data[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    private static func put(_ data: inout Data, _ at: Int, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(at..<at + 4, with: $0) }
    }
}
