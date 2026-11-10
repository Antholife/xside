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

    /// Device round 2: the crash a fix answered (« Désactiver ce tweak ») came back 52 s later as
    /// a « new » crash « after a crash fix », read again by the look that checks the fix (its
    /// window reaches back a minute, the install's two). It never comes back; a newer one does.
    @Test func theCrashAFixAnsweredIsNotRaisedAgain() {
        var w = CrashWatch()
        let crash = t0.addingTimeInterval(60)
        #expect(raise(&w, "Tweak-1.ips", crashAt: crash))
        w.fixStarted(recordID: record, deviceID: device)
        let reinstalled = crash.addingTimeInterval(63)
        w.installed(recordID: record, deviceID: device, at: reinstalled)
        w.launchSeen(recordID: record, deviceID: device, at: reinstalled) // XSide opened it: the flag went
        let again = w.raise(recordID: record, deviceID: device, fileName: "Tweak-1.ips", diagnosis: diagnosis(at: crash),
                            installedAt: reinstalled, now: reinstalled.addingTimeInterval(5),
                            inUseSince: crash.addingTimeInterval(52))
        #expect(!again)
        let newer = w.raise(recordID: record, deviceID: device, fileName: "Tweak-2.ips",
                            diagnosis: diagnosis(at: reinstalled.addingTimeInterval(3)), installedAt: reinstalled,
                            now: reinstalled.addingTimeInterval(8), inUseSince: crash.addingTimeInterval(52))
        #expect(newer)
        // Kept across a save.
        let data = try! JSONEncoder().encode(w)
        var back = try! JSONDecoder().decode(CrashWatch.self, from: data)
        back.dismiss(recordID: record, deviceID: device) // the newer flag gone: only `answered` stops it
        let reread = back.raise(recordID: record, deviceID: device, fileName: "Tweak-1.ips", diagnosis: diagnosis(at: crash),
                                installedAt: reinstalled, now: reinstalled.addingTimeInterval(9))
        #expect(!reread)
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

    /// Mega review K2: a crash announced, then cleared by the next launch's check-in, read again
    /// by the look that launch's "previous run crashed" asks for: the notice comes back (now in
    /// use) without a second notification.
    @Test func aCrashAnnouncedOnceIsNeverAnnouncedTwice() {
        var w = CrashWatch()
        let crash = t0.addingTimeInterval(60)
        let first = raise(&w, "Demo-1.ips", crashAt: crash)
        #expect(first)
        let cleared = w.launchSeen(recordID: record, deviceID: device, at: crash.addingTimeInterval(90))
        #expect(cleared)
        #expect(w.flag(recordID: record, deviceID: device) == nil)
        let again = w.raise(recordID: record, deviceID: device, fileName: "Demo-1.ips", diagnosis: diagnosis(at: crash),
                            installedAt: t0, now: crash.addingTimeInterval(95), inUseSince: crash.addingTimeInterval(-30))
        #expect(!again)
        #expect(w.flag(recordID: record, deviceID: device)?.duringUse == true)
        // Another file is still news.
        let other = w.raise(recordID: record, deviceID: device, fileName: "Demo-2.ips", diagnosis: diagnosis(at: crash.addingTimeInterval(200)),
                            installedAt: t0, now: crash.addingTimeInterval(230), inUseSince: crash.addingTimeInterval(150))
        #expect(other)
        // Remembered with the read files: forgotten with its installation and after `seenKeep`.
        w.prune(keeping: [CrashWatch.key(recordID: record, deviceID: device)], now: crash.addingTimeInterval(CrashWatch.seenKeep + 300))
        w.forget(recordID: record, deviceID: device)
        let afresh = raise(&w, "Demo-1.ips", crashAt: crash)
        #expect(afresh)
    }

    /// Mega review K6: the crash the fix answers is the diagnosed one, flagged or not; the look
    /// that checks the fix passes over it (and dismissed ones) to a newer crash.
    @Test func theDiagnosedCrashIsAnsweredFlaggedOrNot() {
        var w = CrashWatch()
        w.fixStarted(recordID: record, deviceID: device, fileName: "Demo-9.ips")
        #expect(w.isSettled(recordID: record, deviceID: device, fileName: "Demo-9.ips"))
        let answered = raise(&w, "Demo-9.ips", crashAt: t0.addingTimeInterval(60))
        #expect(!answered)
        #expect(!w.isSettled(recordID: record, deviceID: device, fileName: "Demo-10.ips"))
        let newer = raise(&w, "Demo-10.ips", crashAt: t0.addingTimeInterval(120))
        #expect(newer)
        w.dismiss(recordID: record, deviceID: device)
        #expect(w.isSettled(recordID: record, deviceID: device, fileName: "Demo-10.ips"))
    }

    /// Mega review K3: what the notice says of when it stopped: in use, at launch (the check after
    /// XSide opened it, or the log says so), or just « stopped » (the quiet look, any time).
    @Test func aFlagSaysWhenTheAppStopped() {
        var w = CrashWatch()
        raise(&w, "Demo-1.ips", crashAt: t0.addingTimeInterval(60))
        #expect(w.flag(recordID: record, deviceID: device)?.moment == .stopped)
        w.raise(recordID: record, deviceID: device, fileName: "Demo-2.ips", diagnosis: diagnosis(at: t0.addingTimeInterval(120)),
                installedAt: t0, now: t0.addingTimeInterval(150), atLaunch: true)
        #expect(w.flag(recordID: record, deviceID: device)?.moment == .atLaunch)
        w.raise(recordID: record, deviceID: device, fileName: "Demo-3.ips", diagnosis: diagnosis(.noSceneSupport, at: t0.addingTimeInterval(180)),
                installedAt: t0, now: t0.addingTimeInterval(210))
        #expect(w.flag(recordID: record, deviceID: device)?.moment == .atLaunch)
        w.raise(recordID: record, deviceID: device, fileName: "Demo-4.ips", diagnosis: diagnosis(at: t0.addingTimeInterval(240)),
                installedAt: t0, now: t0.addingTimeInterval(270), inUseSince: t0.addingTimeInterval(200))
        #expect(w.flag(recordID: record, deviceID: device)?.moment == .inUse)
        // Older files have no `atLaunch`: read as before.
        #expect(CrashFlag(fileName: "x", diagnosis: diagnosis(at: nil), raisedAt: t0).moment == .stopped)
    }

    /// Re-review N2: the fast look in use raises a crash of that run; the one that checks a crash
    /// fix raises the relaunch's crash as one « au lancement », not just « stopped ».
    @Test func theLookAfterACrashFixSaysAtLaunch() {
        let since = t0.addingTimeInterval(100)
        let inUse = CrashWatch.fastLookRaise(since: since, duringUse: true)
        #expect(inUse.inUseSince == since && !inUse.atLaunch)
        let afterFix = CrashWatch.fastLookRaise(since: since, duringUse: false)
        #expect(afterFix.inUseSince == nil && afterFix.atLaunch)
        var w = CrashWatch()
        w.raise(recordID: record, deviceID: device, fileName: "Demo-1.ips", diagnosis: diagnosis(at: t0.addingTimeInterval(120)),
                installedAt: t0, now: t0.addingTimeInterval(150), inUseSince: afterFix.inUseSince, atLaunch: afterFix.atLaunch)
        #expect(w.flag(recordID: record, deviceID: device)?.moment == .atLaunch)
    }

    @Test func eachLookStartsWhereTheLastOneDid() {
        var w = CrashWatch()
        let first = w.scanSince(deviceID: device, now: t0)
        #expect(first == t0.addingTimeInterval(-CrashWatch.firstLookback))
        w.scanSucceeded(deviceID: device, startedAt: t0, complete: true)
        let r17 = w.scanSince(deviceID: device, now: t0.addingTimeInterval(120))
        #expect(r17 == t0)
        let got1 = w.scanSince(deviceID: "OTHER", now: t0)
        #expect(got1 == t0.addingTimeInterval(-CrashWatch.firstLookback))
    }

    /// Mega review K1: a look that failed (the phone locked) or read only part of what was new
    /// (the per-look cap) doesn't move the next look's start: nothing older is skipped.
    @Test func aFailedOrCutLookKeepsWhereTheNextStarts() {
        var w = CrashWatch()
        w.scanSucceeded(deviceID: device, startedAt: t0, complete: true)
        // A failed look between two good ones: nothing recorded, the next starts at t0 still.
        #expect(w.scanSince(deviceID: device, now: t0.addingTimeInterval(120)) == t0)
        #expect(w.scanSince(deviceID: device, now: t0.addingTimeInterval(240)) == t0)
        // A look cut by the cap: the next one starts there again (read files are skipped anyway).
        w.scanSucceeded(deviceID: device, startedAt: t0.addingTimeInterval(240), complete: false)
        #expect(w.scanSince(deviceID: device, now: t0.addingTimeInterval(360)) == t0)
        w.scanSucceeded(deviceID: device, startedAt: t0.addingTimeInterval(360), complete: true)
        #expect(w.scanSince(deviceID: device, now: t0.addingTimeInterval(480)) == t0.addingTimeInterval(360))
        // Never backwards (an older look finishing late).
        w.scanSucceeded(deviceID: device, startedAt: t0.addingTimeInterval(100), complete: true)
        #expect(w.scanSince(deviceID: device, now: t0.addingTimeInterval(480)) == t0.addingTimeInterval(360))
    }

    // MARK: Crashes while in use (the module's run marker, a dropped watch)

    @Test func aReportedCrashIsLookedForOncePerRun() {
        var w = CrashWatch()
        let since = t0.addingTimeInterval(100)
        let run = PreviousRun(ended: .crashed, since: since)
        let got2 = w.previousRunReported(recordID: record, deviceID: device, run: run)
        #expect(got2 == .lookForCrash(since: since))
        // Sent again (the reply was lost): not looked for twice.
        let got3 = w.previousRunReported(recordID: record, deviceID: device, run: run)
        #expect(got3 == .nothing)
        // Another run that crashed: looked for.
        let later = PreviousRun(ended: .crashed, since: t0.addingTimeInterval(900))
        let got4 = w.previousRunReported(recordID: record, deviceID: device, run: later)
        #expect(got4 == .lookForCrash(since: later.since))
        // Another installation is its own.
        let got5 = w.previousRunReported(recordID: UUID(), deviceID: device, run: run)
        #expect(got5 == .lookForCrash(since: since))
        // A clean run with nothing flagged: nothing to do.
        let got6 = w.previousRunReported(recordID: record, deviceID: device, run: PreviousRun(ended: .clean, since: t0))
        #expect(got6 == .nothing)
    }

    @Test func aCrashInUseIsFlaggedThoughTheAppRunsAgain() {
        var w = CrashWatch()
        let runStart = t0.addingTimeInterval(100)
        let crashAt = t0.addingTimeInterval(400)
        // The relaunch's check-in comes first (the app runs again), then the crash is found.
        w.launchSeen(recordID: record, deviceID: device, at: t0.addingTimeInterval(500))
        // The usual rule refuses it: the app was seen running after it.
        let usual = raise(&w, "Demo-1.ips", crashAt: crashAt, now: t0.addingTimeInterval(510))
        #expect(!usual)
        // Reported as ending a run in use: flagged, and notified once.
        let flagged = w.raise(recordID: record, deviceID: device, fileName: "Demo-2.ips", diagnosis: diagnosis(at: crashAt),
                              installedAt: t0, now: t0.addingTimeInterval(510), inUseSince: runStart)
        #expect(flagged)
        #expect(w.flag(recordID: record, deviceID: device)?.duringUse == true)
        let again = w.raise(recordID: record, deviceID: device, fileName: "Demo-2.ips", diagnosis: diagnosis(at: crashAt),
                            installedAt: t0, now: t0.addingTimeInterval(520), inUseSince: runStart)
        #expect(!again)
        // Running again doesn't end it (later check-ins every 15 s).
        let cleared = w.launchSeen(recordID: record, deviceID: device, at: t0.addingTimeInterval(600))
        #expect(!cleared)
        #expect(w.flag(recordID: record, deviceID: device) != nil)
        // A clean end of a run that began before the crash says nothing about it.
        let got7 = w.previousRunReported(recordID: record, deviceID: device, run: PreviousRun(ended: .clean, since: runStart))
        #expect(got7 == .nothing)
        #expect(w.flag(recordID: record, deviceID: device) != nil)
        // A run begun after the crash that ended cleanly: the notice goes.
        let got8 = w.previousRunReported(recordID: record, deviceID: device,
                                      run: PreviousRun(ended: .clean, since: t0.addingTimeInterval(500)))
        #expect(got8 == .cleared)
        #expect(w.flag(recordID: record, deviceID: device) == nil)
    }

    @Test func aCrashBeforeTheRunInUseIsNotItsOwn() {
        var w = CrashWatch()
        let runStart = t0.addingTimeInterval(1000)
        // An older crash file (an earlier run) found by the look for this run.
        let old = w.raise(recordID: record, deviceID: device, fileName: "Old.ips", diagnosis: diagnosis(at: t0.addingTimeInterval(500)),
                          installedAt: t0, now: t0.addingTimeInterval(2000), inUseSince: runStart)
        #expect(!old)
        // Within the slack it is.
        let near = w.raise(recordID: record, deviceID: device, fileName: "Near.ips",
                           diagnosis: diagnosis(at: runStart.addingTimeInterval(-CrashWatch.runSlack + 1)),
                           installedAt: t0, now: t0.addingTimeInterval(2000), inUseSince: runStart)
        #expect(near)
        // Dismissed: never again, even reported in use.
        w.dismiss(recordID: record, deviceID: device)
        let back = w.raise(recordID: record, deviceID: device, fileName: "Near.ips",
                           diagnosis: diagnosis(at: runStart), installedAt: t0, now: t0.addingTimeInterval(2100), inUseSince: runStart)
        #expect(!back)
    }

    @Test func oldFilesWithoutTheNewFieldsStillLoad() throws {
        // A crash-watch.json written before 1.2's fast path: no duringUse, no reportedRuns.
        var w = CrashWatch()
        raise(&w, "Demo-1.ips", crashAt: t0.addingTimeInterval(60))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as! [String: Any]
        json["reportedRuns"] = nil
        var flags = json["flags"] as! [String: [String: Any]]
        for k in flags.keys { flags[k]?["duringUse"] = nil }
        json["flags"] = flags
        let back = try JSONDecoder().decode(CrashWatch.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.flag(recordID: record, deviceID: device)?.fileName == "Demo-1.ips")
        #expect(back.flag(recordID: record, deviceID: device)?.duringUse == nil)
    }

    @Test func forgettingAndPruning() {
        var w = CrashWatch()
        raise(&w, "Demo-1.ips", crashAt: t0.addingTimeInterval(60))
        w.scanSucceeded(deviceID: device, startedAt: t0, complete: true)
        w.prune(keeping: [CrashWatch.key(recordID: record, deviceID: device)], now: t0.addingTimeInterval(CrashWatch.seenKeep + 100))
        #expect(w.flag(recordID: record, deviceID: device) != nil)
        #expect(!w.isSeen(fileName: "Demo-1.ips", deviceID: device))
        w.prune(keeping: [], now: t0)
        #expect(w.flags.isEmpty)
        raise(&w, "Demo-2.ips", crashAt: t0.addingTimeInterval(60))
        w.forgetDevice(device)
        #expect(w.flags.isEmpty && !w.isSeen(fileName: "Demo-2.ips", deviceID: device))
        let got9 = w.scanSince(deviceID: device, now: t0)
        #expect(got9 == t0.addingTimeInterval(-CrashWatch.firstLookback))
        // A reported run is forgotten with its installation: looked for again if reported again.
        let run = PreviousRun(ended: .crashed, since: t0)
        _ = w.previousRunReported(recordID: record, deviceID: device, run: run)
        w.forget(recordID: record, deviceID: device)
        let got10 = w.previousRunReported(recordID: record, deviceID: device, run: run)
        #expect(got10 == .lookForCrash(since: t0))
    }

    /// Mega review K5: before the library is read, or when it couldn't be read in full, the
    /// installations XSide knows aren't all of them: nothing of theirs goes, only old read files.
    @Test func anUnknownLibraryPrunesNoInstallation() {
        var w = CrashWatch()
        raise(&w, "Demo-1.ips", crashAt: t0.addingTimeInterval(60))
        raise(&w, "Demo-2.ips", crashAt: t0.addingTimeInterval(120))
        w.dismiss(recordID: record, deviceID: device)
        raise(&w, "Demo-3.ips", crashAt: t0.addingTimeInterval(180))
        w.prune(keeping: nil, now: t0.addingTimeInterval(CrashWatch.seenKeep + 1000))
        #expect(w.flag(recordID: record, deviceID: device)?.fileName == "Demo-3.ips")
        #expect(w.isSettled(recordID: record, deviceID: device, fileName: "Demo-2.ips"))
        #expect(!w.isSeen(fileName: "Demo-1.ips", deviceID: device))
    }

    @Test func survivesASaveAndOldFiles() throws {
        let folder = TestTemp.root.appendingPathComponent("crash-watch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CrashWatchStore(libraryRoot: folder)
        #expect(store.load() == CrashWatch()) // none yet
        var w = CrashWatch()
        raise(&w, "Demo-1.ips", crashAt: t0.addingTimeInterval(60))
        w.scanSucceeded(deviceID: device, startedAt: t0, complete: true)
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
        #expect(CrashAction.suggested(for: diagnosis(.iCloud, at: nil)) == .turnOnICloudSignedOut)
        #expect(CrashAction.suggested(for: diagnosis(.tweak, at: nil)) == .disableTweak)
        #expect(CrashAction.suggested(for: diagnosis(.tweakSupport, at: nil)) == .disableConvertedTweaks)
        #expect(CrashAction.suggested(for: diagnosis(.bundledLibrary, at: nil)) == nil)
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

    /// Mega review K1: one app's crash loop doesn't hide another app's crash (each app's newest
    /// first, then the newest), and the pick says when the cap left some unread.
    @Test func aCrashLoopDoesntHideAnotherAppsCrash() {
        var entries = [entry("Other App-2026-11-09-083000.ips", "2026-11-09T08:30:00Z")]
        for minute in 10..<20 { entries.append(entry("Demo-2026-11-09-09\(minute)00.ips", "2026-11-09T09:\(minute):00Z")) }
        let pick = CrashLogListing.pickNewCrashFiles(entries, executables: ["Demo", "Other App"], since: since, seen: [])
        #expect(pick.files.count == CrashWatch.maxFilesPerScan)
        #expect(pick.files.contains { $0.relativePath.hasPrefix("Other App-") })
        #expect(pick.files.first?.relativePath == "Demo-2026-11-09-091900.ips") // newest first
        #expect(!pick.complete)
        let rest = CrashLogListing.pickNewCrashFiles(Array(entries.prefix(2)), executables: ["Demo", "Other App"], since: since, seen: [])
        #expect(rest.complete && rest.files.count == 2)
    }

    /// Mega review K7: an executable whose name keeps no ASCII letter (all Chinese, emoji) is no
    /// name at all: it never matches other processes' files.
    @Test func aNameWithNoASCIIMatchesNothing() {
        let entries = [entry("抖音-2026-11-09-090000.ips", "2026-11-09T09:00:00Z"),
                       entry("Stranger-2026-11-09-091000.ips", "2026-11-09T09:10:00Z")]
        #expect(CrashLogListing.newCrashFiles(entries, executables: ["微信"], since: since, seen: []).isEmpty)
        #expect(CrashLogListing.candidates(entries, executable: "微信", since: since).crashes.isEmpty)
    }
}

@Suite struct CrashScanScheduleTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let dev = "DEV"

    /// Runs one look at `at` with the given outcome; true when it was due.
    @discardableResult
    private func look(_ s: inout CrashScanSchedule, at: TimeInterval, ok: Bool = true, busy: Bool = false) -> Bool {
        let now = t0.addingTimeInterval(at)
        guard s.isDue(deviceID: dev, now: now, busy: busy) else { return false }
        s.started(deviceID: dev, now: now)
        s.finished(deviceID: dev, succeeded: ok)
        return true
    }

    @Test func everyTwoMinutes() {
        var s = CrashScanSchedule()
        #expect(look(&s, at: 0)) // never looked at: at once
        #expect(!look(&s, at: 15))
        #expect(!look(&s, at: 105))
        #expect(look(&s, at: 120))
        // The engine ticks every 15 s: a tick a hair early still counts.
        #expect(look(&s, at: 239.5))
        #expect(s.isDue(deviceID: "OTHER", now: t0.addingTimeInterval(240), busy: false))
    }

    @Test func everyFifteenSecondsForThreeMinutesAfterAnInstall() {
        var s = CrashScanSchedule()
        look(&s, at: 0)
        s.boost(deviceID: dev, now: t0.addingTimeInterval(10))
        #expect(s.interval(deviceID: dev, now: t0.addingTimeInterval(10)) == CrashScanSchedule.boostedInterval)
        #expect(look(&s, at: 15))
        #expect(!look(&s, at: 20))
        var looks = 1
        var at: TimeInterval = 30
        while at <= 10 + CrashScanSchedule.boostDuration - 1 { if look(&s, at: at) { looks += 1 }; at += 15 }
        #expect(looks >= 11)
        // Over: back to every 2 minutes.
        #expect(!s.isBoosted(deviceID: dev, now: t0.addingTimeInterval(191)))
        #expect(s.interval(deviceID: dev, now: t0.addingTimeInterval(191)) == CrashScanSchedule.interval)
        // A later boost extends, never shortens.
        s.boost(deviceID: dev, now: t0.addingTimeInterval(300))
        s.boost(deviceID: dev, now: t0.addingTimeInterval(200))
        #expect(s.isBoosted(deviceID: dev, now: t0.addingTimeInterval(479)))
    }

    /// Morning review I2: a polling or watching app's check-ins don't keep the 15 s listing on;
    /// only the first one after a gap boosts.
    @Test func onlyTheFirstCheckInAfterAGapBoosts() {
        var s = CrashScanSchedule()
        let app = "R|\(dev)"
        look(&s, at: 0)
        do { let boosted = s.checkedIn(installation: app, deviceID: dev, now: t0.addingTimeInterval(5)); #expect(boosted) }
        #expect(s.isBoosted(deviceID: dev, now: t0.addingTimeInterval(5)))
        // Polling every 15 s for an hour: never boosted again past the first 3 minutes.
        var looks = 0
        var at: TimeInterval = 15
        while at <= 3600 {
            do { let boosted = s.checkedIn(installation: app, deviceID: dev, now: t0.addingTimeInterval(at)); #expect(!boosted) }
            if look(&s, at: at) { looks += 1 }
            at += 15
        }
        #expect(!s.isBoosted(deviceID: dev, now: t0.addingTimeInterval(3600)))
        // 3 boosted minutes (~12 looks), then every 2 minutes (~28 looks): far from 240.
        #expect(looks <= 45)
        // A watch every 300 s doesn't renew it either.
        do { let boosted = s.checkedIn(installation: app, deviceID: dev, now: t0.addingTimeInterval(3900)); #expect(!boosted) }
        // Silent for more than 10 minutes: the next check-in is a new run, boosted.
        do { let boosted = s.checkedIn(installation: app, deviceID: dev, now: t0.addingTimeInterval(3900 + CrashScanSchedule.checkInGap)); #expect(boosted) }
        // Another installation's first check-in boosts too.
        do { let boosted = s.checkedIn(installation: "S|\(dev)", deviceID: dev, now: t0.addingTimeInterval(5000)); #expect(boosted) }
    }

    @Test func aCheckInWithoutBoostStillEndsABackOff() {
        var s = CrashScanSchedule()
        let app = "R|\(dev)"
        s.checkedIn(installation: app, deviceID: dev, now: t0)
        s.started(deviceID: dev, now: t0.addingTimeInterval(200))
        s.finished(deviceID: dev, succeeded: false)
        #expect(s.failures(deviceID: dev) == 1)
        do { let boosted = s.checkedIn(installation: app, deviceID: dev, now: t0.addingTimeInterval(210)); #expect(!boosted) }
        #expect(s.failures(deviceID: dev) == 0)
        // A forgotten device forgets its installations' check-ins: the next one boosts.
        s.forget(deviceID: dev)
        do { let boosted = s.checkedIn(installation: app, deviceID: dev, now: t0.addingTimeInterval(220)); #expect(boosted) }
    }

    @Test func neverDuringAJobNorTwiceAtOnce() {
        var s = CrashScanSchedule()
        #expect(!s.isDue(deviceID: dev, now: t0, busy: true))
        s.started(deviceID: dev, now: t0)
        // Still running (slow device): not started again, even long after.
        #expect(!s.isDue(deviceID: dev, now: t0.addingTimeInterval(600), busy: false))
        s.finished(deviceID: dev, succeeded: true)
        #expect(s.isDue(deviceID: dev, now: t0.addingTimeInterval(600), busy: false))
        #expect(!s.isDue(deviceID: dev, now: t0.addingTimeInterval(600), busy: true))
    }

    @Test func failuresBackOffAndASignOfLifeEndsIt() {
        var s = CrashScanSchedule()
        look(&s, at: 0, ok: false) // locked, out of reach
        #expect(s.interval(deviceID: dev, now: t0) == 240)
        #expect(!look(&s, at: 120, ok: false))
        #expect(look(&s, at: 240, ok: false))
        #expect(s.interval(deviceID: dev, now: t0) == 480)
        for _ in 0..<20 { s.started(deviceID: dev, now: t0); s.finished(deviceID: dev, succeeded: false) }
        #expect(s.interval(deviceID: dev, now: t0) == CrashScanSchedule.maxBackoff)
        // A look that works: back to normal.
        s.started(deviceID: dev, now: t0)
        s.finished(deviceID: dev, succeeded: true)
        #expect(s.interval(deviceID: dev, now: t0) == CrashScanSchedule.interval)
        // Backed off again, then the device shows a sign of life (an install, a check-in).
        s.started(deviceID: dev, now: t0)
        s.finished(deviceID: dev, succeeded: false)
        s.boost(deviceID: dev, now: t0)
        #expect(s.failures(deviceID: dev) == 0)
        #expect(s.interval(deviceID: dev, now: t0) == CrashScanSchedule.boostedInterval)
        // A failure while boosted backs off from 15 s.
        s.started(deviceID: dev, now: t0)
        s.finished(deviceID: dev, succeeded: false)
        #expect(s.interval(deviceID: dev, now: t0) == 30)
    }

    @Test func aClockSetBackOrAForgottenDeviceDoesntBlock() {
        var s = CrashScanSchedule()
        look(&s, at: 0)
        #expect(s.isDue(deviceID: dev, now: t0.addingTimeInterval(-10_000), busy: false))
        look(&s, at: 1, ok: false)
        s.forget(deviceID: dev)
        #expect(s.failures(deviceID: dev) == 0 && s.isDue(deviceID: dev, now: t0.addingTimeInterval(2), busy: false))
        s.finished(deviceID: "NEVER", succeeded: false) // unknown: nothing
        #expect(s.failures(deviceID: "NEVER") == 0)
    }
}

/// The Mac's fast path when a watch ends: only an abrupt end of a watch that says goodbye.
@Suite struct WatchCloseTests {
    private let secret = Data(repeating: 7, count: 32)
    private let id = "rec|dev"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(_ r: ChannelRequest, installationID: String? = nil, secret: Data? = nil, nonce: String = "bye1",
                      at: Date? = nil) throws -> Data {
        try ChannelEnvelope.seal(r, installationID: installationID ?? id, secret: secret ?? self.secret,
                                 now: at ?? now, nonce: nonce).encodedLine().dropLast()
    }

    private func abrupt(_ close: WatchClose, saysBye: Bool = true, nonces: inout ChannelNonces) -> Bool {
        ChannelHandler.watchEndedAbruptly(close, saysBye: saysBye, installationID: id, now: now, nonces: &nonces, secret: secret)
    }

    @Test func aGoodbyeIsAClean() throws {
        var n = ChannelNonces()
        #expect(!abrupt(.byPhone(farewell: try line(.bye)), nonces: &n))
        // Replayed on another watch: not a goodbye any more.
        #expect(abrupt(.byPhone(farewell: try line(.bye)), nonces: &n))
    }

    @Test func noGoodbyeIsAbrupt() throws {
        var n = ChannelNonces()
        #expect(abrupt(.byPhone(farewell: nil), nonces: &n))
        // Garbage, another request, a forged or stale bye, another installation's bye.
        #expect(abrupt(.byPhone(farewell: Data("hello".utf8)), nonces: &n))
        #expect(abrupt(.byPhone(farewell: try line(.refresh, nonce: "r1")), nonces: &n))
        #expect(abrupt(.byPhone(farewell: try line(.bye, secret: Data(repeating: 8, count: 32), nonce: "f1")), nonces: &n))
        #expect(abrupt(.byPhone(farewell: try line(.bye, nonce: "s1", at: now.addingTimeInterval(-300))), nonces: &n))
        #expect(abrupt(.byPhone(farewell: try line(.bye, installationID: "rec|other", nonce: "o1")), nonces: &n))
    }

    @Test func xsidesOwnClosesAndOlderDylibsSayNothing() throws {
        var n = ChannelNonces()
        #expect(!abrupt(.byMac, nonces: &n))
        #expect(!abrupt(.byPhone(farewell: nil), saysBye: false, nonces: &n))
        #expect(!abrupt(.byPhone(farewell: Data("x".utf8)), saysBye: false, nonces: &n))
    }

    @Test func aByeOnItsOwnChangesNothing() {
        let installation = Installation(deviceID: "dev", installedAt: now, expiresAt: now.addingTimeInterval(86_400))
        let (reply, update) = ChannelHandler.handle(.bye, installation: installation, now: now, reminder: true)
        #expect(reply == .accepted && update == .none)
    }
}
