import Foundation

/// How much XSide shows inside an app, as a summary of the four switches (see
/// `InAppSettings.derivedLevel`): never stored, so it can't disagree with them. `essentials` =
/// only the problem alerts (late pill, reminder); `custom` = any other mix.
public enum MessageLevel: String, Codable, Sendable { case all, essentials, none, custom }

/// Language of the dylib's own texts (iOS translates the Settings titles itself).
public enum MessageLanguage: String, Codable, Sendable { case automatic, fr, en }

/// Who made a change: the Mac (XSide) or the device (the dylib / iOS Settings).
public enum ChangeOrigin: String, Codable, Sendable { case mac, device }

/// One setting with the date and origin of its last change, so two copies can be merged
/// field by field without a shared counter.
public struct Field<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var value: Value
    public var changedAt: Date
    public var changedBy: ChangeOrigin

    public init(value: Value, changedAt: Date, changedBy: ChangeOrigin) {
        self.value = value
        self.changedAt = changedAt
        self.changedBy = changedBy
    }

    /// Newest `changedAt` wins; on an exact tie the device's change wins (it is what the person
    /// last touched in front of them).
    static func merge(_ a: Field, _ b: Field) -> Field {
        if a.changedAt != b.changedAt { return a.changedAt > b.changedAt ? a : b }
        if a.changedBy != b.changedBy { return a.changedBy == .device ? a : b }
        return a
    }
}

/// Outcome of the last refresh as the phone reports it.
public struct RefreshOutcome: Codable, Equatable, Sendable {
    public var at: Date
    public var succeeded: Bool
    /// Localization key of the failure reason; nil on success.
    public var reasonKey: String?

    public init(at: Date, succeeded: Bool, reasonKey: String? = nil) {
        self.at = at
        self.succeeded = succeeded
        self.reasonKey = reasonKey
    }
}

/// The XSide-in-app settings of one installation (app x device).
/// (Settings stored by an earlier 1.1 build also had a "level" field: decoding ignores it.)
public struct InAppSettings: Codable, Equatable, Sendable {
    public var showValidity: Field<Bool>
    public var alertLate: Field<Bool>
    public var refreshCard: Field<Bool>
    public var reminder: Field<Bool>
    public var language: Field<MessageLanguage>
    public var autoRefresh: Field<Bool>

    public init(showValidity: Field<Bool>, alertLate: Field<Bool>,
                refreshCard: Field<Bool>, reminder: Field<Bool>, language: Field<MessageLanguage>,
                autoRefresh: Field<Bool>) {
        self.showValidity = showValidity
        self.alertLate = alertLate
        self.refreshCard = refreshCard
        self.reminder = reminder
        self.language = language
        self.autoRefresh = autoRefresh
    }

    /// Mac defaults for a new installation: the reminder is seeded from the global Mac setting,
    /// everything else on (the validity pill too: Anthony, 2026-11-08).
    public static func defaults(reminder: Bool, at: Date) -> InAppSettings {
        func f<V>(_ v: V) -> Field<V> { Field(value: v, changedAt: at, changedBy: .mac) }
        return InAppSettings(showValidity: f(true), alertLate: f(true),
                             refreshCard: f(true), reminder: f(reminder), language: f(.automatic),
                             autoRefresh: f(true))
    }

    /// Field-by-field merge (see `Field.merge`). Symmetric: `merge(a, b) == merge(b, a)`.
    public static func merge(_ a: InAppSettings, _ b: InAppSettings) -> InAppSettings {
        InAppSettings(showValidity: .merge(a.showValidity, b.showValidity),
                      alertLate: .merge(a.alertLate, b.alertLate),
                      refreshCard: .merge(a.refreshCard, b.refreshCard),
                      reminder: .merge(a.reminder, b.reminder),
                      language: .merge(a.language, b.language),
                      autoRefresh: .merge(a.autoRefresh, b.autoRefresh))
    }

    /// "fr" or "en": the language of the plain texts XSide writes into the app at signing (Settings
    /// titles, local network reason), shown when the app has no localization to translate them.
    /// The installation's chosen language, else the Mac's (`macPreferences`: its preferred
    /// languages, most preferred first), else English. The person on the Mac is the phone's owner.
    public func textLanguage(macPreferences: [String]) -> String {
        switch language.value {
        case .fr: return "fr"
        case .en: return "en"
        case .automatic:
            let first = macPreferences.first { $0.hasPrefix("fr") || $0.hasPrefix("en") }
            return first?.hasPrefix("fr") == true ? "fr" : "en"
        }
    }

    /// Copy with one field set and stamped, e.g. `s.setting(\.reminder, to: false, at: now, by: .mac)`.
    public func setting<V>(_ keyPath: WritableKeyPath<InAppSettings, Field<V>>, to value: V,
                           at date: Date, by origin: ChangeOrigin) -> InAppSettings {
        var copy = self
        copy[keyPath: keyPath] = Field(value: value, changedAt: date, changedBy: origin)
        return copy
    }

    // MARK: Level and visibility (spec §1 matrix; each switch decides for itself)

    /// The four switches summed up: all on, only the problem alerts (late pill and reminder), all
    /// off, or any other mix.
    public var derivedLevel: MessageLevel {
        switch (showValidity.value, alertLate.value, refreshCard.value, reminder.value) {
        case (true, true, true, true): .all
        case (false, true, false, true): .essentials
        case (false, false, false, false): .none
        default: .custom
        }
    }

    /// Copy with the four switches set for `level`, each stamped; `custom` changes nothing.
    public func applying(level: MessageLevel, at date: Date, by origin: ChangeOrigin) -> InAppSettings {
        let values: (validity: Bool, late: Bool, card: Bool, reminder: Bool)
        switch level {
        case .all: values = (true, true, true, true)
        case .essentials: values = (false, true, false, true)
        case .none: values = (false, false, false, false)
        case .custom: return self
        }
        return setting(\.showValidity, to: values.validity, at: date, by: origin)
            .setting(\.alertLate, to: values.late, at: date, by: origin)
            .setting(\.refreshCard, to: values.card, at: date, by: origin)
            .setting(\.reminder, to: values.reminder, at: date, by: origin)
    }

    /// The late pill. Callers on a paused installation show the "automatic refresh off" variant
    /// instead of the "XSide couldn't refresh it" text, under this same condition.
    public func showsLatePill(late: Bool) -> Bool { late && alertLate.value }

    /// The normal validity pill; never together with the late pill, which replaces it.
    public func showsValidityPill(late: Bool) -> Bool { showValidity.value && !showsLatePill(late: late) }

    public var showsRefreshCard: Bool { refreshCard.value }
    public var schedulesReminder: Bool { reminder.value }
    /// The install sheet shows unless all four switches are off.
    public var showsInstallSheet: Bool { derivedLevel != .none }
}
