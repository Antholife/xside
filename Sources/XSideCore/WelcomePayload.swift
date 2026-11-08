import Foundation

/// What XSide hands the iOS dylib at signing: the Info.plist dictionary `XSideWelcome`. The
/// Objective-C dylib reads these exact keys:
///
/// - `thresholdHours` (Int), `reminderLeadHours` (Int)
/// - `reminder` (Int 0/1): legacy switch of the current dylib, kept equal to `settings.reminder`
///   (and 0 under "Aucun")
/// - `settings` (dictionary): `level`, `showValidity`, `alertLate`, `refreshCard`, `reminder`,
///   `language`, `autoRefresh`; each one a dictionary `{value, changedAt, changedBy}` where
///   `value` is a string (`level`: all|essentials|none, `language`: automatic|fr|en) or a Bool,
///   `changedAt` a plist date and `changedBy` "mac" or "device"
/// - `installationID` (String), `channelSecret` (plist data, 32 bytes): the channel credentials
/// - `installedAt` (plist date): first install of the app on this device
/// - `signedAt` (plist date): when this signing happened (the phone's "Rafraîchie le" row)
///
/// Optional parts missing from the payload are left out of the dictionary.
public struct WelcomePayload: Sendable, Equatable {
    public var thresholdHours: Int
    public var reminderLeadHours: Int
    public var inApp: InAppSettings
    public var installationID: String?
    public var channelSecret: Data?
    public var installedAt: Date?
    public var signedAt: Date?

    public init(thresholdHours: Int, reminderLeadHours: Int, inApp: InAppSettings,
                installationID: String? = nil, channelSecret: Data? = nil, installedAt: Date? = nil,
                signedAt: Date? = nil) {
        self.thresholdHours = thresholdHours
        self.reminderLeadHours = reminderLeadHours
        self.inApp = inApp
        self.installationID = installationID
        self.channelSecret = channelSecret
        self.installedAt = installedAt
        self.signedAt = signedAt
    }

    /// The property list value of `XSideWelcome`.
    var plist: [String: Any] {
        func field<V>(_ f: Field<V>, _ value: Any) -> [String: Any] {
            ["value": value, "changedAt": f.changedAt, "changedBy": f.changedBy.rawValue]
        }
        let s = inApp
        var result: [String: Any] = [
            "thresholdHours": thresholdHours,
            "reminderLeadHours": reminderLeadHours,
            "reminder": s.schedulesReminder ? 1 : 0,
            "settings": [
                "level": field(s.level, s.level.value.rawValue),
                "showValidity": field(s.showValidity, s.showValidity.value),
                "alertLate": field(s.alertLate, s.alertLate.value),
                "refreshCard": field(s.refreshCard, s.refreshCard.value),
                "reminder": field(s.reminder, s.reminder.value),
                "language": field(s.language, s.language.value.rawValue),
                "autoRefresh": field(s.autoRefresh, s.autoRefresh.value),
            ] as [String: Any],
        ]
        if let installationID { result["installationID"] = installationID }
        if let channelSecret { result["channelSecret"] = channelSecret }
        if let installedAt { result["installedAt"] = installedAt }
        if let signedAt { result["signedAt"] = signedAt }
        return result
    }
}
