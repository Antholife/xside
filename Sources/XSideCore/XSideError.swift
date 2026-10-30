import Foundation

public enum XSideError: Error, Equatable, Sendable {
    case xcodeMissing
    case xcodeNotSignedIn
    case noSigningIdentity
    case appIDLimitReached
    case deviceUnavailable
    case deviceLocked
    case maxAppsReached
    case encryptedIPA
    case invalidIPA(String)
    case provisioningFailed(String)
    case installFailed(String)
    /// `devicectl` couldn't remove the app from the device (its first error line).
    case uninstallFailed(String)
    case commandFailed(tool: String, status: Int32)
    case recordNotFound
    /// A refresh got back a profile that doesn't expire later than the installed one.
    case profileNotRenewed
    /// The device runs an iOS newer than the installed Xcode supports (iOS beta, release Xcode).
    case xcodeTooOld(deviceOS: String)
    /// The Mac runs a macOS beta with a release Xcode, which may not work on it.
    case xcodeNeedsBetaForMac
    /// A tool didn't answer within its deadline and was stopped (see `CommandTimeout`).
    case timedOut(tool: String)
    /// A bundle identifier XSide can't sign with (custom one, or an import's default too long).
    case invalidBundleID(String)

    /// Case name without payload, used to deduplicate notifications.
    public var key: String {
        switch self {
        case .xcodeMissing: "xcodeMissing"
        case .xcodeNotSignedIn: "xcodeNotSignedIn"
        case .noSigningIdentity: "noSigningIdentity"
        case .appIDLimitReached: "appIDLimitReached"
        case .deviceUnavailable: "deviceUnavailable"
        case .deviceLocked: "deviceLocked"
        case .maxAppsReached: "maxAppsReached"
        case .encryptedIPA: "encryptedIPA"
        case .invalidIPA: "invalidIPA"
        case .provisioningFailed: "provisioningFailed"
        case .installFailed: "installFailed"
        case .uninstallFailed: "uninstallFailed"
        case .commandFailed: "commandFailed"
        case .recordNotFound: "recordNotFound"
        case .profileNotRenewed: "profileNotRenewed"
        case .xcodeTooOld: "xcodeTooOld"
        case .xcodeNeedsBetaForMac: "xcodeNeedsBetaForMac"
        case .timedOut: "timedOut"
        case .invalidBundleID: "invalidBundleID"
        }
    }
}
