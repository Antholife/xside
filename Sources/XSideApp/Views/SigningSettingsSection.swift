import AppKit
import SwiftUI
import XSideCore

/// Settings: Xcode, the Apple account and the signing certificate, each ✅ or ⚠️ with its own fix
/// right below it. A step that depends on a failing one above says so instead (the certificate
/// needs the account first).
struct SigningSettingsSection: View {
    let model: AppModel

    var body: some View {
        let blocking = model.firstBlockingStep
        let probed = model.environment != nil
        Section(L("settings.signing")) {
            row(L("settings.signing.xcode"), ok: probed && blocking != .xcode, detail: xcodeDetail) {
                if blocking == .xcode {
                    Button(L(XcodeLauncher.macIsBeta ? "journey.xcode.downloadBeta" : "onboarding.openAppStore")) {
                        NSWorkspace.shared.open(XcodeLauncher.macIsBeta ? XcodeLauncher.betaURL : XcodeLauncher.appStoreURL)
                    }
                }
                if model.macBetaWithReleaseXcode { MacBetaBanner() }
            }
            let accountOK = probed && (blocking ?? .ready) > .account
            row(L("settings.signing.account"), ok: accountOK, detail: accountOK ? model.accountName : nil) {
                if blocking == .xcode {
                    waiting(L("settings.signing.needsXcode"))
                } else if let error = model.environmentError, error.isSetupCheckFailure {
                    // The check itself failed: nothing to fix in Xcode, only to check again.
                    Text(error.environmentReason).font(.caption).foregroundStyle(.secondary)
                    Button(L("onboarding.recheck"), action: model.recheckEnvironment)
                } else if blocking == .account {
                    SigningFixView(problem: .account, model: model)
                }
            }
            // Signed out with the certificate still in the keychain: the certificate itself is fine.
            // A failed check says nothing about it either way.
            let signedOutOnly = model.environmentError == .xcodeNotSignedIn && !model.certificateMissingToo
            let certificateOK = probed && (blocking == nil || signedOutOnly)
            row(L("settings.signing.certificate"), ok: certificateOK, detail: model.signingEnvironment?.identityName) {
                if blocking == .xcode || (blocking == .account && !signedOutOnly) {
                    waiting(L("settings.signing.needsAccount"))
                } else if blocking == .certificate {
                    SigningFixView(problem: .certificate, model: model)
                }
            }
        }
    }

    private var xcodeDetail: String? {
        guard let dir = model.signingEnvironment?.developerDir ?? model.lastKnownDeveloperDir,
              let xcode = XcodeCompat.xcodeVersion(developerDir: dir) else { return nil }
        return L(xcode.isBeta ? "settings.signing.xcode.beta" : "settings.signing.xcode.version", xcode.version, xcode.build)
    }

    /// "First fix the line above."
    private func waiting(_ text: String) -> some View {
        Label(text, systemImage: "arrow.up")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func row<Fix: View>(_ title: String, ok: Bool, detail: String?,
                                @ViewBuilder fix: () -> Fix) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? Theme.reachable : .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                if !ok {
                    Text(L("settings.signing.todo")).font(.caption).foregroundStyle(.orange)
                }
            }
            fix().padding(.leading, 26)
        }
    }
}
