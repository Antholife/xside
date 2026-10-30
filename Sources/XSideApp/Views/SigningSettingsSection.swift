import AppKit
import SwiftUI
import XSideCore

/// Settings: Xcode, the Apple account and the signing certificate, each ✅ or ⚠️ with its own fix
/// right below it. A step that depends on a failing one above says so instead (the certificate
/// needs the account first). While the first check runs, or when the check itself failed, the
/// rows say so without asking to fix anything.
struct SigningSettingsSection: View {
    let model: AppModel

    /// The state shown by a row's icon.
    private enum RowState { case ok, todo, checking, unknown }

    var body: some View {
        let blocking = model.firstBlockingStep
        let probed = model.environment != nil
        // The check itself failed (`security`, `openssl`): nothing is known about the account or
        // the certificate.
        let checkFailure = model.environmentError.map(\.isSetupCheckFailure) ?? false
        Section(L("settings.signing")) {
            row(L("settings.signing.xcode"), state: !probed ? .checking : blocking == .xcode ? .todo : .ok,
                detail: xcodeDetail) {
                if blocking == .xcode {
                    Button(L(XcodeLauncher.macIsBeta ? "journey.xcode.downloadBeta" : "onboarding.openAppStore")) {
                        NSWorkspace.shared.open(XcodeLauncher.macIsBeta ? XcodeLauncher.betaURL : XcodeLauncher.appStoreURL)
                    }
                }
                if model.macBetaWithReleaseXcode { MacBetaBanner() }
            }
            XcodePicker(model: model)
            if model.unreadyBetaXcode != nil {
                Label(L("settings.xcode.betaNotReady"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let accountOK = probed && (blocking ?? .ready) > .account
            row(L("settings.signing.account"),
                state: !probed ? .checking : checkFailure ? .unknown : accountOK ? .ok : .todo,
                detail: accountOK ? model.accountName : nil) {
                if blocking == .xcode {
                    waiting(L("settings.signing.needsXcode"))
                } else if let error = model.environmentError, error.isSetupCheckFailure {
                    // The check itself failed: nothing to fix in Xcode, only to check again.
                    Text(error.environmentReason).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("onboarding.recheck"), action: model.recheckEnvironment)
                        .disabled(model.isProbing)
                } else if blocking == .account {
                    SigningFixView(problem: .account, model: model)
                }
            }
            // Signed out with the certificate still in the keychain: the certificate itself is fine.
            let signedOutOnly = model.environmentError == .xcodeNotSignedIn && !model.certificateMissingToo
            let certificateOK = probed && (blocking == nil || signedOutOnly)
            row(L("settings.signing.certificate"),
                state: !probed ? .checking : checkFailure ? .unknown : certificateOK ? .ok : .todo,
                detail: model.signingEnvironment?.identityName) {
                if checkFailure {
                    EmptyView()
                } else if blocking == .xcode || (blocking == .account && !signedOutOnly) {
                    waiting(L("settings.signing.needsAccount"))
                } else if blocking == .certificate {
                    SigningFixView(problem: .certificate, model: model)
                }
            }
        }
    }

    private var xcodeDetail: String? {
        guard let dir = model.lastKnownDeveloperDir,
              let xcode = XcodeCompat.xcodeVersion(developerDir: dir) else { return nil }
        return L(xcode.isBeta ? "settings.signing.xcode.beta" : "settings.signing.xcode.version", xcode.version, xcode.build)
    }

    /// "First fix the line above."
    private func waiting(_ text: String) -> some View {
        Label(text, systemImage: "arrow.up")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func row<Fix: View>(_ title: String, state: RowState, detail: String?,
                                @ViewBuilder fix: () -> Fix) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                icon(state).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if state == .checking {
                        Text(L("settings.signing.checking")).font(.caption).foregroundStyle(.secondary)
                    } else if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                if state == .todo {
                    Text(L("settings.signing.todo")).font(.caption).foregroundStyle(.orange)
                }
            }
            if state != .checking { fix().padding(.leading, 26) }
        }
    }

    @ViewBuilder private func icon(_ state: RowState) -> some View {
        switch state {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.reachable)
        case .todo:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .checking:
            ProgressView().controlSize(.small)
        case .unknown:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}

extension URL {
    /// Same directory once symlinks are resolved (`/Applications/Xcode.app` may be a link).
    func isSameDirectory(_ other: URL) -> Bool {
        resolvingSymlinksInPath().standardizedFileURL.path == other.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// "Xcode in use": Automatic (what XSide picks) or one of the Xcode apps found. Shown when there
/// is a choice to make (several Xcode apps), or to go back to Automatic.
private struct XcodePicker: View {
    let model: AppModel

    var body: some View {
        let xcodes = model.xcodes
        if xcodes.count > 1 || model.xcodeSelection != .automatic {
            Picker(L("settings.xcode.picker"), selection: selection) {
                Text(automaticLabel).tag(XcodeSelection.automatic.rawValue)
                ForEach(xcodes) { xcode in
                    Text(label(xcode, among: xcodes)).tag(xcode.developerDir.path)
                }
            }
        }
    }

    /// The picked Xcode, or Automatic once it's gone (the probe already fell back to it).
    private var selection: Binding<String> {
        Binding(get: {
            guard case .path(let path) = model.xcodeSelection,
                  model.xcodes.contains(where: { $0.developerDir.isSameDirectory(URL(fileURLWithPath: path)) })
            else { return XcodeSelection.automatic.rawValue }
            return path
        }, set: { model.xcodeSelection = XcodeSelection(rawValue: $0) })
    }

    private var automaticLabel: String {
        guard let dir = model.automaticDeveloperDir,
              let xcode = model.xcodes.first(where: { $0.developerDir.isSameDirectory(dir) }) else {
            return L("settings.xcode.auto.none")
        }
        return L("settings.xcode.auto", Self.versionLabel(xcode))
    }

    /// "Xcode 27.2 (27B48)", plus the app's name when two Xcode apps read the same.
    private func label(_ xcode: XcodeInstall, among all: [XcodeInstall]) -> String {
        let text = Self.versionLabel(xcode)
        let twins = all.filter { Self.versionLabel($0) == text }.count > 1
        return twins ? "\(text) — \(xcode.appURL.lastPathComponent)" : text
    }

    static func versionLabel(_ xcode: XcodeInstall) -> String {
        L(xcode.isBeta ? "settings.xcode.item.beta" : "settings.xcode.item", xcode.version, xcode.build)
    }
}
