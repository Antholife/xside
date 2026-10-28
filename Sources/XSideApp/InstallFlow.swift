import Foundation
import Observation
import XSideCore

/// State of the install window for one `.ipa`. Lives in `AppModel` (not in view `@State`) so it
/// survives the `.id(language)` re-render.
@MainActor @Observable
final class InstallFlow {
    enum Phase: Equatable {
        case inspecting
        /// The file can't be installed at all (encrypted, not an app…).
        case rejected(String)
        /// Ready for input; `error` is the localized message of the last failed attempt.
        case editing(error: String?)
        case running(InstallStep)
        case succeeded(deviceName: String, guide: FirstInstallGuide?)
    }

    let ipa: URL
    var info: AppInfo?
    /// Library record already imported from the same bundle id (second import of the same app).
    var existing: AppRecord?
    var phase: Phase = .inspecting
    var deviceID: String?
    var draft = OptionsDraft()

    init(ipa: URL) { self.ipa = ipa }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }
}

/// What the first-install guide must say for a device.
struct FirstInstallGuide: Equatable {
    let accountName: String
    let needsDeveloperMode: Bool
}

/// Text-field friendly mirror of `InstallOptions` (empty string = not customized).
struct OptionsDraft: Equatable {
    var name = ""
    var bundleID = ""
    var version = ""
    /// Absolute path of a newly chosen image, or the library-relative path of the remembered one.
    var iconPath: String?
    var fileSharing = false
    var iPadFullScreen = false
    var proMotion = false
    var minOS = ""

    init() {}

    init(_ o: InstallOptions) {
        name = o.displayName ?? ""
        bundleID = o.customBundleID ?? ""
        version = o.version ?? ""
        iconPath = o.iconPath
        fileSharing = o.fileSharing
        iPadFullScreen = o.iPadFullScreen
        proMotion = o.proMotion
        minOS = o.minimumOSVersion ?? ""
    }

    var options: InstallOptions {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return InstallOptions(displayName: clean(name), customBundleID: clean(bundleID), version: clean(version),
                              iconPath: iconPath, fileSharing: fileSharing, iPadFullScreen: iPadFullScreen,
                              proMotion: proMotion, minimumOSVersion: clean(minOS))
    }
}
