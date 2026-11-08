import Foundation
import Testing
@testable import XSideCore

@Suite("InAppStatus")
struct InAppStatusTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    let day: TimeInterval = 86_400

    func installation(installedAt: Date, lastCheckIn: Date? = nil, inApp: InAppSettings? = nil) -> Installation {
        Installation(deviceID: "d", installedAt: installedAt, expiresAt: installedAt.addingTimeInterval(7 * 86_400),
                     inApp: inApp, lastCheckIn: lastCheckIn)
    }

    // MARK: Reachability

    @Test func neverCheckedInIsNeverConnected() {
        #expect(ReachabilityStatus.of(installation: installation(installedAt: t0), now: at(10)) == .neverConnected)
    }

    @Test func recentCheckInIsJoinable() {
        let i = installation(installedAt: t0, lastCheckIn: at(day))
        #expect(ReachabilityStatus.of(installation: i, now: at(3 * day)) == .joinable(lastSeen: at(day)))
        // A check-in a little in the future (clock skew) is still recent.
        #expect(ReachabilityStatus.of(installation: i, now: at(day - 30)) == .joinable(lastSeen: at(day)))
    }

    @Test func oldCheckInIsNotSeenSince() {
        let i = installation(installedAt: t0, lastCheckIn: at(day))
        let limit = at(day + ReachabilityStatus.recentWindow)
        #expect(ReachabilityStatus.of(installation: i, now: limit) == .joinable(lastSeen: at(day)))
        #expect(ReachabilityStatus.of(installation: i, now: limit.addingTimeInterval(1)) == .notSeenSince(at(day)))
    }

    // MARK: Delivery of the Mac's changes

    @Test func noSettingsMeansNothingToTell() {
        #expect(SettingsDelivery.of(installation: installation(installedAt: t0)) == .nothing)
    }

    @Test func onlyPhoneChangesMeanNothingToTell() {
        var s = InAppSettings.defaults(reminder: true, at: t0)
        for kp in [\InAppSettings.showValidity, \.alertLate, \.refreshCard, \.reminder, \.autoRefresh] {
            s = s.setting(kp, to: true, at: at(5), by: .device)
        }
        s = s.setting(\.language, to: .fr, at: at(5), by: .device)
        #expect(SettingsDelivery.of(installation: installation(installedAt: t0, inApp: s)) == .nothing)
    }

    @Test func macEditAfterTheSigningWithoutCheckInIsPending() {
        let s = InAppSettings.defaults(reminder: true, at: t0).setting(\.reminder, to: false, at: at(100), by: .mac)
        #expect(SettingsDelivery.of(installation: installation(installedAt: t0, inApp: s)) == .pending(since: at(100)))
        // A check-in before the edit doesn't deliver it.
        let i = installation(installedAt: t0, lastCheckIn: at(50), inApp: s)
        #expect(SettingsDelivery.of(installation: i) == .pending(since: at(100)))
    }

    @Test func checkInAfterTheEditAppliesIt() {
        let s = InAppSettings.defaults(reminder: true, at: t0).setting(\.reminder, to: false, at: at(100), by: .mac)
        let i = installation(installedAt: t0, lastCheckIn: at(200), inApp: s)
        #expect(SettingsDelivery.of(installation: i) == .applied(at(200)))
    }

    @Test func signingAfterTheEditWritesItButDoesntConfirmIt() {
        let s = InAppSettings.defaults(reminder: true, at: t0).setting(\.reminder, to: false, at: at(100), by: .mac)
        let i = installation(installedAt: at(300), lastCheckIn: at(50), inApp: s)
        #expect(SettingsDelivery.of(installation: i) == .sentWithSigning(at(300)))
        // A fresh install: its Mac values went with it.
        let fresh = installation(installedAt: t0, inApp: InAppSettings.defaults(reminder: true, at: t0))
        #expect(SettingsDelivery.of(installation: fresh) == .sentWithSigning(t0))
    }

    @Test func theNewestMacEditDecides() {
        let s = InAppSettings.defaults(reminder: true, at: t0)
            .setting(\.reminder, to: false, at: at(100), by: .mac)
            .setting(\.language, to: .en, at: at(400), by: .mac)
        #expect(SettingsDelivery.of(installation: installation(installedAt: t0, lastCheckIn: at(200), inApp: s))
                == .pending(since: at(400)))
    }

    @Test func aPhoneChangeOverridingTheEditLeavesNothingPending() {
        // The Mac turned the reminder off, the phone turned it back on later: the merge kept the
        // phone's, and the Mac's other fields were delivered by the check-in that brought it.
        let s = InAppSettings.defaults(reminder: true, at: t0)
            .setting(\.reminder, to: true, at: at(150), by: .device)
        let i = installation(installedAt: t0, lastCheckIn: at(150), inApp: s)
        #expect(SettingsDelivery.of(installation: i) == .applied(at(150)))
    }

    // MARK: Draft adopted by every device of a run

    @Test func adoptingStampsOnlyTheFieldsThatChange() {
        let device = InAppSettings.defaults(reminder: true, at: t0)
            .setting(\.refreshCard, to: false, at: at(10), by: .device)
        let draft = InAppSettings.defaults(reminder: false, at: t0)
            .setting(\.refreshCard, to: false, at: at(5), by: .device)
        let result = device.adopting(draft, at: at(100), by: .mac)
        #expect(result.reminder == Field(value: false, changedAt: at(100), changedBy: .mac))
        #expect(result.refreshCard == device.refreshCard) // same value: untouched
        #expect(result.showValidity == device.showValidity)
        #expect(result.language == device.language)
    }

    @Test func lastUsedMergesEveryDevice() {
        let a = InAppSettings.defaults(reminder: true, at: t0).setting(\.language, to: .fr, at: at(10), by: .device)
        let b = InAppSettings.defaults(reminder: true, at: t0).setting(\.reminder, to: false, at: at(20), by: .mac)
        let list = [installation(installedAt: t0, inApp: a), installation(installedAt: t0),
                    installation(installedAt: t0, inApp: b)]
        let used = InAppSettings.lastUsed(in: list)
        #expect(used?.language.value == .fr)
        #expect(used?.reminder.value == false)
        #expect(InAppSettings.lastUsed(in: [installation(installedAt: t0)]) == nil)
    }

    // MARK: Features choice

    @Test func perAppFeaturesChoiceWinsOverTheDefault() {
        #expect(InstallOptions().resolvedWithoutXSideFeatures(default: true))
        #expect(!InstallOptions().resolvedWithoutXSideFeatures(default: false))
        #expect(!InstallOptions(withoutXSideFeatures: false).resolvedWithoutXSideFeatures(default: true))
        #expect(InstallOptions(withoutXSideFeatures: true).resolvedWithoutXSideFeatures(default: false))
    }
}

@Suite("InstallSummary")
struct InstallSummaryTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func appAsItCameWithDefaults() {
        let s = InstallSummary.lines(options: InstallOptions(), inApp: InAppSettings.defaults(reminder: true, at: t0),
                                     withoutXSideFeatures: false, openAppAfter: true, openTrustPage: true,
                                     offersKeychain: false)
        #expect(s.install == [.appUnchanged, .openAppAfter(true), .openTrustPage(true)])
        #expect(s.inApp == [.xsideFeatures(true), .messages(.all), .showValidity(true), .alertLate(true),
                            .refreshCard(true), .reminder(true), .language(.automatic), .autoRefresh(true)])
    }

    @Test func everyCustomizationIsListed() {
        let o = InstallOptions(displayName: "Tube", customBundleID: "a.b", version: "2.0", iconPath: "x.png",
                               fileSharing: true, iPadFullScreen: true, proMotion: true, minimumOSVersion: "15.0",
                               shareKeychain: true)
        let s = InstallSummary.lines(options: o, inApp: InAppSettings.defaults(reminder: true, at: t0),
                                     withoutXSideFeatures: false, openAppAfter: false, openTrustPage: true,
                                     offersKeychain: true)
        // The Trust page only opens with the app: not listed when the app isn't opened.
        #expect(s.install == [.displayName("Tube"), .bundleID("a.b"), .version("2.0"), .customIcon,
                              .fileSharing, .iPadFullScreen, .proMotion, .minimumOS("15.0"),
                              .shareKeychain(true), .openAppAfter(false)])
    }

    @Test func keychainListedWhenOfferedEvenOff() {
        let s = InstallSummary.lines(options: InstallOptions(), inApp: InAppSettings.defaults(reminder: true, at: t0),
                                     withoutXSideFeatures: false, openAppAfter: true, openTrustPage: false,
                                     offersKeychain: true)
        #expect(s.install == [.appUnchanged, .shareKeychain(false), .openAppAfter(true), .openTrustPage(false)])
    }

    @Test func withoutFeaturesListsOnlyThat() {
        let s = InstallSummary.lines(options: InstallOptions(), inApp: InAppSettings.defaults(reminder: true, at: t0),
                                     withoutXSideFeatures: true, openAppAfter: true, openTrustPage: true,
                                     offersKeychain: false)
        #expect(s.inApp == [.xsideFeatures(false)])
    }

    @Test func messagesFollowTheSwitches() {
        let inApp = InAppSettings.defaults(reminder: true, at: t0).applying(level: .essentials, at: t0, by: .mac)
            .setting(\.language, to: .en, at: t0, by: .mac)
        let s = InstallSummary.lines(options: InstallOptions(), inApp: inApp, withoutXSideFeatures: false,
                                     openAppAfter: true, openTrustPage: true, offersKeychain: false)
        #expect(s.inApp == [.xsideFeatures(true), .messages(.essentials), .showValidity(false), .alertLate(true),
                            .refreshCard(false), .reminder(true), .language(.en), .autoRefresh(true)])
    }
}
