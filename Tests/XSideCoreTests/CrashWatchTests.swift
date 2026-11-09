import Testing
import Foundation
@testable import XSideCore

@Suite struct CrashWatchTests {
    private let record = UUID()
    private let device = "DEV"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func diagnosis(_ cause: CrashCause = .other, at date: Date?, duo: Bool = false) -> CrashDiagnosis {
        CrashDiagnosis(cause: cause, duoCompatibilityOn: duo, date: date)
    }

    @discardableResult
    private func raise(_ w: inout CrashWatch, _ file: String, crashAt: Date, installedAt: Date? = nil, now: Date? = nil) -> Bool {
        w.raise(recordID: record, deviceID: device, fileName: file, diagnosis: diagnosis(at: crashAt),
                installedAt: installedAt ?? t0, now: now ?? crashAt.addingTimeInterval(30))
    }

    @Test func aCrashAfterTheInstallIsFlaggedOnce() {
        var w = CrashWatch()
        let r1 = raise(&w, "Demo-1.ips", crashAt: t0.addingTimeInterval(60))
        #expect(r1)
        #expect(w.flag(recordID: record, deviceID: device)?.fileName == "Demo-1.ips")
        // The same file again (the check after the install, then the quiet look): no second notification.
        let r2 = raise(&w, "Demo-1.ips", crashAt: t0.addingTimeInterval(60))
        #expect(!r2)
        #expect(w.isSeen(fileName: "Demo-1.ips", deviceID: device))
        // A newer crash replaces it and is announced.
        let r3 = raise(&w, "Demo-2.ips", crashAt: t0.addingTimeInterval(600))
        #expect(r3)
        #expect(w.flag(recordID: record, deviceID: device)?.fileName == "Demo-2.ips")
        // An older one found later replaces nothing.
        let r4 = raise(&w, "Demo-0.ips", crashAt: t0.addingTimeInterval(30))
        #expect(!r4)
        #expect(w.flag(recordID: record, deviceID: device)?.fileName == "Demo-2.ips")
    }

    @Test func aCrashBeforeTheInstallIsNotFlagged() {
        var w = CrashWatch()
        let r5 = raise(&w, "Old.ips", crashAt: t0.addingTimeInterval(-3600))
        #expect(!r5)
        #expect(w.flags.isEmpty)
        // Within the slack it is the install's.
        let r6 = raise(&w, "Near.ips", crashAt: t0.addingTimeInterval(-60))
        #expect(r6)
    }

    @Test func dismissingKeepsThatCrashQuiet() {
        var w = CrashWatch()
        raise(&w, "Demo-1.ips", crashAt: t0.addingTimeInterval(60))
        w.dismiss(recordID: record, deviceID: device)
        #expect(w.flag(recordID: record, deviceID: device) == nil)
        let r7 = raise(&w, "Demo-1.ips", crashAt: t0.addingTimeInterval(60))
        #expect(!r7)
        // A new crash after that still shows.
        let r8 = raise(&w, "Demo-2.ips", crashAt: t0.addingTimeInterval(900))
        #expect(r8)
    }

    @Test func aLaunchSeenAfterTheCrashClearsIt() {
        var w = CrashWatch()
        raise(&w, "Demo-1.ips", crashAt: t0.addingTimeInterval(60))
        // A check-in from before the crash changes nothing.
        let r9 = w.launchSeen(recordID: record, deviceID: device, at: t0.addingTimeInterval(30))
        #expect(!r9)
        #expect(w.flag(recordID: record, deviceID: device) != nil)
        let r10 = w.launchSeen(recordID: record, deviceID: device, at: t0.addingTimeInterval(120))
        #expect(r10)
        #expect(w.flag(recordID: record, deviceID: device) == nil)
        // A crash older than that launch, found later, isn't flagged: the app has run since.
        let r11 = raise(&w, "Demo-0.ips", crashAt: t0.addingTimeInterval(90))
        #expect(!r11)
        let r12 = raise(&w, "Demo-3.ips", crashAt: t0.addingTimeInterval(500))
        #expect(r12)
    }

    @Test func anInstallThenNoNewCrashClearsIt() {
        var w = CrashWatch()
        raise(&w, "Demo-1.ips", crashAt: t0.addingTimeInterval(60))
        // A check with no install since keeps it.
        let r13 = w.noNewCrash(recordID: record, deviceID: device, checkedAt: t0.addingTimeInterval(200))
        #expect(!r13)
        let reinstall = t0.addingTimeInterval(1000)
        w.installed(recordID: record, deviceID: device, at: reinstall)
        #expect(w.flag(recordID: record, deviceID: device)?.supersededAt == reinstall)
        // Still shown until the next check.
        #expect(w.flag(recordID: record, deviceID: device) != nil)
        let r14 = w.noNewCrash(recordID: record, deviceID: device, checkedAt: reinstall.addingTimeInterval(60))
        #expect(r14)
        #expect(w.flag(recordID: record, deviceID: device) == nil)
    }

    @Test func aNewCrashAfterTheReinstallKeepsTheFlag() {
        var w = CrashWatch()
        raise(&w, "Demo-1.ips", crashAt: t0.addingTimeInterval(60))
        let reinstall = t0.addingTimeInterval(1000)
        w.installed(recordID: record, deviceID: device, at: reinstall)
        let r15 = raise(&w, "Demo-2.ips", crashAt: reinstall.addingTimeInterval(20), installedAt: reinstall)
        #expect(r15)
        let flag = w.flag(recordID: record, deviceID: device)
        #expect(flag?.fileName == "Demo-2.ips" && flag?.supersededAt == nil)
        let r16 = w.noNewCrash(recordID: record, deviceID: device, checkedAt: reinstall.addingTimeInterval(60))
        #expect(!r16)
    }

    @Test func scansAreThrottledPerDevice() {
        var w = CrashWatch()
        #expect(w.shouldScan(deviceID: device, now: t0))
        let first = w.scanStarted(deviceID: device, now: t0)
        #expect(first == t0.addingTimeInterval(-CrashWatch.firstLookback))
        #expect(!w.shouldScan(deviceID: device, now: t0.addingTimeInterval(1800)))
        #expect(w.shouldScan(deviceID: "OTHER", now: t0.addingTimeInterval(1800)))
        #expect(w.shouldScan(deviceID: device, now: t0.addingTimeInterval(CrashWatch.scanInterval)))
        // The next look starts where the last one did.
        let r17 = w.scanStarted(deviceID: device, now: t0.addingTimeInterval(4000))
        #expect(r17 == t0)
        // A clock set back doesn't block the looks.
        #expect(w.shouldScan(deviceID: device, now: t0.addingTimeInterval(-10_000)))
    }

    @Test func forgettingAndPruning() {
        var w = CrashWatch()
        raise(&w, "Demo-1.ips", crashAt: t0.addingTimeInterval(60))
        _ = w.scanStarted(deviceID: device, now: t0)
        w.prune(keeping: [CrashWatch.key(recordID: record, deviceID: device)], now: t0.addingTimeInterval(CrashWatch.seenKeep + 100))
        #expect(w.flag(recordID: record, deviceID: device) != nil)
        #expect(!w.isSeen(fileName: "Demo-1.ips", deviceID: device))
        w.prune(keeping: [], now: t0)
        #expect(w.flags.isEmpty)
        raise(&w, "Demo-2.ips", crashAt: t0.addingTimeInterval(60))
        w.forgetDevice(device)
        #expect(w.flags.isEmpty && !w.isSeen(fileName: "Demo-2.ips", deviceID: device))
        #expect(w.shouldScan(deviceID: device, now: t0.addingTimeInterval(1)))
    }

    @Test func survivesASaveAndOldFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crash-watch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CrashWatchStore(libraryRoot: folder)
        #expect(store.load() == CrashWatch()) // none yet
        var w = CrashWatch()
        raise(&w, "Demo-1.ips", crashAt: t0.addingTimeInterval(60))
        _ = w.scanStarted(deviceID: device, now: t0)
        try store.save(w)
        #expect(store.load() == w)
        try Data("not json".utf8).write(to: store.url)
        #expect(store.load() == CrashWatch())
    }

    @Test func suggestedActions() {
        #expect(CrashAction.suggested(for: diagnosis(.xsideModule, at: nil)) == .reinstallWithoutXSide)
        #expect(CrashAction.suggested(for: diagnosis(.noSceneSupport, at: nil, duo: true)) == .turnOffDuo)
        #expect(CrashAction.suggested(for: diagnosis(.noSceneSupport, at: nil)) == nil)
        #expect(CrashAction.suggested(for: diagnosis(.codeSignature, at: nil)) == .refresh)
        #expect(CrashAction.suggested(for: diagnosis(.iCloud, at: nil)) == nil)
        #expect(CrashAction.suggested(for: diagnosis(.tweak, at: nil)) == nil)
    }
}

@Suite struct CrashNewFilesTests {
    private let since = ISO8601DateFormatter().date(from: "2026-11-09T08:00:00Z")!

    private func entry(_ path: String, _ modified: String?, size: Int? = 30_000) -> CrashLogEntry {
        CrashLogEntry(relativePath: path, size: size, modified: modified.flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    @Test func picksOnlyNewUnreadLogsOfXSideApps() {
        let entries = [
            entry("Demo-2026-11-09-090000.ips", "2026-11-09T09:00:00Z"),
            entry("Retired/Demo-2026-11-09-091000.ips", "2026-11-09T09:10:00Z"),
            entry("Other App-2026-11-09-092000.ips", "2026-11-09T09:20:00Z"), // spaces kept by ReportCrash
            entry("Stranger-2026-11-09-093000.ips", "2026-11-09T09:30:00Z"), // not an XSide app
            entry("JetsamEvent-2026-11-09-094000.ips", "2026-11-09T09:40:00Z"),
            entry("Demo-2026-11-08-090000.ips", "2026-11-08T09:00:00Z"), // before the last look
            entry("Demo-2026-11-09-095000.ips", "2026-11-09T09:50:00Z"), // already read
            entry("Demo-2026-11-09-095500.ips", nil), // undated
            entry("Demo-2026-11-09-095600.ips", "2026-11-09T09:56:00Z", size: nil), // no size
            entry("Demo-2026-11-09-095700.ips", "2026-11-09T09:57:00Z", size: 50_000_000), // too big
            entry("ProxiedDevice-Watch/Demo-2026-11-09-095800.ips", "2026-11-09T09:58:00Z"),
        ]
        let picked = CrashLogListing.newCrashFiles(entries, executables: ["Demo", "Other App"], since: since,
                                                   seen: ["Demo-2026-11-09-095000.ips"])
        #expect(picked.map(\.relativePath) == ["Other App-2026-11-09-092000.ips", "Retired/Demo-2026-11-09-091000.ips",
                                               "Demo-2026-11-09-090000.ips"])
        // At most a few per look: the newest.
        let few = CrashLogListing.newCrashFiles(entries, executables: ["Demo", "Other App"], since: since, seen: [], limit: 2)
        #expect(few.count == 2)
        #expect(CrashLogListing.newCrashFiles(entries, executables: [], since: since, seen: []).isEmpty)
    }
}
