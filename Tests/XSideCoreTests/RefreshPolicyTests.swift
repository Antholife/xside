import Testing
import Foundation
@testable import XSideCore

private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Paris")!
    return c
}

/// 2026-11-05 at `hour`:00, Paris time.
private func at(_ hour: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: hour))!
}

private let days: TimeInterval = 86_400

struct RefreshPolicyTests {
    @Test func noSettingsAllowsEverything() {
        #expect(RefreshPolicy().allows(expiresAt: at(14).addingTimeInterval(2 * days), now: at(14), calendar: calendar))
    }

    @Test func pausedUntilADate() {
        let policy = RefreshPolicy(pausedUntil: at(20))
        let expiry = at(14).addingTimeInterval(2 * days)
        #expect(!policy.allows(expiresAt: expiry, now: at(14), calendar: calendar))
        #expect(policy.allows(expiresAt: expiry, now: at(20), calendar: calendar))
    }

    @Test func onBatteryWhenACOnly() {
        let expiry = at(14).addingTimeInterval(2 * days)
        #expect(!RefreshPolicy(acOnly: true, onBattery: true).allows(expiresAt: expiry, now: at(14), calendar: calendar))
        #expect(RefreshPolicy(acOnly: true, onBattery: false).allows(expiresAt: expiry, now: at(14), calendar: calendar))
        #expect(RefreshPolicy(acOnly: false, onBattery: true).allows(expiresAt: expiry, now: at(14), calendar: calendar))
    }

    @Test func waitsForThePreferredHours() {
        let night = RefreshPolicy(preferredHours: .night)
        let expiry = at(14).addingTimeInterval(2 * days)
        #expect(!night.allows(expiresAt: expiry, now: at(14), calendar: calendar))
        #expect(night.allows(expiresAt: expiry, now: at(3), calendar: calendar))
        #expect(!night.allows(expiresAt: expiry, now: at(6), calendar: calendar)) // 1 h – 6 h: 6:00 is past
        let evening = RefreshPolicy(preferredHours: .evening)
        #expect(evening.allows(expiresAt: expiry, now: at(21), calendar: calendar))
        #expect(!evening.allows(expiresAt: expiry, now: at(23), calendar: calendar))
    }

    /// Review I1: an app signed with a replaced or revoked certificate may stop launching any time.
    @Test func certificateChangeAlwaysGoes() {
        let policy = RefreshPolicy(pausedUntil: .distantFuture, acOnly: true, onBattery: true, preferredHours: .night)
        #expect(policy.allows(expiresAt: at(14).addingTimeInterval(5 * days), now: at(14),
                              certificateChanged: true, calendar: calendar))
    }

    /// Review M5: the on-device reminder comes after the refresh would have happened, never at the
    /// same time (with "1 day before", 24 h before expiry fired at every cycle).
    @Test func reminderLeadIsHalfTheRefreshWindow() {
        #expect(RefreshPolicy.reminderLead(threshold: 1 * days) == 12 * 3600)
        #expect(RefreshPolicy.reminderLead(threshold: 2 * days) == 24 * 3600)
        #expect(RefreshPolicy.reminderLead(threshold: 3 * days) == 24 * 3600)
    }

    /// No setting may let an app expire: under 12 h left, it's refreshed anyway.
    @Test func urgentAppsAlwaysGo() {
        let policy = RefreshPolicy(pausedUntil: .distantFuture, acOnly: true, onBattery: true, preferredHours: .night)
        #expect(policy.allows(expiresAt: at(14).addingTimeInterval(11 * 3600), now: at(14), calendar: calendar))
        #expect(!policy.allows(expiresAt: at(14).addingTimeInterval(13 * 3600), now: at(14), calendar: calendar))
    }
}
