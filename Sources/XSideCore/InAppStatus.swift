import Foundation

/// Whether the app on a device talks to XSide through the local network channel, as the Mac
/// knows it from the check-ins (shown per device in the install window and Settings > Mes apps).
public enum ReachabilityStatus: Equatable, Sendable {
    /// The app is open on the device: it holds a watch, so a Mac change is written to it at once
    /// (device feedback 4), or (no watch: an older dylib, or the watch couldn't open) it checked in
    /// within `openWindow(pollEvery:)`, polling every 15 s (45 s in Low Power Mode) (device feedback 3,
    /// E3; feedback 5, G3).
    case openNow(lastSeen: Date)
    /// Checked in recently: the app checks in at each launch, a Mac change arrives at its next opening.
    case joinable(lastSeen: Date)
    /// Never checked in: the phone hasn't allowed the local network yet (a first tap on
    /// "Rafraîchir" in the app asks for it). Mac changes arrive at the next signing.
    case neverConnected
    /// Signed by an XSide before 1.1 (no channel secret): the app has nothing to talk to XSide
    /// with, nor a Refresh to tap, until its next refresh brings them (final review minor 3).
    case channelComing
    /// Its last check-in is old: the app may not have been opened, or isn't on the Mac's network.
    case notSeenSince(Date)
    /// Signed without XSide's features: nothing in the app talks to XSide.
    case noFeatures

    /// How long a check-in counts as recent: a week, about one refresh cycle of a free account.
    public static let recentWindow: TimeInterval = 7 * 86_400
    /// The phone's foreground poll interval when its check-in doesn't say (older dylibs): 15 s.
    public static let defaultPollInterval: TimeInterval = 15
    /// The longest poll interval a check-in may claim: a bigger one counts as this, so no check-in
    /// keeps the app "open" for long after it left the screen.
    public static let maxPollInterval: TimeInterval = 120
    /// What a poll can lag behind its interval: the phone's 5 s tick and its 2 s tolerance, plus
    /// the time to find the Mac and connect (device feedback 5, G3).
    public static let pollMargin: TimeInterval = 10

    /// How long after a check-in the app counts as open when it holds no watch: one poll interval
    /// (the one the check-in stated, else 15 s; at least 15, at most 120) plus `pollMargin`. So an
    /// app polling every 45 s in Low Power Mode stays "open" between its polls (device feedback 5,
    /// G3), and the status still flips back within about one poll of the app leaving the screen
    /// (device feedback 4: it said "open" long after).
    public static func openWindow(pollEvery: TimeInterval? = nil) -> TimeInterval {
        min(max(pollEvery ?? defaultPollInterval, defaultPollInterval), maxPollInterval) + pollMargin
    }

    /// The app is open on the device right now: it holds a watch, or (polling) the Mac saw a check-in
    /// within `openWindow(pollEvery:)`. A date ahead of `now` (the Mac's clock moved back) counts
    /// only as far.
    public static func isLive(watching: Bool, lastSeen: Date?, now: Date, pollEvery: TimeInterval? = nil) -> Bool {
        if watching { return true }
        guard let lastSeen else { return false }
        let since = now.timeIntervalSince(lastSeen)
        let window = openWindow(pollEvery: pollEvery)
        return since <= window && since >= -window
    }

    /// `lastSeen`: the last check-in the Mac saw in this run (those that change nothing aren't
    /// written to the library, so its date can lag by up to a minute).
    /// `watching`: the app holds a watch open now (the Mac writes its changes on it as they happen).
    /// `pollEvery`: the poll interval the last check-in stated (nil: not said, 15 s).
    public static func of(installation: Installation, now: Date, lastSeen: Date? = nil,
                          watching: Bool = false, pollEvery: TimeInterval? = nil) -> ReachabilityStatus {
        if installation.withoutXSideFeatures == true { return .noFeatures }
        if installation.channelSecret == nil { return .channelComing }
        if watching { return .openNow(lastSeen: now) }
        let seen = [installation.lastCheckIn, lastSeen].compactMap { $0 }.max()
        guard let last = seen else { return .neverConnected }
        let since = now.timeIntervalSince(last)
        if isLive(watching: false, lastSeen: last, now: now, pollEvery: pollEvery) { return .openNow(lastSeen: last) }
        return since <= recentWindow ? .joinable(lastSeen: installation.lastCheckIn ?? last) : .notSeenSince(last)
    }
}

/// Where the Mac's changes to an installation's in-app settings stand. The Mac never claims a
/// setting is active on the phone before a check-in confirmed it.
///
/// Only the Mac user's edits count (`Installation.lastMacEdit`): values seeded or defaulted by
/// XSide are stamped by the Mac but nobody changed them. An edit the phone has since overridden
/// on every field it touched (no field still stamped by the Mac at or after it) is the phone's
/// now: nothing to tell. A check-in at or after the edit delivered it: the phone reports its
/// values, the merge keeps the Mac's newer fields and the reply hands them to the phone, which
/// applies them at once.
public enum SettingsDelivery: Equatable, Sendable {
    /// No Mac edit waiting or to confirm (none made, superseded, or no XSide features).
    case nothing
    /// Edited on the Mac after the last signing and the last check-in: goes at the app's next
    /// opening (check-in) or its next refresh (signing). `since`: the edit.
    case pending(since: Date)
    /// Written into the app by the signing of that date, not confirmed by a check-in since.
    case sentWithSigning(Date)
    /// Delivered: the latest check-in (at or after the edit) is of that date. Only the latest one
    /// is known, so it's worded as "confirmed at the last connection".
    case confirmed(lastCheckIn: Date)

    public static func of(installation: Installation) -> SettingsDelivery {
        guard installation.withoutXSideFeatures != true, let s = installation.inApp,
              let edit = installation.lastMacEdit else { return .nothing }
        let macDates = [s.showValidity.macDate, s.alertLate.macDate, s.refreshCard.macDate, s.reminder.macDate,
                        s.language.macDate, s.autoRefresh.macDate].compactMap { $0 }
        guard macDates.contains(where: { $0 >= edit }) else { return .nothing }
        if let checkIn = installation.lastCheckIn, checkIn >= edit { return .confirmed(lastCheckIn: checkIn) }
        if installation.installedAt >= edit { return .sentWithSigning(installation.installedAt) }
        return .pending(since: edit)
    }
}

extension SettingsDelivery {
    /// The fields the Mac changed since the app last got its settings (its last check-in, or the
    /// signing that wrote them), in the settings' order: what a pending line names.
    public static func pendingFields(of installation: Installation) -> [InAppField] {
        guard let s = installation.inApp else { return [] }
        let delivered = max(installation.lastCheckIn ?? .distantPast, installation.installedAt)
        func pending<V>(_ f: Field<V>) -> Bool { f.macDate.map { $0 > delivered } ?? false }
        return InAppField.allCases.filter { field in
            switch field {
            case .showValidity: pending(s.showValidity)
            case .alertLate: pending(s.alertLate)
            case .refreshCard: pending(s.refreshCard)
            case .reminder: pending(s.reminder)
            case .language: pending(s.language)
            case .autoRefresh: pending(s.autoRefresh)
            }
        }
    }
}

private extension Field {
    /// The change date when the Mac made the last change, nil when the device did.
    var macDate: Date? { changedBy == .mac ? changedAt : nil }
}

/// One of the in-app settings, to say which ones the install window's user touched.
public enum InAppField: String, CaseIterable, Sendable {
    case showValidity, alertLate, refreshCard, reminder, language, autoRefresh
}

/// The install window's step ③: the values shown and the fields the user changed there.
public struct InAppDraft: Equatable, Sendable {
    public var settings: InAppSettings
    public var touched: Set<InAppField>

    public init(settings: InAppSettings, touched: Set<InAppField>) {
        self.settings = settings
        self.touched = touched
    }
}

extension InAppSettings {
    /// Copy holding `draft`'s values for `fields`: each of those whose value differs is set and
    /// stamped (`date`, `origin`); one already at the draft's value keeps its own stamp, and the
    /// other fields are left alone. The install window passes the fields its user touched, so a
    /// newer change made on the phone meanwhile is never overwritten by a value merely shown.
    public func adopting(_ draft: InAppSettings, fields: Set<InAppField>, at date: Date,
                         by origin: ChangeOrigin) -> InAppSettings {
        var copy = self
        func adopt<V>(_ field: InAppField, _ keyPath: WritableKeyPath<InAppSettings, Field<V>>) {
            if fields.contains(field), copy[keyPath: keyPath].value != draft[keyPath: keyPath].value {
                copy = copy.setting(keyPath, to: draft[keyPath: keyPath].value, at: date, by: origin)
            }
        }
        adopt(.showValidity, \.showValidity)
        adopt(.alertLate, \.alertLate)
        adopt(.refreshCard, \.refreshCard)
        adopt(.reminder, \.reminder)
        adopt(.language, \.language)
        adopt(.autoRefresh, \.autoRefresh)
        return copy
    }

    /// The fields whose value differs from `other`'s (stamps aside): what an edit changed.
    public func fields(differingFrom other: InAppSettings) -> Set<InAppField> {
        var result: Set<InAppField> = []
        if showValidity.value != other.showValidity.value { result.insert(.showValidity) }
        if alertLate.value != other.alertLate.value { result.insert(.alertLate) }
        if refreshCard.value != other.refreshCard.value { result.insert(.refreshCard) }
        if reminder.value != other.reminder.value { result.insert(.reminder) }
        if language.value != other.language.value { result.insert(.language) }
        if autoRefresh.value != other.autoRefresh.value { result.insert(.autoRefresh) }
        return result
    }

    /// The app's last-used values: every device's settings merged field by field (newest change
    /// wins). Nil when no installation has settings. Prefills step ③ of the install window.
    public static func lastUsed(in installations: [Installation]) -> InAppSettings? {
        installations.compactMap(\.inApp).reduce(nil) { result, next in result.map { merge($0, next) } ?? next }
    }
}

extension InstallOptions {
    /// Whether this app installs without XSide's features: its own choice when it made one, else
    /// the Mac's default (Settings > Module XSide dans les apps).
    public func resolvedWithoutXSideFeatures(default fallback: Bool) -> Bool {
        withoutXSideFeatures ?? fallback
    }
}

/// Every option an install will apply, as shown in step ① of the install window when the
/// options aren't reviewed step by step. Not localized: the window words each line.
public enum InstallSummary {
    public enum Line: Equatable, Sendable {
        /// Nothing customized: name, identifier, version, icon and capabilities as in the .ipa.
        case appUnchanged
        case displayName(String), bundleID(String), version(String), customIcon
        case fileSharing, iPadFullScreen, proMotion, minimumOS(String)
        case shareKeychain(Bool)
        /// iPhone Duo compatibility: the devices getting it (empty: none).
        case duoCompatibility([String])
        /// "Simulate signed-out iCloud": the devices getting it (empty: none).
        case iCloudSignedOut([String])
        case openAppAfter(Bool), openTrustPage(Bool)
        case xsideFeatures(Bool)
        case messages(MessageLevel)
        case showValidity(Bool), alertLate(Bool), refreshCard(Bool), reminder(Bool)
        case language(MessageLanguage)
        case autoRefresh(Bool)
    }

    /// `install`: the app and what happens after the install; `fixes`: the compatibility fixes
    /// (iPhone Duo, signed-out iCloud; edited in step ② too, listed apart); `inApp`: the XSide module in the app (only
    /// "without XSide features" when it has none). `offersKeychain`: the app asks for shared
    /// keychain groups (the option exists only then). The Trust page is listed only when the app
    /// is opened after the install (it can't open otherwise). `duoDevices`: the names of the
    /// devices getting iPhone Duo compatibility; `offersDuo`: a Duo is among the targets (the line
    /// then shows even when none gets it). `iCloudDevices` / `offersICloud`: the same for
    /// "Simulate signed-out iCloud" (offered: the app uses iCloud).
    public static func lines(options o: InstallOptions, inApp s: InAppSettings, withoutXSideFeatures: Bool,
                             openAppAfter: Bool, openTrustPage: Bool,
                             offersKeychain: Bool, duoDevices: [String] = [],
                             offersDuo: Bool = false, iCloudDevices: [String] = [],
                             offersICloud: Bool = false) -> (install: [Line], fixes: [Line], inApp: [Line]) {
        var install: [Line] = []
        if let v = o.displayName { install.append(.displayName(v)) }
        if let v = o.customBundleID { install.append(.bundleID(v)) }
        if let v = o.version { install.append(.version(v)) }
        if o.iconPath?.isEmpty == false { install.append(.customIcon) }
        if o.fileSharing { install.append(.fileSharing) }
        if o.iPadFullScreen { install.append(.iPadFullScreen) }
        if o.proMotion { install.append(.proMotion) }
        if let v = o.minimumOSVersion { install.append(.minimumOS(v)) }
        if install.isEmpty { install.append(.appUnchanged) }
        if offersKeychain { install.append(.shareKeychain(o.shareKeychain)) }
        var fixes: [Line] = []
        if offersDuo || !duoDevices.isEmpty { fixes.append(.duoCompatibility(duoDevices)) }
        if offersICloud || !iCloudDevices.isEmpty { fixes.append(.iCloudSignedOut(iCloudDevices)) }
        install.append(.openAppAfter(openAppAfter))
        if openAppAfter { install.append(.openTrustPage(openTrustPage)) }

        guard !withoutXSideFeatures else { return (install, fixes, [.xsideFeatures(false)]) }
        let inApp: [Line] = [.xsideFeatures(true), .messages(s.derivedLevel), .showValidity(s.showValidity.value),
                             .alertLate(s.alertLate.value), .refreshCard(s.refreshCard.value),
                             .reminder(s.reminder.value), .language(s.language.value),
                             .autoRefresh(s.autoRefresh.value)]
        return (install, fixes, inApp)
    }
}
