import Foundation

/// What a signing was asked to do for the options that only take effect when the app is signed
/// again (as opposed to the settings that sync live to the XSide module). Recorded by the
/// pipeline on the installation; what was asked, not what the app got (an option that couldn't be
/// added is shown by its own "missing" note, and asking again would not change it).
public struct SigningChoices: Codable, Equatable, Sendable {
    public var withoutXSideFeatures: Bool
    public var duoCompatibility: Bool
    public var iCloudSignedOut: Bool

    public init(withoutXSideFeatures: Bool, duoCompatibility: Bool, iCloudSignedOut: Bool) {
        self.withoutXSideFeatures = withoutXSideFeatures
        self.duoCompatibility = duoCompatibility
        self.iCloudSignedOut = iCloudSignedOut
    }
}

/// An option of Settings > Mes apps that only applies at signing.
public enum SigningTimeSetting: String, Sendable, CaseIterable {
    case xsideModule, duoCompatibility, iCloudSignedOut
}

extension Installation {
    /// The signing-time options whose stored choice differs from what the installed copy was
    /// signed with: they take effect at its next refresh. `wantsWithoutXSideFeatures` is the
    /// choice now (the app's, the Mac's default, or this device's own, already resolved by the
    /// caller). In older state (no `signedChoices`) the module compares with what the last
    /// signing did (`withoutXSideFeatures`); Duo and iCloud are unknown, so never pending.
    public func pendingSigningChanges(wantsWithoutXSideFeatures: Bool) -> Set<SigningTimeSetting> {
        var pending: Set<SigningTimeSetting> = []
        let signedWithout = signedChoices?.withoutXSideFeatures ?? (withoutXSideFeatures == true)
        if signedWithout != wantsWithoutXSideFeatures { pending.insert(.xsideModule) }
        if let signed = signedChoices {
            if signed.duoCompatibility != (duoCompatibility == true) { pending.insert(.duoCompatibility) }
            if signed.iCloudSignedOut != (iCloudSignedOut == true) { pending.insert(.iCloudSignedOut) }
        }
        return pending
    }
}
