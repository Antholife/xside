import Foundation
import Testing
@testable import XSideCore

@Suite("InAppSettings")
struct InAppSettingsTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @Test func mergeKeepsTheNewestChangePerField() {
        let base = InAppSettings.defaults(reminder: true, at: t0)
        // Mac changed language at t2 and reminder at t1; device changed reminder at t3 and level at t1.
        var mac = base
        mac = mac.setting(\.language, to: .fr, at: at(2), by: .mac)
        mac = mac.setting(\.reminder, to: false, at: at(1), by: .mac)
        var dev = base
        dev = dev.setting(\.reminder, to: true, at: at(3), by: .device)
        dev = dev.setting(\.level, to: .essentials, at: at(1), by: .device)
        dev = dev.setting(\.language, to: .en, at: at(1), by: .device)
        for merged in [InAppSettings.merge(mac, dev), InAppSettings.merge(dev, mac)] {
            #expect(merged.language.value == .fr)       // Mac newer
            #expect(merged.reminder.value == true)      // device newer
            #expect(merged.reminder.changedBy == .device)
            #expect(merged.level.value == .essentials)  // only changed on device (t1 > t0)
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
        #expect(d.showValidity.value == false)
        #expect(d.alertLate.value && d.refreshCard.value && d.autoRefresh.value)
        #expect(d.level.value == .all)
        #expect(d.language.value == .automatic)
        #expect(d.level.changedBy == .mac && d.level.changedAt == t0)
        #expect(InAppSettings.defaults(reminder: true, at: t0).reminder.value == true)
    }

    private func settings(_ level: MessageLevel, validity: Bool, late: Bool, card: Bool = true,
                          reminder: Bool = true) -> InAppSettings {
        InAppSettings.defaults(reminder: reminder, at: t0)
            .setting(\.level, to: level, at: t0, by: .mac)
            .setting(\.showValidity, to: validity, at: t0, by: .mac)
            .setting(\.alertLate, to: late, at: t0, by: .mac)
            .setting(\.refreshCard, to: card, at: t0, by: .mac)
    }

    @Test func visibilityMatrix() {
        // Level .all: spec §1 table (validity, alert) -> (fine, late). "n" normal, "l" late, "-" nothing.
        let rows: [(Bool, Bool, Bool, Bool, Bool, Bool)] = [
            // validity, alert, fine: validity pill, fine: late pill, late: validity pill, late: late pill
            (true, true, true, false, false, true),     // normal / late
            (false, true, false, false, false, true),   // nothing / late
            (true, false, true, false, true, false),    // normal / normal
            (false, false, false, false, false, false), // nothing / nothing
        ]
        for r in rows {
            let s = settings(.all, validity: r.0, late: r.1)
            #expect(s.showsValidityPill(late: false) == r.2)
            #expect(s.showsLatePill(late: false) == r.3)
            #expect(s.showsValidityPill(late: true) == r.4)
            #expect(s.showsLatePill(late: true) == r.5)
        }
        // Essentials: ceiling, only problem alerts whose own switch is on.
        let e = settings(.essentials, validity: true, late: true, card: true)
        #expect(!e.showsValidityPill(late: false) && !e.showsValidityPill(late: true))
        #expect(e.showsLatePill(late: true) && !e.showsLatePill(late: false))
        #expect(!e.showsRefreshCard && !e.showsInstallSheet)
        #expect(e.schedulesReminder)
        let eOff = settings(.essentials, validity: true, late: false, reminder: false)
        #expect(!eOff.showsLatePill(late: true))
        #expect(!eOff.schedulesReminder)
        // None: nothing at all, install sheet included, switches keep their values.
        let n = settings(.none, validity: true, late: true)
        #expect(!n.showsValidityPill(late: false) && !n.showsValidityPill(late: true))
        #expect(!n.showsLatePill(late: true) && !n.showsRefreshCard)
        #expect(!n.schedulesReminder && !n.showsInstallSheet)
        #expect(n.alertLate.value && n.showValidity.value)
        // All: card and sheet follow their rule.
        let a = settings(.all, validity: false, late: true, card: false)
        #expect(!a.showsRefreshCard && a.showsInstallSheet && a.schedulesReminder)
        #expect(settings(.all, validity: false, late: true).showsRefreshCard)
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
