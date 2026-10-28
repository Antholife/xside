import Foundation

/// Shared between the app and its privileged wake helper (`XSideWakeHelper`).
public enum WakeHelper {
    /// launchd label and Mach service name of the helper daemon.
    public static let label = "io.github.xside.wakehelper"
    /// File name of the daemon plist in `Contents/Library/LaunchDaemons`.
    public static let plistName = "\(label).plist"
    /// Bundle identifier of the only client the helper accepts.
    public static let appBundleID = "io.github.xside.XSide"
}

/// XPC interface of the helper. Replies carry an error message, or nil on success.
@objc public protocol WakeHelperProtocol {
    /// Replaces any wake XSide scheduled with a single wake at `date`.
    func scheduleWake(at date: Date, reply: @escaping @Sendable (String?) -> Void)
    /// Cancels every wake XSide scheduled (other apps' events are left untouched).
    func cancelWakes(reply: @escaping @Sendable (String?) -> Void)
}
