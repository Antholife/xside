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
    case commandFailed(tool: String, status: Int32)

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
        case .commandFailed: "commandFailed"
        }
    }
}
