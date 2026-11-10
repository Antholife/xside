import AppKit
import SwiftUI
import XSideCore

/// "Simulate signed-out iCloud" for one device: an install option of its own, with or without
/// XSide's module (see `ICloudSignedOut`). Always shown and usable, with any account, always with
/// its full explanation; how it stands for the app (`ICloudSignedOut.OptionState`) is one line
/// above it: recommended for an app whose entitlements declare iCloud (free team), "XSide keeps
/// its iCloud" for that app with a paid team (offered, not recommended), "useful if it crashes
/// because of iCloud" for one that only links CloudKit, "not needed" for one that doesn't use it.
struct ICloudOptionRow: View {
    let state: ICloudSignedOut.OptionState
    let appName: String
    /// Shown under the title when the option is listed for several devices.
    let deviceName: String?
    @Binding var isOn: Bool
    /// The last signing couldn't add it (Settings > Mes apps).
    var missing = false
    /// …because the app had room for one more library only, and XSide's module got it.
    var skippedForModule = false
    /// Settings > Mes apps: its change waits for the next refresh (« en attente »).
    var pending = false
    /// Settings > Mes apps: the explanation (and its details) behind « En savoir plus ».
    var foldsDetails = false
    @State private var showsDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("icloud.option")).font(.system(size: 13))
                    if state.isRecommended {
                        Text(L("icloud.recommended"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.brand, in: Capsule())
                            .fixedSize()
                    }
                    if pending { PendingBadge() }
                }
                if let deviceName {
                    Text(deviceName).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                if let status { FixStatusLine(text: status.text, kind: status.kind) }
                if foldsDetails {
                    FoldedExplanation {
                        captionText
                        ForEach(ICloudDetails.keys, id: \.self) { key in
                            Text(L("icloud.details.\(key)"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    captionText
                    Button(L("icloud.details.title")) { showsDetails.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .popover(isPresented: $showsDetails, arrowEdge: .bottom) { ICloudDetails() }
                }
                if missing {
                    Label(L(skippedForModule ? "icloud.missing.module" : "icloud.missing", appName), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(L("icloud.option"), isOn: Binding(get: { isOn }, set: { on in
                if !on || Self.confirm(app: appName) { isOn = on }
            }))
                .labelsHidden()
                .toggleStyle(.xside)
                .controlSize(.small)
                .help((status.map { $0.text + " " } ?? "") + L("icloud.caption"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(state.isRecommended ? Theme.violet.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var captionText: some View {
        Text(L("icloud.caption"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// How it stands for this app; nil when not known (an app imported by an older XSide).
    private var status: (text: String, kind: FixStatusLine.Kind)? {
        switch state {
        case .recommended: (L("icloud.caption.recommended", appName), .recommended)
        case .keptByPaidTeam: (L("icloud.caption.paidTeam", appName), .neutral)
        case .useful: (L("icloud.caption.useful"), .caution)
        case .notNeeded: (L("icloud.caption.notNeeded"), .caution)
        case .unknown: nil
        }
    }
}

extension ICloudOptionRow {
    /// True when the user confirmed turning it on for `app` (same style as the Duo option's).
    static func confirm(app: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("icloud.confirm.title")
        alert.informativeText = L("icloud.confirm.message", app)
        alert.addButton(withTitle: L("icloud.confirm.turnOn"))
        alert.addButton(withTitle: L("install.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// "Learn more": what the option covers, item by item, and what it doesn't.
private struct ICloudDetails: View {
    static let keys = ["cloudKit", "coreData", "kvs", "drive", "limits"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("icloud.option")).font(.system(size: 13, weight: .semibold))
            ForEach(Self.keys, id: \.self) { key in
                Text(L("icloud.details.\(key)"))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }
}

/// Step ②: the option for each checked device (signing is per device). One card of the
/// compatibility fixes.
struct ICloudOptionsCard: View {
    let model: AppModel
    @Bindable var flow: InstallFlow

    private var appName: String {
        flow.draft.name.isEmpty ? flow.info?.name ?? flow.ipa.deletingPathExtension().lastPathComponent : flow.draft.name
    }

    var body: some View {
        let ids = flow.deviceIDs
        if !ids.isEmpty {
            let state = model.iCloudState(app: flow.info?.icloud)
            CompatibilityFixCard {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    if index > 0 { Divider().padding(.leading, 48) }
                    ICloudOptionRow(state: state, appName: appName,
                                    deviceName: ids.count > 1 ? name(id) : nil,
                                    isOn: Binding(get: { flow.iCloudDevices.contains(id) }, set: { on in
                                        if on { flow.iCloudDevices.insert(id) } else { flow.iCloudDevices.remove(id) }
                                    }))
                }
            }
            .disabled(flow.isRunning)
        }
    }

    private func name(_ id: String) -> String {
        model.deviceName(id)
    }
}

/// After an install: the devices whose copy was installed without the signed-out iCloud asked for.
struct ICloudMissingNotes: View {
    let flow: InstallFlow

    var body: some View {
        let missing = flow.runs.filter { $0.iCloudMissing && $0.status == .succeeded }
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(missing) { run in
                    Label(L(run.iCloudSkippedForModule ? "icloud.missing.install.module" : "icloud.missing.install",
                            run.name, flow.info?.name ?? ""), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
