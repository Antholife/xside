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
    static let maxProtocolsPerList = 1024
    /// Segments a slice may declare (real executables have fewer than ten).
    static let maxSegments = 64
    /// Pointer reads allowed for one slice, whatever its shape: past it the scan gives no answer.
    /// A large real app (~100k classes) takes a few million.
    static let stepBudget = 20_000_000

    enum ScanError: Error, Equatable {
        /// The slice needed more reads than `stepBudget`: a hostile or broken binary.
        case tooComplex
    }

    /// The app's scene delegate: a class named "…SceneDelegate" that conforms to
    /// `UIWindowSceneDelegate`. Nil when there is none or the executable can't be read.
    ///
    /// Every 64-bit slice is scanned and the answer must hold in all of them: the device runs
    /// one slice (arm64 or arm64e), and the manifest names one class for whichever it is. A
    /// slice that can't be read gives no answer at all.
    public static func sceneDelegateClass(in executable: URL) -> String? {
        guard let slices = try? classesPerSlice(in: executable), let first = slices.first else { return nil }
        // Conforming candidates present (and conforming) in every slice.
        let common = slices.dropFirst().reduce(Set(conforming(first).map(\.name))) { names, slice in
            names.intersection(conforming(slice).map(\.name))
        }
        return choose(first.filter { common.contains($0.name) })
    }

    private static func conforming(_ classes: [ClassInfo]) -> [ClassInfo] {
        classes.filter { $0.conformsToWindowSceneDelegate && $0.name.hasSuffix("SceneDelegate") }
    }

    /// Among conforming "…SceneDelegate" classes: one declaring the conformance itself first,
    /// then the shortest name, then alphabetical (a stable answer).
    static func choose(_ classes: [ClassInfo]) -> String? {
        conforming(classes)
            .min { a, b in
                if a.declaresItself != b.declaresItself { return a.declaresItself }
                if a.name.count != b.name.count { return a.name.count < b.name.count }
                return a.name < b.name
            }?.name
    }

    /// Every class of one slice: `arch` ("arm64", "arm64e"), else arm64, else the first.
    static func classes(in executable: URL, arch: String? = nil) throws -> [ClassInfo] {
        let (data, slices) = try readSlices(executable)
        let chosen = arch.map { a in slices.first { $0.slice.archName == a } }
            ?? slices.first { $0.slice.archName == "arm64" } ?? slices.first
        guard let start = chosen?.start else { throw MachOPatcher.Failure.notMachO }
        return try Image(data: data, start: start).classes()
    }

    /// Every slice's classes, arm64 first (then the file's order).
    static func classesPerSlice(in executable: URL) throws -> [[ClassInfo]] {
        let (data, slices) = try readSlices(executable)
        let ordered = slices.filter { $0.slice.archName == "arm64" } + slices.filter { $0.slice.archName != "arm64" }
        return try ordered.map { try Image(data: data, start: $0.start).classes() }
    }

    private static func readSlices(_ executable: URL) throws -> (Data, [(start: Int, slice: MachOBuildInfo.Slice)]) {
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe),
              let starts = try? IPAInspector.sliceOffsets(data), !starts.isEmpty else { throw MachOPatcher.Failure.notMachO }
        // A fat header may list the same slice twice: scanned once.
        var seen = Set<Int>()
        let unique = starts.filter { seen.insert($0).inserted }
        return (data, unique.map { (start: $0, slice: MachOBuildInfo.Slice(
            cpuType: MachOPatcher.u32(data, $0 + 4), cpuSubtype: MachOPatcher.u32(data, $0 + 8),
            platform: nil, minOS: nil, sdk: nil)) })
    }

    /// One 64-bit slice, with what it takes to follow its pointers. Every value read from the
    /// file is untrusted: address arithmetic is checked (an overflow means no answer, never a
    /// trap), segments must lie inside the file, each protocol and class is resolved once
    /// (memoized), and the whole scan has a read budget.
    private final class Image {
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
        /// Pointer reads left; below zero the scan has given up.
        private var steps = ObjCClassScanner.stepBudget
        /// Protocol address -> it is, or inherits, `UIWindowSceneDelegate`. A protocol being
        /// resolved is in it as false: a cycle ends there.
        private var protocols: [UInt64: Bool] = [:]
        /// Protocol list address -> it lists a conforming protocol.
        private var lists: [UInt64: Bool] = [:]
        /// Class address -> it or an in-image superclass declares the conformance.
        private var conformingClasses: [UInt64: Bool] = [:]

        init(data: Data, start: Int) throws {
            self.data = data
            self.start = start
            for c in try MachOPatcher.loadCommands(data, at: start) {
                if c.cmd == MachOPatcher.segment64, c.size >= 72 {
                    let segment = Segment(vmaddr: u64(c.pos + 24), fileoff: u64(c.pos + 40), filesize: u64(c.pos + 48))
                    // Inside the file, or not followed at all.
                    let available = UInt64(data.count - start)
                    guard segment.fileoff <= available, segment.filesize <= available - segment.fileoff,
                          segment.vmaddr.addingReportingOverflow(segment.filesize).overflow == false,
                          segments.count < ObjCClassScanner.maxSegments else { continue }
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

        func classes() throws -> [ClassInfo] {
            guard let list = classList, list.offset > 0 else { return [] }
            let count = min(list.size / 8, ObjCClassScanner.maxClasses)
            var result: [ClassInfo] = []
            for i in 0..<count {
                guard steps >= 0 else { break }
                guard let cls = pointer(atFile: start + list.offset + i * 8),
                      let ro = classRO(cls), let name = string(at: field(ro, 24).flatMap(pointer(atVM:))) else { continue }
                let own = declares(ro)
                result.append(ClassInfo(name: name, conformsToWindowSceneDelegate: own || superclassConforms(cls),
                                        declaresItself: own))
            }
            guard steps >= 0 else { throw ScanError.tooComplex }
            return result
        }

        /// A superclass in this image (up to `maxDepth` levels) declares the conformance.
        private func superclassConforms(_ cls: UInt64) -> Bool {
            var chain: [UInt64] = []
            var current = cls
            var answer: Bool?
            while answer == nil, chain.count < ObjCClassScanner.maxDepth, steps >= 0 {
                guard let superclass = field(current, 8).flatMap(pointer(atVM:)) else { answer = false; break }
                if let known = conformingClasses[superclass] { answer = known; break }
                chain.append(superclass)
                if let superRO = classRO(superclass), declares(superRO) { answer = true }
                current = superclass
            }
            // Each class walked conforms exactly when the one that settled it does (none of them
            // declared it before). Cut short (depth, budget): nothing remembered.
            if let answer { for c in chain { conformingClasses[c] = answer } }
            return answer ?? false
        }

        /// The class's `class_ro_t` address (its `data` field, without the runtime's flag bits).
        private func classRO(_ cls: UInt64) -> UInt64? {
            field(cls, 32).flatMap(pointer(atVM:)).map { $0 & ~7 }
        }

        /// The `class_ro_t` at `ro` lists `UIWindowSceneDelegate`, or a protocol inheriting it.
        private func declares(_ ro: UInt64) -> Bool {
            guard let list = field(ro, 40).flatMap(pointer(atVM:)) else { return false }
            return listsWindowSceneDelegate(list, depth: 0)
        }

        private func listsWindowSceneDelegate(_ list: UInt64, depth: Int) -> Bool {
            if let known = lists[list] { return known }
            guard depth < ObjCClassScanner.maxDepth, steps >= 0, let offset = fileOffset(list) else { return false }
            lists[list] = false // being resolved: a list reached again through itself adds nothing
            let count = min(Int(clamping: u64(offset)), ObjCClassScanner.maxProtocolsPerList)
            var answer = false
            for i in 0..<count where steps >= 0 {
                guard let proto = pointer(atFile: offset + 8 + i * 8) else { continue }
                if protocolConforms(proto, depth: depth) { answer = true; break }
            }
            lists[list] = answer
            return answer
        }

        private func protocolConforms(_ proto: UInt64, depth: Int) -> Bool {
            if let known = protocols[proto] { return known }
            protocols[proto] = false // being resolved
            var answer = string(at: field(proto, 8).flatMap(pointer(atVM:))) == ObjCClassScanner.windowSceneDelegate
            if !answer, let inherited = field(proto, 16).flatMap(pointer(atVM:)) {
                answer = listsWindowSceneDelegate(inherited, depth: depth + 1)
            }
            protocols[proto] = answer
            return answer
        }

        // MARK: Pointers

        /// `address + offset`, nil when it wraps.
        private func field(_ address: UInt64, _ offset: UInt64) -> UInt64? {
            let (sum, overflow) = address.addingReportingOverflow(offset)
            return overflow ? nil : sum
        }

        private func fileOffset(_ vm: UInt64) -> Int? {
            // Segments are inside the file (checked at init): no sum below can wrap.
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
            steps -= 1
            guard steps >= 0, offset >= 0, offset <= data.count - 8 else { return nil }
            return resolve(u64(offset))
        }

        /// A raw pointer as stored in the file: with chained fixups, a rebase holds its target in
        /// its low bits (an address, or an offset from the base) and a bind is skipped.
        private func resolve(_ raw: UInt64) -> UInt64? {
            guard raw != 0 else { return nil }
            guard let format = pointerFormat else { return raw }
            let target: UInt64
            switch format {
            case 1, 12, 24: // DYLD_CHAINED_PTR_ARM64E(_USERLAND, _USERLAND24)
                if raw & (1 << 62) != 0 { return nil }                          // bind
                if raw & (1 << 63) != 0 { return field(base, raw & 0xFFFF_FFFF) } // authenticated rebase: offset
                target = raw & 0x7FF_FFFF_FFFF                                  // 43 bits
            case 2, 6: // DYLD_CHAINED_PTR_64(_OFFSET)
                if raw & (1 << 63) != 0 { return nil }                          // bind
                target = raw & 0xF_FFFF_FFFF                                    // 36 bits
            default:
                return nil
            }
            return target < base ? field(base, target) : target
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
            guard at >= 0, at < data.count else { return "" }
            return String(decoding: data[at..<min(at + 16, data.count)].prefix { $0 != 0 }, as: UTF8.self)
        }

        private func u32(_ at: Int) -> UInt32 { MachOPatcher.u32(data, at) }

        private func u64(_ at: Int) -> UInt64 {
            guard at >= 0, at <= data.count - 8 else { return 0 }
            return data[at..<at + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        }
    }
}
