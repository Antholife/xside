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
        case .tweak, .tweakSupport:
            // The tweak's own name when XSide knows it ("Alpha 1.2"), else its image's.
            let text = f(base + ".text", app, d.cause == .tweak ? d.tweakName ?? subject : subject)
            // Cephei's HBOutputForShellCommand and the like: no shell without a jailbreak.
            explanation = d.shellCommand == true ? text + " " + t("crash.shellCommand") : text
            advice = t(base + ".advice")
        case .tweakCFunctionHook:
            explanation = d.tweakName == nil && d.subject == nil ? f(base + ".textUnnamed", app)
                : f(base + ".text", app, d.tweakName ?? subject)
            advice = t(base + ".advice")
        case .bundledLibrary:
            explanation = f(base + ".text", app, subject)
            advice = t(base + ".advice")
        case .other:
            let what = [d.exceptionType, d.signal].compactMap { $0 }.joined(separator: ", ")
            let kind = what.isEmpty ? t("crash.unknownError") : what
            explanation = d.subject.map { f(base + ".text", app, kind, $0) } ?? f(base + ".textNoImage", app, kind)
            advice = t(base + ".advice")
        case .missingUsageDescription:
            // The key in plain words ("Apple Music…"), else what iOS named, else nothing.
            if let key = d.subject {
                let topic = d.usageTopic.map { t("crash.usage." + $0) } ?? t("crash.usage.unknown")
                explanation = f(base + ".text", app, topic, key)
            } else {
                explanation = f(base + ".textUnnamed", app)
            }
            advice = t(base + (d.duoCompatibilityOn && d.xsideAddsUsageDescription ? ".adviceDuo" : ".advice"))
        case .iCloud:
            explanation = f(base + ".text", app)
            advice = t(base + (d.iCloudSignedOutOn == true ? ".adviceSignedOut" : ".adviceOption"))
        case .codeSignature, .xsideModule, .duoLegacyModule, .duoAppLaunch, .iCloudShim, .outOfMemory, .launchTimeout, .hang:
            explanation = f(base + ".text", app)
            advice = t(base + ".advice")
        }
    }
}

/// Where a crash fix (« Désactiver ce tweak », « Réinstaller sans… ») stands.
enum CrashFixState: Equatable {
    /// `subject`: the tweak's name for « Désactiver ce tweak ».
    case running(CrashAction, subject: String?)
    /// `opened`: XSide opened the app again on the device.
    case done(CrashAction, subject: String?, opened: Bool)
    case failed(CrashAction, subject: String?, message: String)

    var isRunning: Bool { if case .running = self { true } else { false } }
    var isDone: Bool { if case .done = self { true } else { false } }

    /// « Réinstallation sans XSide Test Crash… », « Réinstallée sans XSide Test Crash. Rouvre l'app. »
    var text: String {
        switch self {
        case .running(let a, let subject): Self.say("crash.fix.running", a, subject)
        case .done(let a, let subject, let opened):
            Self.say("crash.fix.done", a, subject) + " " + L(opened ? "crash.fix.opened" : "crash.fix.reopen")
        case .failed(_, _, let message): L("crash.fix.failed", message)
        }
    }

    private static func say(_ prefix: String, _ action: CrashAction, _ subject: String?) -> String {
        let key = prefix + "." + action.rawValue
        return action == .disableTweak ? L(key, subject ?? "") : L(key)
    }
}
