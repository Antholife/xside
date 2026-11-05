import Foundation

/// When the install window shows how to trust the developer on the device (Settings > General >
/// VPN & Device Management). iOS trusts a developer certificate per device, and forgets it once
/// the last app signed with it is deleted there.
public enum TrustGuide {
    /// What XSide remembers about a device's guide.
    public enum Shown: Equatable, Sendable {
        case never
        /// Shown by an XSide that didn't record the certificate.
        case unknownIdentity
        /// Shown for that certificate (SHA-1).
        case identity(String)

        /// From the stored defaults value: a SHA-1 string, or `true` from older versions.
        public init(stored: Any?) {
            if let sha1 = stored as? String, !sha1.isEmpty { self = .identity(sha1) }
            else if stored as? Bool == true { self = .unknownIdentity }
            else { self = .never }
        }
    }

    /// `deviceHasApps`: XSide had at least one app on the device before this install.
    public static func isDue(shown: Shown, currentIdentity: String?, deviceHasApps: Bool) -> Bool {
        switch shown {
        case .never: return true
        case _ where !deviceHasApps: return true
        case .identity(let sha1):
            guard let currentIdentity else { return false }
            return sha1.uppercased() != currentIdentity.uppercased()
        case .unknownIdentity: return false
        }
    }
}
