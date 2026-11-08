import Foundation
import Testing
@testable import XSideCore

@Suite("InAppStatus")
struct InAppStatusTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    let day: TimeInterval = 86_400

    func installation(installedAt: Date, lastCheckIn: Date? = nil, inApp: InAppSettings? = nil,
                      secret: Data? = Data([1])) -> Installation {
        Installation(deviceID: "d", installedAt: installedAt, expiresAt: installedAt.addingTimeInterval(7 * 86_400),
                     inApp: inApp, channelSecret: secret, lastCheckIn: lastCheckIn)
    }

    // MARK: Reachability

    @Test func neverCheckedInIsNeverConnected() {
        #expect(ReachabilityStatus.of(installation: installation(installedAt: t0), now: at(10)) == .neverConnected)
    }

    /// Final review minor 3: signed by an earlier XSide (no channel secret), the app has no Refresh
    /// to tap yet; the channel comes with its next refresh.
    @Test func earlierBuildWaitsForTheNextRefresh() {
        #expect(ReachabilityStatus.of(installation: installation(installedAt: t0, secret: nil), now: at(10)) == .channelComing)
    }

    @Test func recentCheckInIsJoinable() {
        let i = installation(installedAt: t0, lastCheckIn: at(day))
        #expect(ReachabilityStatus.of(installation: i, now: at(3 * day)) == .joinable(lastSeen: at(day)))
        // A check-in a little in the future (clock skew) is recent: the app is open (E3).
        #expect(ReachabilityStatus.of(installation: i, now: at(day - 30)) == .openNow(lastSeen: at(day)))
    }

    @Test func oldCheckInIsNotSeenSince() {
        let i = installation(installedAt: t0, lastCheckIn: at(day))
        let limit = at(day + ReachabilityStatus.recentWindow)
        #expect(ReachabilityStatus.of(installation: i, now: limit) == .joinable(lastSeen: at(day)))
        #expect(ReachabilityStatus.of(installation: i, now: limit.addingTimeInterval(1)) == .notSeenSince(at(day)))
    }

    /// Device feedback 3, E3: an app that checked in within the last 45 s is open on the device
    /// (it polls every 15 s while in front), so the Mac's changes arrive live. The Mac's memory of
    /// the last check-in (`lastSeen`, quiet check-ins aren't written) counts as well.
    @Test func aCheckInWithinSecondsIsTheAppOpen() {
        let i = installation(installedAt: t0, lastCheckIn: at(100))
        #expect(ReachabilityStatus.of(installation: i, now: at(130)) == .openNow(lastSeen: at(100)))
        #expect(ReachabilityStatus.of(installation: i, now: at(145)) == .openNow(lastSeen: at(100)))
        #expect(ReachabilityStatus.of(installation: i, now: at(146)) == .joinable(lastSeen: at(100)))
        #expect(ReachabilityStatus.of(installation: i, now: at(200), lastSeen: at(190)) == .openNow(lastSeen: at(190)))
        #expect(ReachabilityStatus.of(installation: i, now: at(200), lastSeen: at(50)) == .joinable(lastSeen: at(100)))
        let never = installation(installedAt: t0)
        #expect(ReachabilityStatus.of(installation: never, now: at(200), lastSeen: at(190)) == .openNow(lastSeen: at(190)))
        var bare = i
        bare.withoutXSideFeatures = true
        #expect(ReachabilityStatus.of(installation: bare, now: at(130), lastSeen: at(129)) == .noFeatures)
    }

    // MARK: Delivery of the Mac's changes

    func edited(_ s: InAppSettings, lastMacEdit: Date?, installedAt: Date, lastCheckIn: Date? = nil,
                withoutFeatures: Bool? = nil) -> Installation {
        var i = installation(installedAt: installedAt, lastCheckIn: lastCheckIn, inApp: s)
        i.lastMacEdit = lastMacEdit
        i.withoutXSideFeatures = withoutFeatures
        return i
    }

    @Test func noSettingsMeansNothingToTell() {
        #expect(SettingsDelivery.of(installation: installation(installedAt: t0)) == .nothing)
    }

    /// Seeded or defaulted values are stamped by the Mac but nobody changed them: nothing pending.
    @Test func untouchedInstallationsHaveNothingToTell() {
        let s = InAppSettings.defaults(reminder: true, at: at(100))
        #expect(SettingsDelivery.of(installation: installation(installedAt: t0, inApp: s)) == .nothing)
        #expect(SettingsDelivery.of(installation: installation(installedAt: t0, lastCheckIn: at(50), inApp: s)) == .nothing)
    }

    @Test func macEditAfterTheSigningWithoutCheckInIsPending() {
        let s = InAppSettings.defaults(reminder: true, at: t0).setting(\.reminder, to: false, at: at(100), by: .mac)
        #expect(SettingsDelivery.of(installation: edited(s, lastMacEdit: at(100), installedAt: t0)) == .pending(since: at(100)))
        // A check-in before the edit doesn't deliver it.
        #expect(SettingsDelivery.of(installation: edited(s, lastMacEdit: at(100), installedAt: t0, lastCheckIn: at(50)))
                == .pending(since: at(100)))
    }

    /// Device feedback 3, E3: a pending line names what is pending: the fields the Mac changed
    /// since the app last got its settings (check-in or signing), in the settings' order.
    @Test func pendingFieldsAreTheMacsChangesSinceTheLastDelivery() {
        let s = InAppSettings.defaults(reminder: true, at: t0)
            .setting(\.reminder, to: false, at: at(100), by: .mac)
            .setting(\.autoRefresh, to: false, at: at(110), by: .mac)
            .setting(\.showValidity, to: false, at: at(120), by: .device)
        #expect(SettingsDelivery.pendingFields(of: edited(s, lastMacEdit: at(110), installedAt: t0, lastCheckIn: at(50)))
                == [.reminder, .autoRefresh])
        #expect(SettingsDelivery.pendingFields(of: edited(s, lastMacEdit: at(110), installedAt: t0, lastCheckIn: at(105)))
                == [.autoRefresh])
        #expect(SettingsDelivery.pendingFields(of: edited(s, lastMacEdit: at(110), installedAt: at(300))).isEmpty)
    }

    @Test func checkInAfterTheEditConfirmsIt() {
        let s = InAppSettings.defaults(reminder: true, at: t0).setting(\.reminder, to: false, at: at(100), by: .mac)
        #expect(SettingsDelivery.of(installation: edited(s, lastMacEdit: at(100), installedAt: t0, lastCheckIn: at(200)))
                == .confirmed(lastCheckIn: at(200)))
    }

    @Test func signingAfterTheEditWritesItButDoesntConfirmIt() {
        let s = InAppSettings.defaults(reminder: true, at: t0).setting(\.reminder, to: false, at: at(100), by: .mac)
        #expect(SettingsDelivery.of(installation: edited(s, lastMacEdit: at(100), installedAt: at(300), lastCheckIn: at(50)))
                == .sentWithSigning(at(300)))
    }

    @Test func aPhoneChangeOverridingTheEditLeavesNothingToTell() {
        // The Mac turned the reminder off, the phone turned it back on later: the phone's stands.
        let s = InAppSettings.defaults(reminder: true, at: t0).setting(\.reminder, to: true, at: at(150), by: .device)
        #expect(SettingsDelivery.of(installation: edited(s, lastMacEdit: at(100), installedAt: t0)) == .nothing)
    }

    @Test func withoutFeaturesThereIsNothingToTellNorToReach() {
        let s = InAppSettings.defaults(reminder: true, at: t0).setting(\.reminder, to: false, at: at(100), by: .mac)
        let i = edited(s, lastMacEdit: at(100), installedAt: t0, lastCheckIn: at(50), withoutFeatures: true)
        #expect(SettingsDelivery.of(installation: i) == .nothing)
        #expect(ReachabilityStatus.of(installation: i, now: at(60)) == .noFeatures)
    }

    // MARK: Draft adopted by every device of a run

    @Test func adoptingStampsOnlyTheFieldsThatChange() {
        let device = InAppSettings.defaults(reminder: true, at: t0)
            .setting(\.refreshCard, to: false, at: at(10), by: .device)
        let draft = InAppSettings.defaults(reminder: false, at: t0)
            .setting(\.refreshCard, to: false, at: at(5), by: .device)
        let result = device.adopting(draft, fields: Set(InAppField.allCases), at: at(100), by: .mac)
        #expect(result.reminder == Field(value: false, changedAt: at(100), changedBy: .mac))
        #expect(result.refreshCard == device.refreshCard) // same value: untouched
        #expect(result.showValidity == device.showValidity)
        #expect(result.language == device.language)
    }

    /// A field the phone changed after the window opened, and the user didn't touch, keeps the phone's value.
    @Test func adoptingOnlyTheTouchedFieldsKeepsTheNewerPhoneChanges() {
        let prefill = InAppSettings.defaults(reminder: true, at: t0)
        var draft = prefill.setting(\.language, to: .en, at: at(20), by: .mac) // touched in step 3
        draft = draft.setting(\.refreshCard, to: true, at: at(20), by: .mac)  // unchanged value
        let phone = prefill.setting(\.showValidity, to: false, at: at(30), by: .device) // after the window opened
        let result = phone.adopting(draft, fields: [.language], at: at(100), by: .mac)
        #expect(result.language == Field(value: .en, changedAt: at(100), changedBy: .mac))
        #expect(result.showValidity == phone.showValidity)
        #expect(phone.adopting(draft, fields: [], at: at(100), by: .mac) == phone)
    }

    @Test func fieldsWhoseValueDiffers() {
        let a = InAppSettings.defaults(reminder: true, at: t0)
        let b = a.setting(\.reminder, to: false, at: at(1), by: .mac).setting(\.language, to: .fr, at: at(1), by: .mac)
            .setting(\.alertLate, to: true, at: at(1), by: .mac) // restamped, same value
        #expect(b.fields(differingFrom: a) == [.reminder, .language])
        #expect(a.fields(differingFrom: a).isEmpty)
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

    @Test func newerMacEditIsKeptThroughASigning() {
        var current = installation(installedAt: t0)
        current.lastMacEdit = at(100)
        var signed = installation(installedAt: at(200))
        #expect(signed.keepingChannelState(of: current).lastMacEdit == at(100))
        signed.lastMacEdit = at(150)
        #expect(signed.keepingChannelState(of: current).lastMacEdit == at(150))
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
