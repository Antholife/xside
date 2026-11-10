import AppKit
import SwiftUI
import XSideCore

/// "Add iPhone Duo compatibility" for one device: an install option of its own, with or without
/// XSide's module (see `DuoCompatibility`). Always shown with its full explanation; how it stands
/// (`DuoCompatibility.OptionState`) is one line above it: recommended on a Duo for an app built
/// before SDK 27.1, "not recommended" elsewhere, "already compatible" (switch greyed) when the app
/// already fills the Duo. An app without scene support of its own gets XSide's small compatibility
/// module: its explanation says so, with a stronger warning.
/// Turning it on asks first: nobody knows how an app not made for the Duo will look.
struct DuoOptionRow: View {
    let state: DuoCompatibility.OptionState
    let appName: String
    /// Shown under the title when the option is listed for several devices.
    let deviceName: String?
    @Binding var isOn: Bool
    /// The app has no scene support of its own: the option adds XSide's compatibility module.
    var needsModule = false
    /// The app starts from a nib (`DuoAppInfo.mayShowBlack`): it may show black with the option.
    var mayShowBlack = false
    /// The last signing couldn't add it (Settings > Mes apps).
    var missing = false
    /// `isOn` is a choice already stored on an installation (Settings > Mes apps): it shows, and
    /// can be turned off, even when the app's current .ipa no longer allows it (duo review minor 2).
    var storedChoice = false
    /// Settings > Mes apps: its change waits for the next refresh (« en attente »).
    var pending = false
    /// Settings > Mes apps: the explanation (and its details) behind « En savoir plus ».
    var foldsDetails = false
    @State private var showsDetails = false

    /// The switch can be used: to turn it on when possible, or to clear a stored choice.
    private var usable: Bool { state.canTurnOn || (storedChoice && isOn) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .opacity(state.canTurnOn ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 4) {
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
                    if pending { PendingBadge() }
                }
                if let deviceName {
                    Text(deviceName).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                if let status { FixStatusLine(text: status.text, kind: status.kind) }
                if foldsDetails {
                    FoldedExplanation {
                        captionText
                        ForEach(DuoDetails.keys(needsModule: needsModule), id: \.self) { key in
                            Text(L("duo.details.\(key)"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    captionText
                    Button(L("duo.details.title")) { showsDetails.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .popover(isPresented: $showsDetails, arrowEdge: .bottom) { DuoDetails(needsModule: needsModule) }
                }
                if needsModule {
                    Label(L("duo.caption.moduleWarning"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if mayShowBlack {
                    Label(L("duo.caption.nibWarning"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if missing {
                    Label(L("duo.missing", appName), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(L("duo.option"), isOn: Binding(get: { isOn && usable }, set: { on in
                if !on || Self.confirm(app: appName, needsModule: needsModule) { isOn = on }
            }))
            .labelsHidden()
            .toggleStyle(.xside)
            .controlSize(.small)
            .disabled(!usable)
            .help((status.map { $0.text + " " } ?? "") + caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(state == .recommended ? Theme.violet.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var captionText: some View {
        Text(caption)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// How it stands for this app and device; nil when not known (an app imported by an older XSide).
    private var status: (text: String, kind: FixStatusLine.Kind)? {
        switch state {
        case .recommended: (L("duo.status.recommended", appName), .recommended)
        case .notADuo: (L("duo.status.notADuo"), .caution)
        case .alreadySupported: (L("duo.status.alreadySupported", appName), .caution)
        case .unavailable: (L("duo.status.unavailable", appName), .caution)
        case .unknown: nil
        }
    }

    /// What it does and what may go wrong. For an app that already supports the Duo, a neutral
    /// sentence instead: it wasn't "not made for it", and the option would change nothing.
    private var caption: String {
        if state == .alreadySupported { return L("duo.caption.alreadySupported", appName) }
        return L(needsModule ? "duo.caption.module" : "duo.caption")
    }

    /// True when the user confirmed turning it on for `app`.
    static func confirm(app: String, needsModule: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("duo.confirm.title", app)
        alert.informativeText = L(needsModule ? "duo.confirm.messageModule" : "duo.confirm.message", app)
        alert.addButton(withTitle: L("duo.confirm.turnOn"))
        alert.addButton(withTitle: L("install.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// "Learn more": what the option does, what can go wrong, how to undo it, who it is for.
private struct DuoDetails: View {
    let needsModule: Bool

    static func keys(needsModule: Bool) -> [String] {
        [needsModule ? "whatModule" : "what", needsModule ? "riskModule" : "risk", "undo", "onlyDuo"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("duo.option")).font(.system(size: 13, weight: .semibold))
            ForEach(Self.keys(needsModule: needsModule), id: \.self) { key in
                Text(L("duo.details.\(key)"))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }
}

/// Step ②: the option for each checked device (signing is per device, so only the copies the
/// user picks get it). One card of the compatibility fixes.
struct DuoOptionsCard: View {
    let model: AppModel
    @Bindable var flow: InstallFlow

    private var appName: String {
        flow.draft.name.isEmpty ? flow.info?.name ?? flow.ipa.deletingPathExtension().lastPathComponent : flow.draft.name
    }

    var body: some View {
        let ids = flow.deviceIDs
        if !ids.isEmpty {
            CompatibilityFixCard {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    if index > 0 { Divider().padding(.leading, 48) }
                    DuoOptionRow(state: model.duoState(for: id, app: flow.info?.duo),
                                 appName: appName,
                                 deviceName: ids.count > 1 ? name(id) : nil,
                                 isOn: Binding(get: { flow.duoDevices.contains(id) }, set: { on in
                                     if on { flow.duoDevices.insert(id) } else { flow.duoDevices.remove(id) }
                                 }),
                                 needsModule: flow.info?.duo?.needsLegacyModule == true,
                                 mayShowBlack: flow.info?.duo?.mayShowBlack == true)
                }
            }
            .disabled(flow.isRunning)
        }
    }

    private func name(_ id: String) -> String {
        model.deviceName(id)
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
