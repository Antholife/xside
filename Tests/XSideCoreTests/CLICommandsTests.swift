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

    @Test func crashDiagnosis() {
        #expect(parse("crash YouTube") == .success(.crash(app: "YouTube", device: nil, json: false)))
        #expect(parse("crash YouTube --device Duo --json") == .success(.crash(app: "YouTube", device: "Duo", json: true)))
        guard case .failure = parse("crash") else { Issue.record("no app"); return }
        guard case .failure = parse("crash a b") else { Issue.record("extra word"); return }
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

    /// Mega review C11: two devices with the same name are told apart by their ids, which the
    /// error gives (and `--device` takes).
    @Test func devicesOfTheSameNameAreListedWithTheirIDs() throws {
        let id = UUID()
        let twins = [CLIMatch.Candidate(recordID: id, deviceID: "00008110-AAA", app: "Delta", bundleID: "d", device: "iPhone"),
                     CLIMatch.Candidate(recordID: id, deviceID: "00008110-BBB", app: "Delta", bundleID: "d", device: "iPhone")]
        guard case .failure(let e) = CLIMatch.find(app: "Delta", device: "iphone", in: twins) else { Issue.record("guessed"); return }
        #expect(e.message.contains("iPhone (00008110-AAA)") && e.message.contains("iPhone (00008110-BBB)"))
        #expect(e.message.contains("--device"))
        #expect(try CLIMatch.find(app: "Delta", device: "00008110-BBB", in: twins).get().map(\.deviceID) == ["00008110-BBB"])
        #expect(CLIMatch.deviceLabel(name: "iPhone", id: "00008110-AAA") == "iPhone (00008110-AAA)")
        #expect(CLIMatch.deviceLabel(name: "00008110-AAA", id: "00008110-AAA") == "00008110-AAA")
    }

    // MARK: Global flags (mega review C10)

    /// `--debug` and `--version` count only before the command word: after it, they are the
    /// command's own words (a device named "--debug", an unexpected argument).
    @Test func globalFlagsComeBeforeTheCommand() {
        #expect(CLIGlobalFlags(["--debug", "status"]) == CLIGlobalFlags(debug: true, version: false, rest: ["status"]))
        #expect(CLIGlobalFlags(["--version"]) == CLIGlobalFlags(debug: false, version: true, rest: []))
        #expect(CLIGlobalFlags(["--debug", "--version"]) == CLIGlobalFlags(debug: true, version: true, rest: []))
        #expect(CLIGlobalFlags(["refresh", "yt", "--device", "--debug"])
                == CLIGlobalFlags(debug: false, version: false, rest: ["refresh", "yt", "--device", "--debug"]))
        #expect(CLIGlobalFlags(["status", "--version"]) == CLIGlobalFlags(debug: false, version: false, rest: ["status", "--version"]))
        guard case .failure = CLIInvocation.parse(CLIGlobalFlags(["status", "--debug"]).rest) else { Issue.record("flag dropped"); return }
    }

    // MARK: Status (mega review C9)

    @Test func statusSaysWhenAnAppsPauseEnds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let end = now.addingTimeInterval(7200)
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened)
        #expect(CLIStatus.refreshNote(paused: true, pausedUntil: end, allPaused: false, nextRefresh: now, now: now, format: format)
                == " · paused until \(end.formatted(format))")
        #expect(CLIStatus.refreshNote(paused: true, pausedUntil: nil, allPaused: false, nextRefresh: now, now: now, format: format)
                == " · paused")
        #expect(CLIStatus.refreshNote(paused: false, pausedUntil: nil, allPaused: true, nextRefresh: now, now: now, format: format)
                == " · refreshes paused")
        #expect(CLIStatus.refreshNote(paused: false, pausedUntil: nil, allPaused: false, nextRefresh: end, now: now, format: format)
                == " · next refresh \(end.formatted(format))")
    }
}

/// `--json`: stdout holds one JSON document, whatever happens (review Important 2).
struct CLIJSONOutputTests {
    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func anErrorIsJSON() throws {
        let doc = try object(CLIJSONOutput.error("no app matches \"x\" \\ (see xside apps)"))
        #expect(doc["ok"] as? Bool == false)
        #expect(doc["error"] as? String == "no app matches \"x\" \\ (see xside apps)")
    }

    @Test func aRepliesJSONIsPrintedAsIs() throws {
        let rows = "[\n  {\"app\" : \"Demo\", \"error\" : \"unreachable\"}\n]"
        #expect(CLIJSONOutput.document(fromReply: rows) == rows)
        #expect(try object(CLIJSONOutput.document(fromReply: "That app is no longer installed there."))["error"] as? String
            == "That app is no longer installed there.")
        #expect(try object(CLIJSONOutput.document(fromReply: ""))["ok"] as? Bool == false)
    }

    @Test func everyOutcomeGivesJSON() throws {
        typealias Outcome = CLIBridge.Wait.Outcome
        for outcome: Outcome in [.noAnswer, .stoppedAnswering, .stillWorking, .waiting] {
            let doc = try object(CLIJSONOutput.document(for: outcome))
            #expect(doc["ok"] as? Bool == false)
            #expect((doc["error"] as? String)?.isEmpty == false)
        }
        let ok = CLIBridge.Reply(id: "1", ok: true, message: "[]")
        #expect(CLIJSONOutput.document(for: .finished(ok)) == "[]")
        let failed = CLIBridge.Reply(id: "1", ok: false, message: "[{\"error\":\"x\"}]")
        #expect(CLIJSONOutput.document(for: .finished(failed)) == "[{\"error\":\"x\"}]")
    }
}
