import Foundation
import Testing
@testable import XSideCore

@Suite("InAppSettings")
struct InAppSettingsTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @Test func mergeKeepsTheNewestChangePerField() {
        let base = InAppSettings.defaults(reminder: true, at: t0)
        // Mac changed language at t2 and reminder at t1; device changed reminder at t3 and the card at t1.
        var mac = base
        mac = mac.setting(\.language, to: .fr, at: at(2), by: .mac)
        mac = mac.setting(\.reminder, to: false, at: at(1), by: .mac)
        var dev = base
        dev = dev.setting(\.reminder, to: true, at: at(3), by: .device)
        dev = dev.setting(\.refreshCard, to: false, at: at(1), by: .device)
        dev = dev.setting(\.language, to: .en, at: at(1), by: .device)
        for merged in [InAppSettings.merge(mac, dev), InAppSettings.merge(dev, mac)] {
            #expect(merged.language.value == .fr)       // Mac newer
            #expect(merged.reminder.value == true)      // device newer
            #expect(merged.reminder.changedBy == .device)
            #expect(merged.refreshCard.value == false)  // only changed on device (t1 > t0)
            #expect(merged.showValidity == base.showValidity)
        }
    }

    @Test func tieGoesToTheDevice() {
        let base = InAppSettings.defaults(reminder: true, at: t0)
        let mac = base.setting(\.alertLate, to: false, at: at(5), by: .mac)
        let dev = base.setting(\.alertLate, to: true, at: at(5), by: .device)
        #expect(InAppSettings.merge(mac, dev).alertLate.value == true)
        #expect(InAppSettings.merge(dev, mac).alertLate.value == true)
        #expect(InAppSettings.merge(mac, dev).alertLate.changedBy == .device)
    }

    @Test func secondsOfSkewDontFlipAnOlderChange() {
        let base = InAppSettings.defaults(reminder: true, at: t0)
        let dev = base.setting(\.refreshCard, to: false, at: at(100), by: .device)
        let mac = base.setting(\.autoRefresh, to: false, at: at(105), by: .mac)
        let m = InAppSettings.merge(dev, mac)
        #expect(m.refreshCard.value == false)
        #expect(m.autoRefresh.value == false)
        #expect(m == InAppSettings.merge(mac, dev))
    }

    @Test func defaultsSeedTheReminderFromTheGlobalSetting() {
        let d = InAppSettings.defaults(reminder: false, at: t0)
        #expect(d.reminder.value == false)
        #expect(d.showValidity.value == true) // the validity pill is on by default (Anthony, 2026-11-08)
        #expect(d.alertLate.value && d.refreshCard.value && d.autoRefresh.value)
        #expect(d.derivedLevel == .essentials || d.derivedLevel == .custom) // reminder off: not "all"
        #expect(InAppSettings.defaults(reminder: true, at: t0).derivedLevel == .all)
        #expect(d.language.value == .automatic)
        #expect(d.alertLate.changedBy == .mac && d.alertLate.changedAt == t0)
        #expect(InAppSettings.defaults(reminder: true, at: t0).reminder.value == true)
    }

    private func settings(validity: Bool, late: Bool, card: Bool, reminder: Bool) -> InAppSettings {
        InAppSettings.defaults(reminder: reminder, at: t0)
            .setting(\.showValidity, to: validity, at: t0, by: .mac)
            .setting(\.alertLate, to: late, at: t0, by: .mac)
            .setting(\.refreshCard, to: card, at: t0, by: .mac)
    }

    @Test func visibilityFollowsTheFourSwitches() {
        // Spec §1 table (validity, alert) -> (fine, late): validity pill / late pill.
        let rows: [(Bool, Bool, Bool, Bool, Bool, Bool)] = [
            // validity, alert, fine: validity pill, fine: late pill, late: validity pill, late: late pill
            (true, true, true, false, false, true),     // normal / late
            (false, true, false, false, false, true),   // nothing / late
            (true, false, true, false, true, false),    // normal / normal
            (false, false, false, false, false, false), // nothing / nothing
        ]
        for r in rows {
            let s = settings(validity: r.0, late: r.1, card: true, reminder: true)
            #expect(s.showsValidityPill(late: false) == r.2)
            #expect(s.showsLatePill(late: false) == r.3)
            #expect(s.showsValidityPill(late: true) == r.4)
            #expect(s.showsLatePill(late: true) == r.5)
        }
        // Card and reminder: their own switch only.
        #expect(!settings(validity: true, late: true, card: false, reminder: true).showsRefreshCard)
        #expect(settings(validity: false, late: false, card: true, reminder: false).showsRefreshCard)
        #expect(!settings(validity: true, late: true, card: true, reminder: false).schedulesReminder)
        #expect(settings(validity: false, late: false, card: false, reminder: true).schedulesReminder)
        // The install sheet shows unless all four are off.
        #expect(!settings(validity: false, late: false, card: false, reminder: false).showsInstallSheet)
        for i in 0..<4 {
            let s = settings(validity: i == 0, late: i == 1, card: i == 2, reminder: i == 3)
            #expect(s.showsInstallSheet)
        }
    }

    @Test func levelIsDerivedFromTheSwitches() {
        #expect(settings(validity: true, late: true, card: true, reminder: true).derivedLevel == .all)
        #expect(settings(validity: false, late: true, card: false, reminder: true).derivedLevel == .essentials)
        #expect(settings(validity: false, late: false, card: false, reminder: false).derivedLevel == .none)
        #expect(settings(validity: true, late: true, card: false, reminder: true).derivedLevel == .custom)
        #expect(settings(validity: false, late: true, card: false, reminder: false).derivedLevel == .custom)
    }

    @Test func applyingALevelSetsTheFourSwitches() {
        let base = settings(validity: true, late: false, card: true, reminder: false)
        let e = base.applying(level: .essentials, at: at(9), by: .mac)
        #expect(e.derivedLevel == .essentials)
        #expect(e.showValidity == Field(value: false, changedAt: at(9), changedBy: .mac))
        #expect(e.alertLate == Field(value: true, changedAt: at(9), changedBy: .mac))
        #expect(e.language == base.language && e.autoRefresh == base.autoRefresh)
        #expect(base.applying(level: .all, at: at(9), by: .device).derivedLevel == .all)
        let n = base.applying(level: .none, at: at(9), by: .device)
        #expect(n.derivedLevel == .none && n.reminder.changedBy == .device)
        #expect(base.applying(level: .custom, at: at(9), by: .mac) == base) // nothing to apply
    }

    /// Settings stored by an earlier 1.1 build carry a "level" field: it still decodes, ignored.
    @Test func storedLevelFieldIsIgnored() throws {
        let s = settings(validity: false, late: true, card: false, reminder: true)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        json["level"] = ["value": "none", "changedAt": 0, "changedBy": "device"]
        let back = try JSONDecoder().decode(InAppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back == s)
        #expect(back.derivedLevel == .essentials)
    }

    @Test func oldInstallationsStillDecode() throws {
        let json = #"{"deviceID":"d","installedAt":0,"expiresAt":100}"#
        let i = try JSONDecoder().decode(Installation.self, from: Data(json.utf8))
        #expect(i.inApp == nil && i.pausedBy == nil && i.firstInstalledAt == nil)
        #expect(i.lastRefreshOutcome == nil && i.channelSecret == nil && i.lastCheckIn == nil)
    }

    @Test func newInstallationFieldsRoundTrip() throws {
        var i = Installation(deviceID: "d", installedAt: t0, expiresAt: at(100))
        i.inApp = .defaults(reminder: true, at: t0)
        i.pausedBy = .device
        i.channelSecret = Data([1, 2, 3])
        i.lastRefreshOutcome = RefreshOutcome(at: t0, succeeded: false, reasonKey: "k")
        let back = try JSONDecoder().decode(Installation.self, from: JSONEncoder().encode(i))
        #expect(back == i)
    }
}
