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
    /// What XSide does when a newer release of the app's GitHub source shows up (notify or install
    /// on its own). Belongs to the app (its source is shared by every device), but rides here so it
    /// syncs like the other settings; the Mac keeps `UpdateSource.mode` in step (see
    /// `Library.applyCheckIn` and `setUpdateSource`). Inert for an app with no source.
    public var updateMode: Field<UpdateMode>
    /// How often the app's source is checked (see `UpdateFrequency`), riding here like `updateMode`
    /// and kept in step with `UpdateSource.checkInterval` by the Mac. Inert for an app with no source.
    public var updateFrequency: Field<UpdateFrequency>
    /// Compatibility install options (per device, applied at the next signing): the Duo fix and the
    /// signed-out-iCloud shim. Ride here so the phone can set them; the Mac keeps `Installation`'s own
    /// `duoCompatibility` / `iCloudSignedOut` in step (see `Library.applyCheckIn`).
    public var duoCompatibility: Field<Bool>
    public var iCloudSignedOut: Field<Bool>
    /// Per-app data/backup options (the app's `InstallOptions`), ridden here so the phone can set
    /// them; the Mac keeps `record.options` in step. `backupData`: snapshot the data after each
    /// refresh. `backupCaches`: include the Caches/tmp folders. `backupBeforeUpdate`: snapshot just
    /// before an update installs.
    public var backupData: Field<Bool>
    public var backupCaches: Field<Bool>
    public var backupBeforeUpdate: Field<Bool>

    public init(showValidity: Field<Bool>, alertLate: Field<Bool>,
                refreshCard: Field<Bool>, reminder: Field<Bool>, language: Field<MessageLanguage>,
                autoRefresh: Field<Bool>, updateMode: Field<UpdateMode>? = nil,
                updateFrequency: Field<UpdateFrequency>? = nil,
                duoCompatibility: Field<Bool>? = nil, iCloudSignedOut: Field<Bool>? = nil,
                backupData: Field<Bool>? = nil, backupCaches: Field<Bool>? = nil,
                backupBeforeUpdate: Field<Bool>? = nil) {
        self.showValidity = showValidity
        self.alertLate = alertLate
        self.refreshCard = refreshCard
        self.reminder = reminder
        self.language = language
        self.autoRefresh = autoRefresh
        // Older state has no update / compatibility fields: default them to the autoRefresh field's
        // stamp (a safe past date), so decoding never fails and a seeded value always wins.
        let past = autoRefresh.changedAt
        self.updateMode = updateMode ?? Field(value: .notify, changedAt: past, changedBy: .mac)
        self.updateFrequency = updateFrequency ?? Field(value: .global, changedAt: past, changedBy: .mac)
        self.duoCompatibility = duoCompatibility ?? Field(value: false, changedAt: past, changedBy: .mac)
        self.iCloudSignedOut = iCloudSignedOut ?? Field(value: false, changedAt: past, changedBy: .mac)
        self.backupData = backupData ?? Field(value: true, changedAt: past, changedBy: .mac)
        self.backupCaches = backupCaches ?? Field(value: true, changedAt: past, changedBy: .mac)
        self.backupBeforeUpdate = backupBeforeUpdate ?? Field(value: true, changedAt: past, changedBy: .mac)
    }

    // Custom Codable so state and channel JSON from before these fields (older XSide, older dylibs)
    // still decode: a missing field is defaulted, not an error. Extra keys stay ignored.
    private enum CodingKeys: String, CodingKey {
        case showValidity, alertLate, refreshCard, reminder, language, autoRefresh
        case updateMode, updateFrequency, duoCompatibility, iCloudSignedOut
        case backupData, backupCaches, backupBeforeUpdate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(showValidity: try c.decode(Field<Bool>.self, forKey: .showValidity),
                  alertLate: try c.decode(Field<Bool>.self, forKey: .alertLate),
                  refreshCard: try c.decode(Field<Bool>.self, forKey: .refreshCard),
                  reminder: try c.decode(Field<Bool>.self, forKey: .reminder),
                  language: try c.decode(Field<MessageLanguage>.self, forKey: .language),
                  autoRefresh: try c.decode(Field<Bool>.self, forKey: .autoRefresh),
                  updateMode: try c.decodeIfPresent(Field<UpdateMode>.self, forKey: .updateMode),
                  updateFrequency: try c.decodeIfPresent(Field<UpdateFrequency>.self, forKey: .updateFrequency),
                  duoCompatibility: try c.decodeIfPresent(Field<Bool>.self, forKey: .duoCompatibility),
                  iCloudSignedOut: try c.decodeIfPresent(Field<Bool>.self, forKey: .iCloudSignedOut),
                  backupData: try c.decodeIfPresent(Field<Bool>.self, forKey: .backupData),
                  backupCaches: try c.decodeIfPresent(Field<Bool>.self, forKey: .backupCaches),
                  backupBeforeUpdate: try c.decodeIfPresent(Field<Bool>.self, forKey: .backupBeforeUpdate))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(showValidity, forKey: .showValidity)
        try c.encode(alertLate, forKey: .alertLate)
        try c.encode(refreshCard, forKey: .refreshCard)
        try c.encode(reminder, forKey: .reminder)
        try c.encode(language, forKey: .language)
        try c.encode(autoRefresh, forKey: .autoRefresh)
        try c.encode(updateMode, forKey: .updateMode)
        try c.encode(updateFrequency, forKey: .updateFrequency)
        try c.encode(duoCompatibility, forKey: .duoCompatibility)
        try c.encode(iCloudSignedOut, forKey: .iCloudSignedOut)
        try c.encode(backupData, forKey: .backupData)
        try c.encode(backupCaches, forKey: .backupCaches)
        try c.encode(backupBeforeUpdate, forKey: .backupBeforeUpdate)
    }

    /// Mac defaults for a new installation: the reminder is seeded from the global Mac setting,
    /// everything else on (the validity pill too: Anthony, 2026-11-08). The update mode is seeded
    /// from the app's own source at signing (`notify` here, for an app with no source).
    public static func defaults(reminder: Bool, at: Date) -> InAppSettings {
        func f<V>(_ v: V) -> Field<V> { Field(value: v, changedAt: at, changedBy: .mac) }
        return InAppSettings(showValidity: f(true), alertLate: f(true),
                             refreshCard: f(true), reminder: f(reminder), language: f(.automatic),
                             autoRefresh: f(true), updateMode: f(.notify), updateFrequency: f(.global),
                             duoCompatibility: f(false), iCloudSignedOut: f(false),
                             backupData: f(true), backupCaches: f(true), backupBeforeUpdate: f(true))
    }

    /// Field-by-field merge (see `Field.merge`). Symmetric: `merge(a, b) == merge(b, a)`.
    public static func merge(_ a: InAppSettings, _ b: InAppSettings) -> InAppSettings {
        InAppSettings(showValidity: .merge(a.showValidity, b.showValidity),
                      alertLate: .merge(a.alertLate, b.alertLate),
                      refreshCard: .merge(a.refreshCard, b.refreshCard),
                      reminder: .merge(a.reminder, b.reminder),
                      language: .merge(a.language, b.language),
                      autoRefresh: .merge(a.autoRefresh, b.autoRefresh),
                      updateMode: .merge(a.updateMode, b.updateMode),
                      updateFrequency: .merge(a.updateFrequency, b.updateFrequency),
                      duoCompatibility: .merge(a.duoCompatibility, b.duoCompatibility),
                      iCloudSignedOut: .merge(a.iCloudSignedOut, b.iCloudSignedOut),
                      backupData: .merge(a.backupData, b.backupData),
                      backupCaches: .merge(a.backupCaches, b.backupCaches),
                      backupBeforeUpdate: .merge(a.backupBeforeUpdate, b.backupBeforeUpdate))
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
