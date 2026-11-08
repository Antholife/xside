import Foundation

/// How much XSide may show inside an app ("Messages XSide"). `essentials` is a ceiling: only
/// problem alerts (late pill, reminder), and only those whose own switch is on. `none` shows
/// nothing, the install sheet included.
public enum MessageLevel: String, Codable, Sendable { case all, essentials, none }

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
public struct InAppSettings: Codable, Equatable, Sendable {
    public var level: Field<MessageLevel>
    public var showValidity: Field<Bool>
    public var alertLate: Field<Bool>
    public var refreshCard: Field<Bool>
    public var reminder: Field<Bool>
    public var language: Field<MessageLanguage>
    public var autoRefresh: Field<Bool>

    public init(level: Field<MessageLevel>, showValidity: Field<Bool>, alertLate: Field<Bool>,
                refreshCard: Field<Bool>, reminder: Field<Bool>, language: Field<MessageLanguage>,
                autoRefresh: Field<Bool>) {
        self.level = level
        self.showValidity = showValidity
        self.alertLate = alertLate
        self.refreshCard = refreshCard
        self.reminder = reminder
        self.language = language
        self.autoRefresh = autoRefresh
    }

    /// Mac defaults for a new installation: the reminder is seeded from the global Mac setting,
    /// the validity pill is off, everything else on.
    public static func defaults(reminder: Bool, at: Date) -> InAppSettings {
        func f<V>(_ v: V) -> Field<V> { Field(value: v, changedAt: at, changedBy: .mac) }
        return InAppSettings(level: f(.all), showValidity: f(false), alertLate: f(true),
                             refreshCard: f(true), reminder: f(reminder), language: f(.automatic),
                             autoRefresh: f(true))
    }

    /// Field-by-field merge (see `Field.merge`). Symmetric: `merge(a, b) == merge(b, a)`.
    public static func merge(_ a: InAppSettings, _ b: InAppSettings) -> InAppSettings {
        InAppSettings(level: .merge(a.level, b.level),
                      showValidity: .merge(a.showValidity, b.showValidity),
                      alertLate: .merge(a.alertLate, b.alertLate),
                      refreshCard: .merge(a.refreshCard, b.refreshCard),
                      reminder: .merge(a.reminder, b.reminder),
                      language: .merge(a.language, b.language),
                      autoRefresh: .merge(a.autoRefresh, b.autoRefresh))
    }

    /// Copy with one field set and stamped, e.g. `s.setting(\.reminder, to: false, at: now, by: .mac)`.
    public func setting<V>(_ keyPath: WritableKeyPath<InAppSettings, Field<V>>, to value: V,
                           at date: Date, by origin: ChangeOrigin) -> InAppSettings {
        var copy = self
        copy[keyPath: keyPath] = Field(value: value, changedAt: date, changedBy: origin)
        return copy
    }

    // MARK: Effective visibility (spec §1 matrix + the Essentials ceiling)

    /// The late pill. Callers on a paused installation show the "automatic refresh off" variant
    /// instead of the "XSide couldn't refresh it" text, under this same condition.
    public func showsLatePill(late: Bool) -> Bool {
        late && level.value != .none && alertLate.value
    }

    /// The normal validity pill. Never together with the late pill (which replaces it), and
    /// never under Essentials (which only allows problem alerts).
    public func showsValidityPill(late: Bool) -> Bool {
        level.value == .all && showValidity.value && !showsLatePill(late: late)
    }

    public var showsRefreshCard: Bool { level.value == .all && refreshCard.value }
    public var schedulesReminder: Bool { level.value != .none && reminder.value }
    /// The install sheet is not a problem alert: only "all" shows it.
    public var showsInstallSheet: Bool { level.value == .all }
}
