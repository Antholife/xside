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

/// « Retrait du code 32 bits (armv7) »: an automatic fix, always listed, no switch. Says whether
/// it applies to this .ipa (`applied`, from the import scan; nil: an app imported before XSide
/// looked), then what it does. The install's progress list has its own step for it.
struct Legacy32InfoRow: View {
    let appName: String
    let applied: Bool?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .opacity(applied == true ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("fixes.legacy32.title")).font(.system(size: 13))
                    Text(L("fixes.legacy32.badge"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                        .fixedSize()
                }
                if let applied {
                    FixStatusLine(text: L(applied ? "fixes.legacy32.applied" : "fixes.legacy32.notApplied", appName),
                                  kind: applied ? .recommended : .neutral)
                }
                Text(L("fixes.legacy32.caption"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // No switch: the text keeps the width of the rows that have one.
            Spacer(minLength: 8)
            Color.clear.frame(width: 40, height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

/// The line that says how a fix stands for this app and device, above its full explanation (which
/// never goes away): recommended (brand tint), or why it isn't recommended or available (orange tint).
struct FixStatusLine: View {
    /// `neutral`: a plain fact, nothing to do (grey).
    enum Kind { case recommended, caution, neutral }
    let text: String
    let kind: Kind

    private var tint: Color {
        switch kind {
        case .recommended: Theme.violet
        case .caution: Color(nsColor: .systemOrange)
        case .neutral: Color.secondary
        }
    }

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
        .background(tint.opacity(kind == .caution ? 0.16 : 0.12),
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
        // The .ipa's own name: a custom display name is the person's choice, not for a public issue.
        let appName = record.displayName
        let prompt = L("fixes.request.prompt")
        guard let finding else {
            NSWorkspace.shared.open(FixRequest.crashURL(appName: appName, prompt: prompt, details: "No crash diagnosis."))
            return
        }
        let info = Bundle.main.infoDictionary ?? [:]
        // What the signed app has (the last signing's outcome), not only what was chosen.
        let duoOn = installation.hasDuoCompatibility
        let facts = FixRequest.CrashFacts(
            appVersion: installation.appVersion,
            iOSVersion: devices.first { $0.id == installation.deviceID }?.osVersion,
            xsideVersion: "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            xsideModule: installation.hasXSideModule,
            duoCompatibility: duoOn, duoModule: duoOn && (installation.duoLegacyModule
                ?? (record.duo?.needsLegacyModule == true)),
            iCloudSignedOut: installation.hasICloudSignedOut)
        let deviceName = devices.first { $0.id == installation.deviceID }?.name ?? cachedNames[installation.deviceID]
        let secrets = [installation.teamID, record.teamID, installation.deviceID, deviceName].compactMap { $0 }
        let ids = [record.originalBundleID, record.signedBundleID] + record.installations.compactMap(\.signedBundleID)
        let details = LogStore.shared.redact(FixRequest.crashDetails(finding.diagnosis, facts: facts, secrets: secrets, appIDs: ids))
        NSWorkspace.shared.open(FixRequest.crashURL(appName: appName, prompt: prompt, details: details))
    }
}
