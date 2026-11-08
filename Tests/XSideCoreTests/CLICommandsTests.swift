import Testing
import Foundation
@testable import XSideCore

/// Device feedback 3, E7: the new `xside` commands, parsed in XSideCore so they can be tested.
struct CLICommandsTests {
    func parse(_ line: String) -> Result<CLIInvocation, CLIUsageError> {
        CLIInvocation.parse(line.split(separator: " ").map(String.init))
    }

    @Test func listsAndShows() {
        #expect(parse("apps") == .success(.apps(json: false)))
        #expect(parse("apps --json") == .success(.apps(json: true)))
        #expect(parse("devices --json") == .success(.devices(json: true)))
        #expect(parse("status") == .success(.status(json: false)))
        #expect(parse("settings YouTube") == .success(.showSettings(app: "YouTube", device: nil, json: false)))
        #expect(parse("settings YouTube --device Duo --json") == .success(.showSettings(app: "YouTube", device: "Duo", json: true)))
        #expect(parse("logs") == .success(.logs(follow: false)))
        #expect(parse("logs -f") == .success(.logs(follow: true)))
        #expect(parse("report") == .success(.report))
        #expect(parse("") == .success(.help))
    }

    @Test func setsSettings() {
        #expect(parse("settings yt reminder=off language=fr level=essentials") == .success(.setSettings(
            app: "yt", device: nil, changes: [.reminder(false), .language(.fr), .level(.essentials)])))
        #expect(parse("settings yt --device iPad autoRefresh=on showValidity=true alertLate=no refreshCard=1 language=auto level=none")
                == .success(.setSettings(app: "yt", device: "iPad", changes: [
                    .autoRefresh(true), .showValidity(true), .alertLate(false), .refreshCard(true),
                    .language(.automatic), .level(.none)])))
        // Field names are case-insensitive; a wrong field or value is an error naming it.
        #expect(parse("settings yt REMINDER=Off") == .success(.setSettings(app: "yt", device: nil, changes: [.reminder(false)])))
        guard case .failure(let e1) = parse("settings yt colour=red") else { Issue.record("accepted"); return }
        #expect(e1.message.contains("colour"))
        guard case .failure(let e2) = parse("settings yt reminder=maybe") else { Issue.record("accepted"); return }
        #expect(e2.message.contains("maybe"))
        guard case .failure = parse("settings yt level=custom") else { Issue.record("custom is derived, not set"); return }
        guard case .failure = parse("settings") else { Issue.record("no app"); return }
        // Review D–G minor 3: --json with changes isn't silently dropped.
        guard case .failure(let e3) = parse("settings yt --json reminder=off") else { Issue.record("--json dropped"); return }
        #expect(e3.message.contains("--json"))
    }

    /// Review D–G minor 1: an app already paused keeps its pause, and the answer says so.
    @Test func pauseOfAnAlreadyPausedAppSaysSo() {
        #expect(CLIBridge.pauseAppSummary(paused: ["YouTube on Duo"], already: [], when: "until 9 Nov, 14:00")
                == "Paused until 9 Nov, 14:00: YouTube on Duo")
        let both = CLIBridge.pauseAppSummary(paused: ["YouTube on Duo"], already: ["YouTube on iPad (until resumed)"],
                                             when: "until 9 Nov, 14:00")
        #expect(both == "Paused until 9 Nov, 14:00: YouTube on Duo\nAlready paused, left as it was: YouTube on iPad (until resumed). To change it: xside resume <app>, then pause again.")
        #expect(!CLIBridge.pauseAppSummary(paused: [], already: ["YouTube on iPad (until resumed)"], when: "until 9 Nov").contains("Paused until"))
    }

    /// `pause <duration>` alone stays the global pause (1.0.6); `pause <app> [duration]` is one app.
    @Test func pausesAndResumes() {
        #expect(parse("pause") == .success(.pauseAll(seconds: nil)))
        #expect(parse("pause 2h") == .success(.pauseAll(seconds: 7200)))
        #expect(parse("resume") == .success(.resumeAll))
        #expect(parse("pause YouTube") == .success(.pauseApp(app: "YouTube", device: nil, seconds: nil)))
        #expect(parse("pause YouTube 30m") == .success(.pauseApp(app: "YouTube", device: nil, seconds: 1800)))
        #expect(parse("pause YouTube 1d --device Duo") == .success(.pauseApp(app: "YouTube", device: "Duo", seconds: 86_400)))
        #expect(parse("resume YouTube") == .success(.resumeApp(app: "YouTube", device: nil)))
        guard case .failure = parse("pause YouTube soon") else { Issue.record("bad duration accepted"); return }
    }

    @Test func uninstallAsksUnlessYes() {
        #expect(parse("uninstall YouTube") == .success(.uninstall(app: "YouTube", device: nil, yes: false)))
        #expect(parse("uninstall YouTube --device Duo --yes") == .success(.uninstall(app: "YouTube", device: "Duo", yes: true)))
        guard case .failure = parse("uninstall") else { Issue.record("no app"); return }
    }

    @Test func keepsTheOlderCommands() {
        #expect(parse("refresh --all") == .success(.refreshAll))
        #expect(parse("refresh yt --device Duo") == .success(.refresh(app: "yt", device: "Duo")))
        #expect(parse("install ~/a.ipa") == .success(.install(path: "~/a.ipa")))
        #expect(parse("open") == .success(.open))
        guard case .failure = parse("frobnicate") else { Issue.record("unknown accepted"); return }
        guard case .failure = parse("apps extra") else { Issue.record("stray argument accepted"); return }
    }

    /// Changes applied as from the UI: stamped by the Mac; the level sets the four switches.
    @Test func changesApplyLikeTheUI() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let s = InAppSettings.defaults(reminder: true, at: now.addingTimeInterval(-60))
        let edited = s.applying([.level(.none), .reminder(true), .language(.en)], at: now)
        #expect(edited.showValidity.value == false && edited.reminder == Field(value: true, changedAt: now, changedBy: .mac))
        #expect(edited.language == Field(value: .en, changedAt: now, changedBy: .mac))
        #expect(edited.autoRefresh == s.autoRefresh) // that one goes through the pause
    }

    // MARK: Matching apps and devices

    let candidates = [
        CLIMatch.Candidate(recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, deviceID: "d1",
                           app: "YouTube", bundleID: "com.google.ios.youtube", device: "iPhone Duo de Anthony"),
        CLIMatch.Candidate(recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, deviceID: "d2",
                           app: "YouTube", bundleID: "com.google.ios.youtube", device: "iPad"),
        CLIMatch.Candidate(recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, deviceID: "d1",
                           app: "YouTube Music", bundleID: "com.google.ios.youtubemusic", device: "iPhone Duo de Anthony"),
        CLIMatch.Candidate(recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, deviceID: "d1",
                           app: "Delta", bundleID: "com.rileytestut.Delta", device: "iPhone Duo de Anthony"),
    ]

    @Test func appsMatchByNameOrBundleIDCaseInsensitive() throws {
        #expect(try CLIMatch.find(app: "youtube", device: nil, in: candidates).get().map(\.deviceID) == ["d1", "d2"])
        #expect(try CLIMatch.find(app: "COM.RILEYTESTUT.DELTA", device: nil, in: candidates).get().map(\.app) == ["Delta"])
        #expect(try CLIMatch.find(app: "delt", device: nil, in: candidates).get().map(\.app) == ["Delta"])
        #expect(try CLIMatch.find(app: "youtube", device: "ipad", in: candidates).get().map(\.deviceID) == ["d2"])
    }

    @Test func ambiguityListsTheCandidates() {
        guard case .failure(let e) = CLIMatch.find(app: "you", device: nil, in: candidates) else { Issue.record("guessed"); return }
        #expect(e.message.contains("YouTube (com.google.ios.youtube)") && e.message.contains("YouTube Music (com.google.ios.youtubemusic)"))
        guard case .failure(let none) = CLIMatch.find(app: "netflix", device: nil, in: candidates) else { Issue.record("found"); return }
        #expect(none.message.contains("netflix"))
        guard case .failure(let device) = CLIMatch.find(app: "Delta", device: "ipad", in: candidates) else { Issue.record("found"); return }
        #expect(device.message.contains("ipad"))
    }
}
