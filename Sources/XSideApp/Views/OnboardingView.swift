import AppKit
import SwiftUI
import XSideCore

enum OnboardingWindow {
    static let id = "onboarding"
}

enum XcodeLauncher {
    static let appStoreURL = URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!

    /// Xcode by bundle identifier, else the app enclosing the detected developer directory.
    @MainActor static func open(developerDir: URL?) {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")
            ?? developerDir.flatMap(enclosingApp)
        guard let url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// `/Applications/Xcode-beta.app/Contents/Developer` becomes `/Applications/Xcode-beta.app`.
    static func enclosingApp(_ dir: URL) -> URL? {
        var url = dir.standardizedFileURL
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

/// What to tell a user whose Mac isn't ready. Re-probes every 5 s while on screen, so it goes away
/// by itself (the parent stops showing it) once the environment is OK.
struct OnboardingView: View {
    let model: AppModel
    let error: XSideError
    var compact = false

    private var isMissing: Bool { if case .xcodeMissing = error { true } else { false } }

    private var title: String {
        switch error {
        case .xcodeMissing: L("onboarding.xcodeMissing.title")
        case .noSigningIdentity: L("onboarding.noIdentity.title")
        default: L("onboarding.signIn.title")
        }
    }

    var body: some View {
        VStack(spacing: compact ? 10 : 14) {
            Image(systemName: isMissing ? "hammer.fill" : "person.crop.circle.badge.exclamationmark")
                .font(.system(size: compact ? 26 : 40, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            Text(title).font(compact ? .headline : .title2.weight(.semibold))
            Text(isMissing ? L("onboarding.xcodeMissing.body") : error.localizedMessage)
                .font(compact ? .callout : .body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !isMissing {
                Text(L("onboarding.signIn.steps"))
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Button(isMissing ? L("onboarding.openAppStore") : L("onboarding.openXcode")) {
                if isMissing {
                    NSWorkspace.shared.open(XcodeLauncher.appStoreURL)
                } else {
                    XcodeLauncher.open(developerDir: model.lastKnownDeveloperDir)
                }
            }
            .buttonStyle(GradientButtonStyle())
            HStack(spacing: 6) {
                if model.isProbing { ProgressView().controlSize(.small) }
                Button(L("onboarding.recheck"), action: model.recheckEnvironment)
                    .controlSize(.small)
                    .disabled(model.isProbing)
            }
            Text(L("onboarding.autoDetect"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(compact ? 12 : 28)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { model.recheckEnvironment() }
            }
        }
    }
}

/// Dedicated window shown at launch when the environment fails. Closes itself once it is OK.
struct OnboardingWindowRoot: View {
    let model: AppModel
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if case .failure(let error)? = model.environment {
                OnboardingView(model: model, error: error)
            } else {
                ProgressView().padding(40)
            }
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(L("onboarding.window"))
        .id(language)
        .onChange(of: model.environmentFailed) { _, failed in
            if !failed, model.environment != nil { dismissWindow(id: OnboardingWindow.id) }
        }
    }
}
