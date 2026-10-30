import Foundation

/// Xcode vs. OS versions. A device on an iOS newer than Xcode's iOS SDK (typically an iOS beta
/// with a release Xcode) can't be provisioned or installed to, with an obscure Xcode error.
public enum XcodeCompat {
    /// `version` is newer than `reference` on major.minor: "27.1" vs "26.4" or "27.0".
    public static func isNewer(_ version: String, than reference: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let n = v.split(separator: ".").map { Int($0) ?? 0 }
            return [n.first ?? 0, n.count > 1 ? n[1] : 0]
        }
        let a = parts(version), b = parts(reference)
        return a[0] != b[0] ? a[0] > b[0] : a[1] > b[1]
    }

    /// `version`'s major is greater than `reference`'s: "27.0" vs "26.4", not "26.1" vs "26.0".
    public static func isNewerMajor(_ version: String, than reference: String) -> Bool {
        func major(_ v: String) -> Int { Int(v.split(separator: ".").first ?? "") ?? 0 }
        return major(version) > major(reference)
    }

    /// iOS SDK version of a developer directory ("26.0"), from the SDK's `SDKSettings.plist`.
    public static func iOSSDKVersion(developerDir: URL) -> String? {
        let url = developerDir.appendingPathComponent(
            "Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/SDKSettings.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["Version"] as? String
    }

    /// Version ("27.2") and build ("27B48") of the Xcode owning a developer directory, and whether
    /// it's a beta: beta build number ("17A5241e") or an app named like "Xcode-beta.app".
    public static func xcodeVersion(developerDir: URL) -> (version: String, build: String, isBeta: Bool)? {
        let contents = developerDir.standardizedFileURL.deletingLastPathComponent()
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("version.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String else { return nil }
        let build = plist["ProductBuildVersion"] as? String ?? ""
        let appName = contents.deletingLastPathComponent().lastPathComponent.lowercased()
        return (version, build, isBetaBuild(build) || appName.contains("beta"))
    }

    /// Apple beta builds have a build number of 4+ digits starting with 5 ("25A5279m", "26A5310").
    /// A trailing lowercase letter alone means nothing: releases have one too ("16A242d", and
    /// "22E772610a" for a Rapid Security Response).
    public static func isBetaBuild(_ build: String) -> Bool {
        guard let letter = build.firstIndex(where: \.isUppercase) else { return false }
        let number = build[build.index(after: letter)...].prefix(while: \.isNumber)
        return number.count >= 4 && number.first == "5"
    }

    /// Replaces a provisioning or install failure by its likely cause: `.xcodeTooOld` when the
    /// device's iOS major version is newer than the Xcode SDK's (a minor gap usually deploys fine),
    /// else `.xcodeNeedsBetaForMac` on a macOS beta with a release Xcode. Any other error is
    /// returned unchanged. The caller logs the original error.
    public static func explain(_ error: any Error, deviceOS: String?, sdkVersion: String?,
                               macBetaWithReleaseXcode: Bool = false) -> any Error {
        guard let xsideError = error as? XSideError else { return error }
        switch xsideError {
        case .provisioningFailed, .installFailed, .commandFailed: break
        default: return error
        }
        if let deviceOS, let sdkVersion, isNewerMajor(deviceOS, than: sdkVersion) {
            return XSideError.xcodeTooOld(deviceOS: deviceOS)
        }
        return macBetaWithReleaseXcode ? XSideError.xcodeNeedsBetaForMac : error
    }
}
