import Foundation
import Testing
@testable import XSideCore

/// C function hooks a tweak imports: read from the symbol table and the chained-fixup imports,
/// from hostile files without trapping.
struct MachOImportsTests {
    /// A 64-bit Mach-O with one `LC_SYMTAB`: `symbols` as (name, n_type).
    static func symtabMachO(_ symbols: [(String, UInt8)], nsymsOverride: UInt32? = nil, stroffOverride: UInt32? = nil) -> Data {
        var strings = Data([0x20, 0x00]) // index 0: " \0", as ld writes it
        var nlist = Data()
        for (name, type) in symbols {
            let strx = UInt32(strings.count)
            strings.append(contentsOf: Array(name.utf8) + [0])
            nlist.append(le(strx)); nlist.append(type); nlist.append(0); nlist.append(contentsOf: [0, 0]); nlist.append(le64(0))
        }
        let headerAndCommands = 32 + 24
        let symoff = UInt32(headerAndCommands), stroff = UInt32(headerAndCommands + nlist.count)
        var d = header(ncmds: 1, sizeofcmds: 24)
        d.append(le(0x2)); d.append(le(24)); d.append(le(symoff)); d.append(le(nsymsOverride ?? UInt32(symbols.count)))
        d.append(le(stroffOverride ?? stroff)); d.append(le(UInt32(strings.count)))
        return d + nlist + strings
    }

    /// A 64-bit Mach-O with `LC_DYLD_CHAINED_FIXUPS` listing `names` in import `format` (1, 2 or 3).
    static func chainedMachO(_ names: [String], format: UInt32, countOverride: UInt32? = nil) -> Data {
        var pool = Data([0])
        var offsets: [UInt32] = []
        for n in names { offsets.append(UInt32(pool.count)); pool.append(contentsOf: Array(n.utf8) + [0]) }
        var imports = Data()
        for o in offsets {
            switch format {
            case 1: imports.append(le(o << 9 | 1))
            case 2: imports.append(le(o << 9 | 1)); imports.append(le(0))
            default: imports.append(le64(UInt64(o) << 32 | 1)); imports.append(le64(0))
            }
        }
        var blob = Data()
        blob.append(le(0)); blob.append(le(28)); blob.append(le(28)); blob.append(le(UInt32(28 + imports.count)))
        blob.append(le(countOverride ?? UInt32(names.count))); blob.append(le(format)); blob.append(le(0))
        blob += imports + pool
        var d = header(ncmds: 1, sizeofcmds: 16)
        d.append(le(0x8000_0034)); d.append(le(16)); d.append(le(UInt32(32 + 16))); d.append(le(UInt32(blob.count)))
        return d + blob
    }

    static func header(ncmds: UInt32, sizeofcmds: UInt32) -> Data {
        var d = Data()
        d.append(le(0xFEED_FACF)); d.append(le(0x0100_000C)); d.append(le(0)); d.append(le(6))
        d.append(le(ncmds)); d.append(le(sizeofcmds)); d.append(le(0)); d.append(le(0))
        return d
    }

    static func le(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    static let undefinedExternal: UInt8 = 0x01
    static let definedExternal: UInt8 = 0x0F   // N_SECT | N_EXT

    @Test func importedHooksAreFoundInTheSymbolTable() {
        let d = Self.symtabMachO([("_MSHookFunction", Self.undefinedExternal), ("_MSHookMessageEx", Self.undefinedExternal),
                                  ("_LHHookFunctions", Self.undefinedExternal), ("_objc_msgSend", Self.undefinedExternal)])
        #expect(MachOImports.cFunctionHooks(in: d) == ["LHHookFunctions", "MSHookFunction"])
        #expect(MachOImports.cFunctionHooks(in: Self.symtabMachO([("__MSHookFunction", Self.undefinedExternal),
                                                                  ("_substitute_hook_functions", Self.undefinedExternal)]))
                == ["_MSHookFunction", "substitute_hook_functions"])
    }

    /// The hooking library itself defines them; ObjC-only hooks import none; a longer name or a
    /// debugging entry isn't one.
    @Test func definedOrOtherSymbolsAreNotImports() {
        #expect(MachOImports.cFunctionHooks(in: Self.symtabMachO([("_MSHookFunction", Self.definedExternal)])).isEmpty)
        #expect(MachOImports.cFunctionHooks(in: Self.symtabMachO([("_MSHookMessageEx", Self.undefinedExternal)])).isEmpty)
        #expect(MachOImports.cFunctionHooks(in: Self.symtabMachO([("_MSHookFunctionX", Self.undefinedExternal)])).isEmpty)
        #expect(MachOImports.cFunctionHooks(in: Self.symtabMachO([("_MSHookFunction", 0x20)])).isEmpty)  // N_GSYM stab
        #expect(MachOImports.cFunctionHooks(in: Self.symtabMachO([("_MSHookFunction", 0x00)])).isEmpty)  // not external
    }

    @Test func chainedFixupImportsInEveryFormat() {
        for format: UInt32 in [1, 2, 3] {
            let d = Self.chainedMachO(["_objc_msgSend", "_MSHookFunction"], format: format)
            #expect(MachOImports.cFunctionHooks(in: d) == ["MSHookFunction"], "format \(format)")
        }
        #expect(MachOImports.cFunctionHooks(in: Self.chainedMachO(["_MSHookFunction"], format: 9)).isEmpty)
    }

    @Test func fatBinariesAreReadPerSlice() {
        let slice = Self.symtabMachO([("_LHHookFunctions", Self.undefinedExternal)])
        var fat = Data()
        func be(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
        fat.append(be(0xCAFE_BABE)); fat.append(be(1))
        fat.append(be(0x0100_000C)); fat.append(be(0)); fat.append(be(4096)); fat.append(be(UInt32(slice.count))); fat.append(be(12))
        fat.append(Data(count: 4096 - fat.count))
        fat.append(slice)
        #expect(MachOImports.cFunctionHooks(in: fat) == ["LHHookFunctions"])
    }

    @Test func hostileTablesNeverTrap() {
        let good = Self.symtabMachO([("_MSHookFunction", Self.undefinedExternal)])
        #expect(MachOImports.cFunctionHooks(in: Self.symtabMachO([("_MSHookFunction", 1)], nsymsOverride: .max)).isEmpty)
        #expect(MachOImports.cFunctionHooks(in: Self.symtabMachO([("_MSHookFunction", 1)], nsymsOverride: 1000)).isEmpty)
        #expect(MachOImports.cFunctionHooks(in: Self.symtabMachO([("_MSHookFunction", 1)], stroffOverride: .max)).isEmpty)
        #expect(MachOImports.cFunctionHooks(in: Self.chainedMachO(["_MSHookFunction"], format: 1, countOverride: .max)).isEmpty)
        #expect(MachOImports.cFunctionHooks(in: Self.chainedMachO(["_MSHookFunction"], format: 3, countOverride: 50)).isEmpty)
        // A name that runs off the table without its NUL.
        #expect(MachOImports.cFunctionHooks(in: good.dropLast()).isEmpty)
        // Every truncation of a good file, and garbage.
        for n in stride(from: 0, to: good.count, by: 7) { _ = MachOImports.cFunctionHooks(in: Data(good.prefix(n))) }
        #expect(MachOImports.cFunctionHooks(in: Data("not a mach-o".utf8)).isEmpty)
        #expect(MachOImports.cFunctionHooks(in: URL(fileURLWithPath: "/nonexistent/x.dylib")).isEmpty)
    }
}
