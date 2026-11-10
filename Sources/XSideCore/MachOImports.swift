import Foundation

/// The C function hooks a tweak binary imports. A tweak that hooks C functions
/// (`MSHookFunction`, libhooker's `LHHookFunctions`, Substitute's `substitute_hook_functions`)
/// writes into the app's code pages: stock iOS kills the app for it (SIGKILL, CODESIGNING
/// namespace, seen on iOS 27.3 with ElleKit). Its Objective-C hooks still work.
public enum MachOImports {
    /// Mach-O symbol name -> the function's name for people.
    static let cFunctionHooks: [String: String] = [
        "_MSHookFunction": "MSHookFunction",
        "__MSHookFunction": "_MSHookFunction",
        "_LHHookFunctions": "LHHookFunctions",
        "_substitute_hook_functions": "substitute_hook_functions",
    ]
    /// Symbol table entries read per slice at most.
    static let maxSymbols = 4_000_000
    static let maxNameBytes = 1024

    /// The C function hooks `binary` imports, by their names for people, sorted; empty when none
    /// or when it isn't a readable Mach-O. Read from each 64-bit slice's undefined external
    /// symbols (`LC_SYMTAB`) and chained-fixup imports (`LC_DYLD_CHAINED_FIXUPS`); every offset
    /// is checked against the file, nothing traps.
    public static func cFunctionHooks(in binary: URL) -> [String] {
        guard let data = try? Data(contentsOf: binary, options: .mappedIfSafe) else { return [] }
        return cFunctionHooks(in: data)
    }

    static func cFunctionHooks(in data: Data) -> [String] {
        importedSymbols(in: data, wanted: Set(cFunctionHooks.keys)).compactMap { cFunctionHooks[$0] }.sorted()
    }

    /// Which of `wanted` (Mach-O symbol names, each starting with "_") `data` imports, from the
    /// same tables as `cFunctionHooks`.
    static func importedSymbols(in data: Data, wanted: Set<String>) -> Set<String> {
        guard let starts = try? IPAInspector.sliceOffsets(data) else { return [] }
        var found = Set<String>()
        for start in Set(starts) {
            guard let commands = try? MachOPatcher.loadCommands(data, at: start) else { continue }
            for c in commands {
                if c.cmd == 0x2, c.size >= 24 { // LC_SYMTAB
                    found.formUnion(undefinedSymbols(data, start: start, symoff: u32(data, c.pos + 8),
                                                     nsyms: u32(data, c.pos + 12), stroff: u32(data, c.pos + 16),
                                                     strsize: u32(data, c.pos + 20), wanted: wanted))
                } else if c.cmd == 0x8000_0034, c.size >= 16 { // LC_DYLD_CHAINED_FIXUPS
                    found.formUnion(chainedImports(data, start: start, dataoff: u32(data, c.pos + 8),
                                                   datasize: u32(data, c.pos + 12), wanted: wanted))
                }
            }
        }
        return found
    }

    private static func u32(_ data: Data, _ at: Int) -> Int { Int(MachOPatcher.u32(data, at)) }

    /// A slice-relative range inside the file, or nil.
    private static func range(_ data: Data, start: Int, offset: Int, length: Int) -> Range<Int>? {
        let (lower, o1) = start.addingReportingOverflow(offset)
        guard !o1, lower >= 0, length >= 0 else { return nil }
        let (upper, o2) = lower.addingReportingOverflow(length)
        guard !o2, upper <= data.count else { return nil }
        return lower..<upper
    }

    /// The wanted name at `at` inside `table` (NUL-terminated there), else nil.
    private static func wantedName(_ data: Data, table: Range<Int>, at offset: Int, wanted: Set<String>) -> String? {
        guard offset >= 0, offset < table.count else { return nil }
        let from = table.lowerBound + offset
        let to = min(table.upperBound, from + maxNameBytes)
        // Cheap first: every wanted name starts with "_".
        guard data[data.startIndex + from] == UInt8(ascii: "_") else { return nil }
        guard let nul = data[(data.startIndex + from)..<(data.startIndex + to)].firstIndex(of: 0) else { return nil }
        let name = String(decoding: data[(data.startIndex + from)..<nul], as: UTF8.self)
        return wanted.contains(name) ? name : nil
    }

    /// `nlist_64` entries that are undefined (`N_UNDF`), external and not debugging entries.
    private static func undefinedSymbols(_ data: Data, start: Int, symoff: Int, nsyms: Int,
                                         stroff: Int, strsize: Int, wanted: Set<String>) -> Set<String> {
        guard nsyms <= maxSymbols, let symbols = range(data, start: start, offset: symoff, length: nsyms * 16),
              let strings = range(data, start: start, offset: stroff, length: strsize) else { return [] }
        var out = Set<String>()
        for i in 0..<nsyms {
            let entry = symbols.lowerBound + i * 16
            let type = data[data.startIndex + entry + 4]
            guard type & 0xE0 == 0, type & 0x0E == 0, type & 0x01 == 1 else { continue }
            if let name = wantedName(data, table: strings, at: u32(data, entry), wanted: wanted) { out.insert(name) }
        }
        return out
    }

    /// `dyld_chained_fixups_header` imports, in their three formats (uncompressed names only).
    private static func chainedImports(_ data: Data, start: Int, dataoff: Int, datasize: Int,
                                       wanted: Set<String>) -> Set<String> {
        guard datasize >= 28, let blob = range(data, start: start, offset: dataoff, length: datasize) else { return [] }
        let base = blob.lowerBound
        let importsOffset = u32(data, base + 8), symbolsOffset = u32(data, base + 12)
        let count = u32(data, base + 16), format = u32(data, base + 20), symbolsFormat = u32(data, base + 24)
        guard symbolsFormat == 0, symbolsOffset <= datasize, count <= maxSymbols else { return [] }
        let size: Int
        switch format {
        case 1: size = 4
        case 2: size = 8
        case 3: size = 16
        default: return []
        }
        guard importsOffset <= datasize, count * size <= datasize - importsOffset else { return [] }
        let names = (base + symbolsOffset)..<blob.upperBound
        var out = Set<String>()
        for i in 0..<count {
            let at = base + importsOffset + i * size
            let nameOffset: Int
            if format == 3 {
                nameOffset = u32(data, at + 4)
            } else {
                nameOffset = u32(data, at) >> 9
            }
            if let name = wantedName(data, table: names, at: nameOffset, wanted: wanted) { out.insert(name) }
        }
        return out
    }
}
