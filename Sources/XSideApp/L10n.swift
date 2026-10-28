import Foundation
import SwiftUI
import XSideCore

/// In-app language choice, persisted in `UserDefaults` under `AppLanguage.storageKey`
/// (use `@AppStorage("language")` in views so they re-render on change).
enum AppLanguage: String, CaseIterable {
    case system, en, fr

    static let storageKey = "language"

    /// Currently selected language (read at call time).
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    /// Concrete `.lproj` code (`en` or `fr`) to read strings from.
    var resolvedCode: String {
        switch self {
        case .en: return "en"
        case .fr: return "fr"
        case .system:
            let preferred = Bundle.preferredLocalizations(from: ["en", "fr"], forPreferences: Locale.preferredLanguages)
            return preferred.first ?? "en"
        }
    }
}

private func lprojBundle(_ code: String) -> Bundle? {
    Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
}

/// Looks up `key` in the selected language, falling back to `en`, then to the key itself.
func L(_ key: String) -> String {
    let missing = "\u{0}missing"
    for code in [AppLanguage.current.resolvedCode, "en"] {
        if let value = lprojBundle(code)?.localizedString(forKey: key, value: missing, table: "Localizable"),
           value != missing {
            return value
        }
    }
    return key
}

/// Formatted variant: `L("popover.expires.days", 3)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let code = AppLanguage.current.resolvedCode
    return String(format: L(key), locale: Locale(identifier: code), arguments: args)
}

extension XSideError {
    /// One friendly message per case. Payloads are technical and never shown.
    var localizedMessage: String {
        switch self {
        case .xcodeMissing: return L("error.xcodeMissing")
        case .xcodeNotSignedIn: return L("error.xcodeNotSignedIn")
        case .noSigningIdentity: return L("error.noSigningIdentity")
        case .appIDLimitReached: return L("error.appIDLimitReached")
        case .deviceUnavailable: return L("error.deviceUnavailable")
        case .deviceLocked: return L("error.deviceLocked")
        case .maxAppsReached: return L("error.maxAppsReached")
        case .encryptedIPA: return L("error.encryptedIPA")
        case .invalidIPA: return L("error.invalidIPA")
        case .provisioningFailed: return L("error.provisioningFailed")
        case .installFailed: return L("error.installFailed")
        case .commandFailed: return L("error.commandFailed")
        case .recordNotFound: return L("error.recordNotFound")
        }
    }
}

/// Friendly message for any error: `XSideError` cases have their own text, anything else is generic.
func localizedMessage(_ error: any Error) -> String {
    (error as? XSideError)?.localizedMessage ?? L("error.generic")
}

/// Message for a persisted `Installation.lastErrorKey` (an `XSideError.key`), shown on an app row.
/// An unreachable device gets the network hint (isolating networks, CoreDeviceError 4016).
func localizedRowError(key: String) -> String {
    if key == "deviceUnavailable" { return L("popover.unreachableHint") }
    let lookup = "error.\(key)"
    let text = L(lookup)
    return text == lookup ? L("error.generic") : text
}

/// Locale matching the in-app language, for dates.
var appLocale: Locale { Locale(identifier: AppLanguage.current.resolvedCode) }
