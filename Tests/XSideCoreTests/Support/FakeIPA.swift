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
