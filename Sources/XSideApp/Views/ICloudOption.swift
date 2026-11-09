import SwiftUI
import XSideCore

/// "Simulate signed-out iCloud" for one device: an install option of its own, with or without
/// XSide's module (see `ICloudSignedOut`). Always shown and usable, with any account; how depends
/// on the app (`ICloudSignedOut.OptionState`): highlighted for an app whose entitlements declare
/// iCloud, "useful if it crashes because of iCloud" for one that only links CloudKit, "not needed"
/// for one that doesn't use it.
struct ICloudOptionRow: View {
    let state: ICloudSignedOut.OptionState
    let appName: String
    /// Shown under the title when the option is listed for several devices.
    let deviceName: String?
    @Binding var isOn: Bool
    /// The last signing couldn't add it (Settings > Mes apps).
    var missing = false
    @State private var showsDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("icloud.option")).font(.system(size: 13))
                    if state == .recommended {
                        Text(L("icloud.recommended"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.brand, in: Capsule())
                            .fixedSize()
                    }
                }
                if let deviceName {
                    Text(deviceName).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("icloud.details.title")) { showsDetails.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .popover(isPresented: $showsDetails, arrowEdge: .bottom) { ICloudDetails() }
                if missing {
                    Label(L("icloud.missing", appName), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(L("icloud.option"), isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.xside)
                .controlSize(.small)
                .help(caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(state == .recommended ? Theme.violet.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var caption: String {
        switch state {
        case .recommended: L("icloud.caption.recommended", appName) + " " + L("icloud.caption")
        case .useful: L("icloud.caption.useful")
        case .unknown: L("icloud.caption")
        case .notNeeded: L("icloud.caption.notNeeded")
        }
    }
}

/// "Learn more": what the option covers, item by item, and what it doesn't.
private struct ICloudDetails: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("icloud.option")).font(.system(size: 13, weight: .semibold))
            ForEach(["cloudKit", "coreData", "kvs", "drive", "limits"], id: \.self) { key in
                Text(L("icloud.details.\(key)"))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }
}

/// Step ②: the option for each checked device (signing is per device).
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
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(L("icloud.section"))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        if index > 0 { Divider().padding(.leading, 48) }
                        ICloudOptionRow(state: state, appName: appName,
                                        deviceName: ids.count > 1 ? name(id) : nil,
                                        isOn: Binding(get: { flow.iCloudDevices.contains(id) }, set: { on in
                                            if on { flow.iCloudDevices.insert(id) } else { flow.iCloudDevices.remove(id) }
                                        }))
                    }
                }
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(flow.isRunning)
            }
        }
    }

    private func name(_ id: String) -> String {
        model.devices.first { $0.id == id }?.name ?? L("popover.unknownDevice")
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
                    Label(L("icloud.missing.install", run.name, flow.info?.name ?? ""), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
