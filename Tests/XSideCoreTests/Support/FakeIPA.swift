import Foundation

/// Builds fake extracted IPAs for tests. Reusable by the Resigner tests.
enum FakeIPA {
    /// Minimal thin 64-bit little-endian Mach-O with one LC_ENCRYPTION_INFO_64 command.
    static func thinMachO(cryptid: UInt32) -> Data {
        var d = Data()
        func le(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        le(0xFEEDFACF); le(0x0100000C); le(0); le(2) // magic, cputype arm64, subtype, filetype
        le(1); le(24); le(0); le(0)                   // ncmds, sizeofcmds, flags, reserved
        le(0x2C); le(24); le(0); le(0x1000); le(cryptid); le(0) // LC_ENCRYPTION_INFO_64
        return d
    }

    /// Thin arm64 Mach-O with a `__TEXT` segment whose one section starts `padding` bytes after
    /// the load commands (the room a new command can take), and optionally a last
    /// `LC_CODE_SIGNATURE`, like a signed app.
    static func paddedMachO(padding: Int, codeSignatureLast: Bool = false) -> Data {
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func name(_ s: String) { var b = Array(s.utf8); b += Array(repeating: 0, count: 16 - b.count); d.append(contentsOf: b) }
        let segmentSize = 72 + 80
        let sizeofcmds = segmentSize + (codeSignatureLast ? 16 : 0)
        let sectionOffset = 32 + sizeofcmds + padding
        let fileSize = sectionOffset + 16
        le32(0xFEEDFACF); le32(0x0100000C); le32(0); le32(2)
        le32(codeSignatureLast ? 2 : 1); le32(UInt32(sizeofcmds)); le32(0); le32(0)
        le32(0x19); le32(UInt32(segmentSize)); name("__TEXT")             // LC_SEGMENT_64
        le64(0x100000000); le64(UInt64(fileSize)); le64(0); le64(UInt64(fileSize))
        le32(5); le32(5); le32(1); le32(0)                                 // prot, nsects 1, flags
        name("__text"); name("__TEXT"); le64(0x100000000 + UInt64(sectionOffset)); le64(16)
        le32(UInt32(sectionOffset)); le32(2); le32(0); le32(0); le32(0); le32(0); le32(0); le32(0)
        if codeSignatureLast { le32(0x1D); le32(16); le32(UInt32(fileSize)); le32(0) }
        d.append(Data(count: sectionOffset - d.count))
        d.append(Data(repeating: 0xAB, count: 16))                         // the "code"
        return d
    }

    /// Big-endian fat binary (0xCAFEBABE) wrapping the given slices.
    static func fatMachO(slices: [Data]) -> Data {
        var d = Data()
        func be(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        be(0xCAFEBABE); be(UInt32(slices.count))
        var offset = 8 + 20 * slices.count
        offset = (offset + 15) & ~15
        var placed: [(Int, Data)] = []
        for s in slices {
            be(0x0100000C); be(0); be(UInt32(offset)); be(UInt32(s.count)); be(4)
            placed.append((offset, s))
            offset = (offset + s.count + 15) & ~15
        }
        for (off, s) in placed {
            d.append(Data(count: off - d.count))
            d.append(s)
        }
        return d
    }

    /// Writes `<at>/Payload/<Name>.app`; returns the .app URL.
    @discardableResult
    static func makeApp(
        at root: URL,
        name: String = "Demo",
        bundleID: String = "com.example.demo",
        executable: String = "Demo",
        extensions: [String] = ["PlugIns", "Watch"],
        encrypted: Bool = false,
        executableData: Data? = nil,
        plistExtras: [String: Any] = ["CFBundleName": "Demo"]
    ) throws -> URL {
        let fm = FileManager.default
        let app = root.appendingPathComponent("Payload/\(name).app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": executable]
        plist.merge(plistExtras) { _, new in new }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try (executableData ?? thinMachO(cryptid: encrypted ? 1 : 0))
            .write(to: app.appendingPathComponent(executable))
        let fw = app.appendingPathComponent("Frameworks/X.framework")
        try fm.createDirectory(at: fw, withIntermediateDirectories: true)
        try thinMachO(cryptid: 0).write(to: fw.appendingPathComponent("X"))
        for ext in extensions {
            let bundle = app.appendingPathComponent("\(ext)/Placeholder.\(ext == "Watch" ? "app" : "appex")")
            try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": "\(bundleID).\(ext.lowercased())"],
                format: .binary, options: 0
            ).write(to: bundle.appendingPathComponent("Info.plist"))
        }
        return app
    }
}

extension FakeIPA {
    /// Thin 64-bit Mach-O of the given CPU type (12 | 0x01000000 = arm64) with an encryption command.
    static func machO(cpuType: UInt32, cryptid: UInt32) -> Data {
        var d = thinMachO(cryptid: cryptid)
        withUnsafeBytes(of: cpuType.littleEndian) { d.replaceSubrange(4..<8, with: $0) }
        return d
    }

    /// Fat (32-bit header) file with 2^14 alignment from (cpuType, cpuSubtype, slice) triples.
    static func fat(_ slices: [(cpu: UInt32, sub: UInt32, data: Data)]) -> Data {
        var d = Data()
        func be(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        be(0xCAFEBABE); be(UInt32(slices.count))
        var offset = 0x4000
        var offsets: [Int] = []
        for s in slices {
            offsets.append(offset)
            be(s.cpu); be(s.sub); be(UInt32(offset)); be(UInt32(s.data.count)); be(14)
            offset += (s.data.count + 0x3FFF) / 0x4000 * 0x4000
        }
        for (s, o) in zip(slices, offsets) {
            d.append(Data(count: o - d.count))
            d.append(s.data)
        }
        return d
    }
}

extension FakeIPA {
    /// Thin arm64 `MH_DYLIB` with a `__TEXT` segment, one `dylib_command` per `linking` name
    /// (even indexes `LC_LOAD_DYLIB`, odd ones `LC_LOAD_WEAK_DYLIB`; timestamp 2, current
    /// version 5.0.0, compatibility 1.0.0) and a last `LC_CODE_SIGNATURE`. The one section
    /// starts `padding` bytes after the load commands and holds 16 bytes of 0xAB, then each of
    /// `strings`, NUL-terminated.
    static func dylibMachO(linking: [String], padding: Int, cpuSubtype: UInt32 = 0, strings: [String] = []) -> Data {
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func name(_ s: String) { var b = Array(s.utf8); b += Array(repeating: 0, count: 16 - b.count); d.append(contentsOf: b) }
        let dylibSizes = linking.map { (24 + $0.utf8.count + 1 + 7) & ~7 }
        let segmentSize = 72 + 80
        let sizeofcmds = segmentSize + dylibSizes.reduce(0, +) + 16
        let sectionOffset = 32 + sizeofcmds + padding
        var content = Data(repeating: 0xAB, count: 16)
        for s in strings { content.append(contentsOf: Array(s.utf8) + [0]) }
        let fileSize = sectionOffset + content.count
        le32(0xFEEDFACF); le32(0x0100000C); le32(cpuSubtype); le32(6)      // MH_DYLIB
        le32(UInt32(linking.count + 2)); le32(UInt32(sizeofcmds)); le32(0); le32(0)
        le32(0x19); le32(UInt32(segmentSize)); name("__TEXT")
        le64(0); le64(UInt64(fileSize)); le64(0); le64(UInt64(fileSize))
        le32(5); le32(5); le32(1); le32(0)
        name("__text"); name("__TEXT"); le64(UInt64(sectionOffset)); le64(UInt64(content.count))
        le32(UInt32(sectionOffset)); le32(2); le32(0); le32(0); le32(0); le32(0); le32(0); le32(0)
        for (i, (path, size)) in zip(linking, dylibSizes).enumerated() {
            le32(i % 2 == 0 ? 0xC : 0x8000_0018); le32(UInt32(size)); le32(24)
            le32(2); le32(0x0005_0000); le32(0x0001_0000)
            var bytes = Array(path.utf8) + [0]
            bytes += Array(repeating: 0, count: size - 24 - bytes.count)
            d.append(contentsOf: bytes)
        }
        le32(0x1D); le32(16); le32(UInt32(fileSize)); le32(0)
        d.append(Data(count: sectionOffset - d.count))
        d.append(content)
        return d
    }
}
