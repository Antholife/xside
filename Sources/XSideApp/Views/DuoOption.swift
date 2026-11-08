import AppKit
import SwiftUI
import XSideCore

/// "Add iPhone Duo compatibility" for one device: an install option of its own, with or without
/// XSide's module (see `DuoCompatibility`). Always shown; how depends on the device and the app
/// (`DuoCompatibility.OptionState`): highlighted on a Duo for an app built before SDK 27.1,
/// "not recommended" elsewhere, greyed when the app already fills the Duo or can't use scenes.
/// Turning it on asks first: nobody knows how an app not made for the Duo will look.
struct DuoOptionRow: View {
    let state: DuoCompatibility.OptionState
    let appName: String
    /// Shown under the title when the option is listed for several devices.
    let deviceName: String?
    @Binding var isOn: Bool
    /// The last signing couldn't add it (Settings > Mes apps).
    var missing = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .opacity(state.canTurnOn ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("duo.option")).font(.system(size: 13))
                    if state == .recommended {
                        Text(L("duo.recommended"))
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
                if missing {
                    Label(L("duo.missing", appName), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(state.canTurnOn ? 1 : 0.7)
            Spacer(minLength: 8)
            Toggle(L("duo.option"), isOn: Binding(get: { isOn && state.canTurnOn }, set: { on in
                if !on || Self.confirm(app: appName) { isOn = on }
            }))
            .labelsHidden()
            .toggleStyle(.xside)
            .controlSize(.small)
            .disabled(!state.canTurnOn)
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
        case .recommended: L("duo.caption.recommended", appName) + " " + L("duo.caption")
        case .notADuo: L("duo.caption.notADuo")
        case .unknown: L("duo.caption")
        case .alreadySupported: L("duo.caption.alreadySupported", appName)
        case .noSceneSupport: L("duo.caption.noScenes")
        }
    }

    /// True when the user confirmed turning it on for `app`.
    static func confirm(app: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("duo.confirm.title", app)
        alert.informativeText = L("duo.confirm.message", app)
        alert.addButton(withTitle: L("duo.confirm.turnOn"))
        alert.addButton(withTitle: L("install.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Step ②: the option for each checked device (signing is per device, so only the copies the
/// user picks get it).
struct DuoOptionsCard: View {
    let model: AppModel
    @Bindable var flow: InstallFlow

    private var appName: String {
        flow.draft.name.isEmpty ? flow.info?.name ?? flow.ipa.deletingPathExtension().lastPathComponent : flow.draft.name
    }

    var body: some View {
        let ids = flow.deviceIDs
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(L("duo.section"))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        if index > 0 { Divider().padding(.leading, 48) }
                        DuoOptionRow(state: model.duoState(for: id, app: flow.info?.duo),
                                     appName: appName,
                                     deviceName: ids.count > 1 ? name(id) : nil,
                                     isOn: Binding(get: { flow.duoDevices.contains(id) }, set: { on in
                                         if on { flow.duoDevices.insert(id) } else { flow.duoDevices.remove(id) }
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

/// After an install: the devices whose copy was installed without the compatibility asked for.
struct DuoMissingNotes: View {
    let flow: InstallFlow

    var body: some View {
        let missing = flow.runs.filter { $0.duoMissing && $0.status == .succeeded }
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(missing) { run in
                    Label(L("duo.missing.install", run.name, flow.info?.name ?? ""), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
