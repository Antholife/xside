import Foundation

/// Finds an app's own scene delegate class in its main executable, without running it: the
/// Objective-C class list (`__objc_classlist`, Swift classes included) is read straight from the
/// Mach-O, each class's name and declared protocols from its `class_ro_t`. The iPhone Duo option
/// names that class in the scene manifest it adds (see `DuoCompatibility`). Read-only and
/// bounded: an untrusted binary gives at worst no answer.
public enum ObjCClassScanner {
    public struct ClassInfo: Equatable, Sendable {
        /// The runtime name (a Swift class without `@objc(name)` has its mangled one, which
        /// `NSClassFromString` accepts).
        public let name: String
        /// It, or a superclass in the same executable, declares `UIWindowSceneDelegate` (directly
        /// or through a protocol that inherits it).
        public let conformsToWindowSceneDelegate: Bool
        /// The class itself declares the conformance (not only a superclass).
        public let declaresItself: Bool

        public init(name: String, conformsToWindowSceneDelegate: Bool, declaresItself: Bool) {
            self.name = name
            self.conformsToWindowSceneDelegate = conformsToWindowSceneDelegate
            self.declaresItself = declaresItself
        }
    }

    static let windowSceneDelegate = "UIWindowSceneDelegate"
    static let maxClasses = 200_000
    static let maxDepth = 16

    /// The app's scene delegate: a class named "…SceneDelegate" that conforms to
    /// `UIWindowSceneDelegate`. Nil when there is none or the executable can't be read.
    public static func sceneDelegateClass(in executable: URL) -> String? {
        (try? classes(in: executable)).flatMap(choose)
    }

    /// Among conforming "…SceneDelegate" classes: one declaring the conformance itself first,
    /// then the shortest name, then alphabetical (a stable answer).
    static func choose(_ classes: [ClassInfo]) -> String? {
        classes.filter { $0.conformsToWindowSceneDelegate && $0.name.hasSuffix("SceneDelegate") }
            .min { a, b in
                if a.declaresItself != b.declaresItself { return a.declaresItself }
                if a.name.count != b.name.count { return a.name.count < b.name.count }
                return a.name < b.name
            }?.name
    }

    /// Every class of one slice: `arch` ("arm64", "arm64e"), else arm64, else the first.
    static func classes(in executable: URL, arch: String? = nil) throws -> [ClassInfo] {
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe),
              let starts = try? IPAInspector.sliceOffsets(data) else { throw MachOPatcher.Failure.notMachO }
        let slices = starts.map { (start: $0, slice: MachOBuildInfo.Slice(
            cpuType: MachOPatcher.u32(data, $0 + 4), cpuSubtype: MachOPatcher.u32(data, $0 + 8),
            platform: nil, minOS: nil, sdk: nil)) }
        let chosen = arch.map { a in slices.first { $0.slice.archName == a } }
            ?? slices.first { $0.slice.archName == "arm64" } ?? slices.first
        guard let start = chosen?.start else { throw MachOPatcher.Failure.notMachO }
        let image = try Image(data: data, start: start)
        return image.classes()
    }

    /// One 64-bit slice, with what it takes to follow its pointers.
    private struct Image {
        struct Segment { let vmaddr: UInt64; let fileoff: UInt64; let filesize: UInt64 }
        let data: Data
        let start: Int
        var segments: [Segment] = []
        var classList: (offset: Int, size: Int)?
        /// The image's base address (`__TEXT`), for pointers stored as offsets.
        var base: UInt64 = 0
        /// `dyld_chained_starts_in_segment.pointer_format`; nil without chained fixups (pointers
        /// are then plain addresses).
        var pointerFormat: UInt16?

        init(data: Data, start: Int) throws {
            self.data = data
            self.start = start
            for c in try MachOPatcher.loadCommands(data, at: start) {
                if c.cmd == MachOPatcher.segment64, c.size >= 72 {
                    let segment = Segment(vmaddr: u64(c.pos + 24), fileoff: u64(c.pos + 40), filesize: u64(c.pos + 48))
                    segments.append(segment)
                    if segment.fileoff == 0, segment.filesize > 0 { base = segment.vmaddr }
                    let nsects = Int(u32(c.pos + 64))
                    guard 72 + nsects * 80 <= c.size else { continue }
                    for i in 0..<nsects {
                        let s = c.pos + 72 + i * 80
                        if name16(s) == "__objc_classlist" {
                            classList = (Int(u32(s + 48)), Int(min(u64(s + 40), UInt64(Int32.max))))
                        }
                    }
                } else if c.cmd == 0x8000_0034, c.size >= 16 { // LC_DYLD_CHAINED_FIXUPS
                    pointerFormat = chainedPointerFormat(at: start + Int(u32(c.pos + 8)))
                }
            }
        }

        func classes() -> [ClassInfo] {
            guard let list = classList, list.offset > 0 else { return [] }
            let count = min(list.size / 8, maxClasses)
            var result: [ClassInfo] = []
            for i in 0..<count {
                guard let cls = pointer(atFile: start + list.offset + i * 8),
                      let ro = classRO(cls), let name = string(at: u64At(ro + 24)) else { continue }
                let own = declares(ro)
                var conforms = own
                var current = cls
                var depth = 0
                while !conforms, depth < maxDepth, let superclass = pointer(atVM: current + 8),
                      let superRO = classRO(superclass) {
                    conforms = declares(superRO)
                    current = superclass
                    depth += 1
                }
                result.append(ClassInfo(name: name, conformsToWindowSceneDelegate: conforms, declaresItself: own))
            }
            return result
        }

        /// The class's `class_ro_t` address (its `data` field, without the runtime's flag bits).
        private func classRO(_ cls: UInt64) -> UInt64? {
            pointer(atVM: cls + 32).map { $0 & ~7 }
        }

        /// The `class_ro_t` at `ro` lists `UIWindowSceneDelegate`, or a protocol inheriting it.
        private func declares(_ ro: UInt64) -> Bool {
            guard let list = pointer(atVM: ro + 40) else { return false }
            return listsWindowSceneDelegate(list, depth: 0)
        }

        private func listsWindowSceneDelegate(_ list: UInt64, depth: Int) -> Bool {
            guard depth < maxDepth, let offset = fileOffset(list) else { return false }
            let count = min(Int(clamping: u64(offset)), 1024)
            for i in 0..<count {
                guard let proto = pointer(atFile: offset + 8 + i * 8) else { continue }
                if string(at: u64At(proto + 8)) == windowSceneDelegate { return true }
                if let inherited = pointer(atVM: proto + 16), listsWindowSceneDelegate(inherited, depth: depth + 1) {
                    return true
                }
            }
            return false
        }

        // MARK: Pointers

        private func fileOffset(_ vm: UInt64) -> Int? {
            for s in segments where vm >= s.vmaddr && vm - s.vmaddr < s.filesize {
                let offset = UInt64(start) + s.fileoff + (vm - s.vmaddr)
                guard offset < UInt64(data.count) else { return nil }
                return Int(offset)
            }
            return nil
        }

        /// The address a pointer stored at `vm` points to; nil for a null pointer or one bound to
        /// another image (a superclass in UIKit).
        private func pointer(atVM vm: UInt64) -> UInt64? {
            fileOffset(vm).flatMap { pointer(atFile: $0) }
        }

        private func pointer(atFile offset: Int) -> UInt64? {
            guard offset >= 0, offset + 8 <= data.count else { return nil }
            return resolve(u64(offset))
        }

        private func u64At(_ vm: UInt64) -> UInt64? { pointer(atVM: vm) }

        /// A raw pointer as stored in the file: with chained fixups, a rebase holds its target in
        /// its low bits (an address, or an offset from the base) and a bind is skipped.
        private func resolve(_ raw: UInt64) -> UInt64? {
            guard raw != 0 else { return nil }
            guard let format = pointerFormat else { return raw }
            let target: UInt64
            switch format {
            case 1, 12, 24: // DYLD_CHAINED_PTR_ARM64E(_USERLAND, _USERLAND24)
                if raw & (1 << 62) != 0 { return nil }                          // bind
                if raw & (1 << 63) != 0 { return base + (raw & 0xFFFF_FFFF) }   // authenticated rebase: offset
                target = raw & 0x7FF_FFFF_FFFF                                  // 43 bits
            case 2, 6: // DYLD_CHAINED_PTR_64(_OFFSET)
                if raw & (1 << 63) != 0 { return nil }                          // bind
                target = raw & 0xF_FFFF_FFFF                                    // 36 bits
            default:
                return nil
            }
            return target < base ? base + target : target
        }

        /// The pointer format of the first segment that has fixups.
        private func chainedPointerFormat(at header: Int) -> UInt16? {
            guard header >= 0, header + 28 <= data.count else { return nil }
            let startsInImage = header + Int(u32(header + 4))
            guard startsInImage + 4 <= data.count else { return nil }
            let count = min(Int(u32(startsInImage)), 64)
            for i in 0..<count {
                let infoOffset = Int(u32(startsInImage + 4 + i * 4))
                guard infoOffset > 0 else { continue }
                let info = startsInImage + infoOffset
                guard info + 8 <= data.count else { return nil }
                return UInt16(truncatingIfNeeded: u32(info + 4) >> 16)
            }
            return nil
        }

        // MARK: Bytes

        private func string(at vm: UInt64?) -> String? {
            guard let vm, let offset = fileOffset(vm) else { return nil }
            let bytes = data[offset..<min(offset + 1024, data.count)].prefix { $0 != 0 }
            guard !bytes.isEmpty else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }

        private func name16(_ at: Int) -> String {
            String(decoding: data[at..<min(at + 16, data.count)].prefix { $0 != 0 }, as: UTF8.self)
        }

        private func u32(_ at: Int) -> UInt32 { MachOPatcher.u32(data, at) }

        private func u64(_ at: Int) -> UInt64 {
            guard at >= 0, at + 8 <= data.count else { return 0 }
            return data[at..<at + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        }
    }
}
