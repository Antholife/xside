import Foundation

/// Whether the app on a device talks to XSide through the local network channel, as the Mac
/// knows it from the check-ins (shown per device in the install window and "Réglages XSide…").
public enum ReachabilityStatus: Equatable, Sendable {
    /// Checked in recently: the app checks in at each launch, a Mac change arrives at its next opening.
    case joinable(lastSeen: Date)
    /// Never checked in: the phone hasn't allowed the local network yet (a first tap on
    /// "Rafraîchir" in the app asks for it). Mac changes arrive at the next signing.
    case neverConnected
    /// Its last check-in is old: the app may not have been opened, or isn't on the Mac's network.
    case notSeenSince(Date)

    /// How long a check-in counts as recent: a week, about one refresh cycle of a free account.
    public static let recentWindow: TimeInterval = 7 * 86_400

    public static func of(installation: Installation, now: Date) -> ReachabilityStatus {
        guard let last = installation.lastCheckIn else { return .neverConnected }
        return now.timeIntervalSince(last) <= recentWindow ? .joinable(lastSeen: last) : .notSeenSince(last)
    }
}

/// Where the Mac's changes to an installation's in-app settings stand. The Mac never claims a
/// setting is active on the phone before a check-in confirmed it.
///
/// The Mac's latest change is the newest `changedAt` among the fields last changed by the Mac
/// (a field the phone changed since belongs to the phone and is no longer the Mac's to deliver).
/// A check-in at or after that date delivered it: the phone reports its values, the merge keeps
/// the Mac's newer fields and the reply hands them to the phone, which applies them at once.
public enum SettingsDelivery: Equatable, Sendable {
    /// No field holds a Mac change (no settings yet, or the phone changed every one since).
    case nothing
    /// Changed on the Mac after the last signing and the last check-in: goes at the app's next
    /// opening (check-in) or its next refresh (signing). `since`: the latest Mac change.
    case pending(since: Date)
    /// Written into the app by the signing of that date, not confirmed by a check-in since.
    case sentWithSigning(Date)
    /// Confirmed by the check-in of that date.
    case applied(Date)

    public static func of(installation: Installation) -> SettingsDelivery {
        guard let s = installation.inApp else { return .nothing }
        let macDates = [s.showValidity.macDate, s.alertLate.macDate, s.refreshCard.macDate, s.reminder.macDate,
                        s.language.macDate, s.autoRefresh.macDate].compactMap { $0 }
        guard let latest = macDates.max() else { return .nothing }
        if let checkIn = installation.lastCheckIn, checkIn >= latest { return .applied(checkIn) }
        if installation.installedAt >= latest { return .sentWithSigning(installation.installedAt) }
        return .pending(since: latest)
    }
}

private extension Field {
    /// The change date when the Mac made the last change, nil when the device did.
    var macDate: Date? { changedBy == .mac ? changedAt : nil }
}

extension InAppSettings {
    /// Copy holding `draft`'s values: each field whose value differs is set and stamped
    /// (`date`, `origin`); a field already at the draft's value keeps its own stamp. This is how
    /// the install window gives every device of a run the same values without restamping what
    /// didn't change there.
    public func adopting(_ draft: InAppSettings, at date: Date, by origin: ChangeOrigin) -> InAppSettings {
        var copy = self
        func adopt<V>(_ keyPath: WritableKeyPath<InAppSettings, Field<V>>) {
            if copy[keyPath: keyPath].value != draft[keyPath: keyPath].value {
                copy = copy.setting(keyPath, to: draft[keyPath: keyPath].value, at: date, by: origin)
            }
        }
        adopt(\.showValidity)
        adopt(\.alertLate)
        adopt(\.refreshCard)
        adopt(\.reminder)
        adopt(\.language)
        adopt(\.autoRefresh)
        return copy
    }

    /// The app's last-used values: every device's settings merged field by field (newest change
    /// wins). Nil when no installation has settings. Prefills step ③ of the install window.
    public static func lastUsed(in installations: [Installation]) -> InAppSettings? {
        installations.compactMap(\.inApp).reduce(nil) { result, next in result.map { merge($0, next) } ?? next }
    }
}

extension InstallOptions {
    /// Whether this app installs without XSide's features: its own choice when it made one, else
    /// the Mac's default (Settings > XSide dans les apps).
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
        case openAppAfter(Bool), openTrustPage(Bool)
        case xsideFeatures(Bool)
        case messages(MessageLevel)
        case showValidity(Bool), alertLate(Bool), refreshCard(Bool), reminder(Bool)
        case language(MessageLanguage)
        case autoRefresh(Bool)
    }

    /// `install`: the app and what happens after the install; `inApp`: XSide in the app (only
    /// "without XSide features" when it has none). `offersKeychain`: the app asks for shared
    /// keychain groups (the option exists only then). The Trust page is listed only when the app
    /// is opened after the install (it can't open otherwise).
    public static func lines(options o: InstallOptions, inApp s: InAppSettings, withoutXSideFeatures: Bool,
                             openAppAfter: Bool, openTrustPage: Bool,
                             offersKeychain: Bool) -> (install: [Line], inApp: [Line]) {
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
        install.append(.openAppAfter(openAppAfter))
        if openAppAfter { install.append(.openTrustPage(openTrustPage)) }

        guard !withoutXSideFeatures else { return (install, [.xsideFeatures(false)]) }
        let inApp: [Line] = [.xsideFeatures(true), .messages(s.derivedLevel), .showValidity(s.showValidity.value),
                             .alertLate(s.alertLate.value), .refreshCard(s.refreshCard.value),
                             .reminder(s.reminder.value), .language(s.language.value),
                             .autoRefresh(s.autoRefresh.value)]
        return (install, inApp)
    }
}
