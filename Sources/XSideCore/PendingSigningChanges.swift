import Foundation

/// What a signing was asked to do for the options that only take effect when the app is signed
/// again (as opposed to the settings that sync live to the XSide module). Recorded by the
/// pipeline on the installation; what was asked, not what the app got (an option that couldn't be
/// added is shown by its own "missing" note, and asking again would not change it).
public struct SigningChoices: Codable, Equatable, Sendable {
    public var withoutXSideFeatures: Bool
    public var duoCompatibility: Bool
    public var iCloudSignedOut: Bool
    /// The tweaks enabled for that signing (`TweakPackage.id`s, in load order). nil in state
    /// written before tweaks: none were asked.
    public var tweaks: [String]?
    /// Those of `tweaks` loaded despite a ❌ (« Injecter quand même »). nil in older state: none.
    public var forcedTweaks: [String]?

    public init(withoutXSideFeatures: Bool, duoCompatibility: Bool, iCloudSignedOut: Bool, tweaks: [String]? = nil,
                forcedTweaks: [String]? = nil) {
        self.forcedTweaks = forcedTweaks
        self.withoutXSideFeatures = withoutXSideFeatures
        self.duoCompatibility = duoCompatibility
        self.iCloudSignedOut = iCloudSignedOut
        self.tweaks = tweaks
    }
}

/// An option of Settings > Mes apps that only applies at signing.
public enum SigningTimeSetting: String, Sendable, CaseIterable {
    case xsideModule, duoCompatibility, iCloudSignedOut, tweaks
}

extension Installation {
    /// The signing-time options whose stored choice differs from what the installed copy was
    /// signed with: they take effect at its next refresh. `wantsWithoutXSideFeatures` is the
    /// choice now (the app's, the Mac's default, or this device's own, already resolved by the
    /// caller). In older state (no `signedChoices`) the module compares with what the last
    /// signing did (`withoutXSideFeatures`); Duo, iCloud and tweaks are unknown, so never pending.
    /// Tweaks are pending when the ids enabled on this device, in order, differ from those the
    /// last signing was asked for (enabled, disabled, added, removed, replaced or reordered), or
    /// when « Injecter quand même » changed on one of the enabled ones.
    public func pendingSigningChanges(wantsWithoutXSideFeatures: Bool) -> Set<SigningTimeSetting> {
        var pending: Set<SigningTimeSetting> = []
        let signedWithout = signedChoices?.withoutXSideFeatures ?? (withoutXSideFeatures == true)
        if signedWithout != wantsWithoutXSideFeatures { pending.insert(.xsideModule) }
        if let signed = signedChoices {
            if signed.duoCompatibility != (duoCompatibility == true) { pending.insert(.duoCompatibility) }
            if signed.iCloudSignedOut != (iCloudSignedOut == true) { pending.insert(.iCloudSignedOut) }
            if enabledTweakIDs != (signed.tweaks ?? []) || Set(forcedTweakIDs) != Set(signed.forcedTweaks ?? []) {
                pending.insert(.tweaks)
            }
        }
        return pending
    }
}

extension Installation {
    /// The tweaks enabled on this device, in its list's order (the pool's load order).
    public var enabledTweakIDs: [String] { (tweaks ?? []).filter(\.enabled).map(\.id) }
    /// The enabled ones the person chose to load despite a ❌.
    public var forcedTweakIDs: [String] { (tweaks ?? []).filter { $0.enabled && $0.force == true }.map(\.id) }
}
