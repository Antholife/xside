import AppKit
import SwiftUI
import XSideCore

/// « Correctifs de compatibilité »: the install options that change the app so it works better on
/// the device or with a free account (iPhone Duo, signed-out iCloud…), apart from the regular
/// install options. Step ② and Settings > Mes apps. Each fix is one card in `content` (a future
/// entitlement fix is one more card).
struct CompatibilityFixesSection<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(L("fixes.section"))
                Text(L("fixes.caption"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
            content
        }
    }
}

/// One fix's card: the rows (one per device) on the soft card fill.
struct CompatibilityFixCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The line that says how a fix stands for this app and device, above its full explanation (which
/// never goes away): recommended (brand tint), or why it isn't recommended or available (orange tint).
struct FixStatusLine: View {
    enum Kind { case recommended, caution }
    let text: String
    let kind: Kind

    private var tint: Color { kind == .recommended ? Theme.violet : Color(nsColor: .systemOrange) }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: kind == .recommended ? "sparkles" : "info.circle.fill")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(kind == .recommended ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(kind == .recommended ? 0.12 : 0.16),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// "Request a fix": a new issue on the idea form (`FixRequest`), generic (Settings > Créer &
/// contribuer); the crash window builds its own with the diagnosis (`AppModel.requestFix`).
struct FixRequestButton: View {
    let appName: String?

    var body: some View {
        Button(L("fixes.request.button")) { NSWorkspace.shared.open(FixRequest.url(appName: appName)) }
            .fixedSize()
            .help(L("fixes.request.help"))
    }
}

extension AppModel {
    /// "Request a fix" from a crash: a new issue on the idea form, titled with the app's name, with
    /// the sanitized diagnosis (no bundle id, team id, device name or id) and the fixes that were on.
    func requestFix(for entry: AppEntry, finding: CrashFinding?) {
        let record = entry.record, installation = entry.installation
        let appName = record.options.displayName ?? record.displayName
        let prompt = L("fixes.request.prompt")
        guard let finding else {
            NSWorkspace.shared.open(FixRequest.crashURL(appName: appName, prompt: prompt, details: "No crash diagnosis."))
            return
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let duoOn = installation.duoCompatibility == true && installation.duoCompatibilityMissing != true
        let facts = FixRequest.CrashFacts(
            appVersion: installation.appVersion,
            iOSVersion: devices.first { $0.id == installation.deviceID }?.osVersion,
            xsideVersion: "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            xsideModule: installation.withoutXSideFeatures != true,
            duoCompatibility: duoOn, duoModule: duoOn && record.duo?.needsLegacyModule == true,
            iCloudSignedOut: installation.hasICloudSignedOut)
        let deviceName = devices.first { $0.id == installation.deviceID }?.name ?? cachedNames[installation.deviceID]
        let secrets = [installation.teamID, record.teamID, installation.deviceID, deviceName].compactMap { $0 }
        let ids = [record.originalBundleID, record.signedBundleID] + record.installations.compactMap(\.signedBundleID)
        let details = LogStore.shared.redact(FixRequest.crashDetails(finding.diagnosis, facts: facts, secrets: secrets, appIDs: ids))
        NSWorkspace.shared.open(FixRequest.crashURL(appName: appName, prompt: prompt, details: details))
    }
}
