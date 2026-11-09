import Foundation
import XSideCore

/// A crash diagnosis in plain words: what happened and what to do, for `app` (its name), in the
/// app's language or in `language` (the `xside` tool answers in English).
struct CrashWording {
    let title: String
    let explanation: String
    let advice: String

    init(_ d: CrashDiagnosis, app: String, language: String? = nil) {
        func t(_ key: String) -> String { language.map { L(key, language: $0) } ?? L(key) }
        func f(_ key: String, _ args: String...) -> String {
            String(format: t(key), locale: Locale(identifier: language ?? AppLanguage.current.resolvedCode), arguments: args)
        }
        let base = "crash.cause.\(d.cause.rawValue)"
        let subject = d.subject ?? "?"
        title = t(base + ".title")
        switch d.cause {
        case .noSceneSupport:
            explanation = f(base + ".text", app)
            advice = t(base + (d.duoCompatibilityOn ? ".adviceDuo" : ".advice"))
        case .missingLibrary where d.subject == nil:
            // dyld said only that something is missing, not what.
            explanation = f(base + ".textUnnamed", app)
            advice = t(base + ".adviceUnnamed")
        case .missingLibrary:
            explanation = f(base + (d.inApp == true ? ".textApp" : ".textSystem"), app, subject)
            advice = t(base + (d.inApp == true ? ".adviceApp" : ".adviceSystem"))
        case .jailbreakLibrary:
            explanation = f(base + ".text", app, subject)
            advice = t(base + ".advice")
        case .missingSymbol:
            explanation = f(base + ".text", app, subject, d.library ?? t("crash.aLibrary"))
            advice = t("crash.cause.missingLibrary" + (d.inApp == true ? ".adviceApp" : ".adviceSystem"))
        case .tweak, .bundledLibrary:
            explanation = f(base + ".text", app, subject)
            advice = t(base + ".advice")
        case .other:
            let what = [d.exceptionType, d.signal].compactMap { $0 }.joined(separator: ", ")
            let kind = what.isEmpty ? t("crash.unknownError") : what
            explanation = d.subject.map { f(base + ".text", app, kind, $0) } ?? f(base + ".textNoImage", app, kind)
            advice = t(base + ".advice")
        case .iCloud:
            explanation = f(base + ".text", app)
            advice = t(base + (d.iCloudSignedOutOn == true ? ".adviceSignedOut" : ".adviceOption"))
        case .codeSignature, .xsideModule, .duoLegacyModule, .iCloudShim, .outOfMemory, .launchTimeout, .hang:
            explanation = f(base + ".text", app)
            advice = t(base + ".advice")
        }
    }
}
