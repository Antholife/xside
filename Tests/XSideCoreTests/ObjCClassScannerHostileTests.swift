import Foundation
import Testing
@testable import XSideCore

/// The class scan runs in XSide's own process at every import: a hostile or broken executable
/// must give no answer, never a crash (overflow trap) nor a scan that doesn't end. The binaries
/// are built here, small and on purpose malformed (duo review, critical 1 and important 1).
@Suite struct ObjCClassScannerHostileTests {
    private static func put64(_ d: inout Data, _ at: Int, _ v: UInt64) {
        withUnsafeBytes(of: v.littleEndian) { d.replaceSubrange(at..<at + 8, with: $0) }
    }

    private static func put32(_ d: inout Data, _ at: Int, _ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { d.replaceSubrange(at..<at + 4, with: $0) }
    }

    /// One arm64 slice: one LC_SEGMENT_64 (`vmaddr` mapped to `fileoff`) with a
    /// `__objc_classlist` section at file offset 256.
    static func image(size: Int, vmaddr: UInt64 = 0, fileoff: UInt64 = 0, filesize: UInt64? = nil,
                      classListSize: UInt64 = 8) -> Data {
        var d = Data(count: size)
        put32(&d, 0, 0xFEED_FACF); put32(&d, 4, 0x0100_000C); put32(&d, 12, 2); put32(&d, 16, 1); put32(&d, 20, 152)
        put32(&d, 32, 0x19); put32(&d, 36, 152)
        d.replaceSubrange(40..<46, with: Array("__DATA".utf8))
        put64(&d, 56, vmaddr); put64(&d, 64, filesize ?? UInt64(size))
        put64(&d, 72, fileoff); put64(&d, 80, filesize ?? UInt64(size)); put32(&d, 96, 1)
        let s = 32 + 72
        d.replaceSubrange(s..<s + 16, with: Array("__objc_classlist".utf8))
        put64(&d, s + 40, classListSize); put32(&d, s + 48, 256)
        return d
    }

    private static func write(_ d: Data) throws -> URL {
        let url = TestTemp.root.appendingPathComponent("xside-hostile-\(UUID().uuidString)")
        try d.write(to: url)
        return url
    }

    /// Runs the scan on another thread and gives up waiting after `seconds`: a scan that doesn't
    /// end fails the test instead of hanging the suite.
    static func scanFinishes(_ url: URL, within seconds: Double = 10) -> (finished: Bool, elapsed: Double) {
        let done = DispatchSemaphore(value: 0)
        let start = Date()
        Thread.detachNewThread {
            _ = ObjCClassScanner.sceneDelegateClass(in: url)
            done.signal()
        }
        let finished = done.wait(timeout: .now() + seconds) == .success
        return (finished, Date().timeIntervalSince(start))
    }

    @Test func aClassPointerNearTheTopOfMemoryGivesNoAnswer() throws {
        var d = Self.image(size: 264)
        Self.put64(&d, 256, 0xFFFF_FFFF_FFFF_FFF8)
        let url = try Self.write(d)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ObjCClassScanner.sceneDelegateClass(in: url) == nil)
    }

    @Test func aSegmentWithAHugeFileOffsetIsIgnored() throws {
        var d = Self.image(size: 264, vmaddr: 0x1000, fileoff: 0xFFFF_FFFF_FFFF_FFF8, filesize: 0x2000)
        Self.put64(&d, 256, 0x1010)
        let url = try Self.write(d)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ObjCClassScanner.sceneDelegateClass(in: url) == nil)
    }

    @Test func aSegmentHighInMemoryCantOverflowItsPointers() throws {
        // vmaddr at the top: every "address + field offset" would wrap.
        var d = Self.image(size: 512, vmaddr: 0xFFFF_FFFF_FFFF_FE00, fileoff: 0, filesize: 512)
        Self.put64(&d, 256, 0xFFFF_FFFF_FFFF_FFF0)
        let url = try Self.write(d)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ObjCClassScanner.sceneDelegateClass(in: url) == nil)
    }

    @Test func aProtocolGraphThatFansOutEndsFast() throws {
        var d = Self.image(size: 9000)
        Self.put64(&d, 256, 512)                 // classlist -> class
        Self.put64(&d, 512 + 32, 600)            // class.data -> ro
        Self.put64(&d, 600 + 24, 700)            // ro.name
        Self.put64(&d, 600 + 40, 800)            // ro.baseProtocols
        d.replaceSubrange(700..<714, with: Array("XSceneDelegate".utf8))
        d.replaceSubrange(740..<741, with: Array("p".utf8))
        Self.put64(&d, 760 + 8, 740)             // protocol name
        Self.put64(&d, 760 + 16, 800)            // the protocol inherits the same list
        Self.put64(&d, 800, 1024)
        for i in 0..<1024 { Self.put64(&d, 808 + i * 8, 760) }
        let url = try Self.write(d)
        defer { try? FileManager.default.removeItem(at: url) }
        let run = Self.scanFinishes(url)
        #expect(run.finished)
        #expect(run.elapsed < 9)
    }

    @Test func manyDistinctProtocolsSharingListsEndFast() throws {
        // 64 lists of 64 protocols, each protocol inheriting every list in turn: no cycle through
        // one address, still a graph whose plain walk explodes.
        let lists = 64, perList = 64
        let protoBase = 1024, listBase = protoBase + lists * perList * 24
        var d = Self.image(size: listBase + lists * (8 + perList * 8) + 64)
        Self.put64(&d, 256, 512)
        Self.put64(&d, 512 + 32, 600)
        Self.put64(&d, 600 + 24, 700)
        Self.put64(&d, 600 + 40, UInt64(listBase))
        d.replaceSubrange(700..<714, with: Array("XSceneDelegate".utf8))
        d.replaceSubrange(740..<741, with: Array("p".utf8))
        for l in 0..<lists {
            let list = listBase + l * (8 + perList * 8)
            Self.put64(&d, list, UInt64(perList))
            for i in 0..<perList {
                let proto = protoBase + (l * perList + i) * 24
                Self.put64(&d, proto + 8, 740)
                Self.put64(&d, proto + 16, UInt64(listBase + ((l + 1) % lists) * (8 + perList * 8)))
                Self.put64(&d, list + 8 + i * 8, UInt64(proto))
            }
        }
        let url = try Self.write(d)
        defer { try? FileManager.default.removeItem(at: url) }
        let run = Self.scanFinishes(url)
        #expect(run.finished)
        #expect(run.elapsed < 9)
    }

    /// Cut and bit-flipped copies of the real fixtures: never a trap, always quick.
    @Test func damagedFixturesNeverTrapAndEndFast() throws {
        let fixtures = ["duo-objc-fat", "duo-swift-arm64"].map {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/macho/\($0)")
        }
        var generator = SplitMix64(seed: 0x5EED_D0D0)
        let start = Date()
        var scanned = 0
        for fixture in fixtures {
            let original = try Data(contentsOf: fixture)
            var variants: [Data] = []
            for cut in [16, 31, 32, 100, 1000, 4096, original.count / 2, original.count - 1] where cut < original.count {
                variants.append(original.prefix(cut))
            }
            for _ in 0..<60 {
                var d = original
                // A few bytes flipped anywhere past the load commands (the header then still
                // parses and the damaged pointers, names and lists get followed), sometimes in them.
                let flips = generator.next() % 4 == 0 ? 2 : 24
                for n in 0..<flips {
                    let low = n == 0 && flips == 2 ? 0 : 4096
                    let at = low + Int(generator.next() % UInt64(d.count - low))
                    d[at] ^= UInt8(truncatingIfNeeded: generator.next() | 1)
                }
                variants.append(d)
            }
            for variant in variants {
                let url = try Self.write(variant)
                defer { try? FileManager.default.removeItem(at: url) }
                let run = Self.scanFinishes(url)
                #expect(run.finished)
                if run.finished, (try? ObjCClassScanner.classesPerSlice(in: url)) != nil { scanned += 1 }
            }
        }
        // Most copies still parse: their damaged metadata really was walked.
        #expect(scanned > 60)
        #expect(Date().timeIntervalSince(start) < 60)
    }
}

/// Small deterministic generator (the damaged copies are the same at every run).
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
