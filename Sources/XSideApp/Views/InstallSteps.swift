import SwiftUI
import XSideCore

/// ① Appareils · ② Installation · ③ Module XSide dans l'app: where the install window is; each step
/// can be clicked.
struct StepBar: View {
    let flow: InstallFlow

    private static var titles: [String] {
        [L("install.steps.devices"), L("install.steps.options"), L("install.steps.inApp")]
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Self.titles.enumerated()), id: \.offset) { index, title in
                if index > 0 {
                    Capsule()
                        .fill(index <= flow.step ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.primary.opacity(0.12)))
                        .frame(height: 2)
                        .frame(minWidth: 8, maxWidth: 24)
                }
                Button {
                    withAnimation(.smooth(duration: 0.2)) { flow.go(to: index) }
                } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(index <= flow.step ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.cardFill))
                            if index < flow.step {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                            } else {
                                Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .rounded))
                            }
                        }
                        .foregroundStyle(index <= flow.step ? .white : .secondary)
                        .frame(width: 20, height: 20)
                        Text(title)
                            .font(.system(size: 12, weight: index == flow.step ? .semibold : .regular))
                            .foregroundStyle(index == flow.step ? .primary : .secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(index == flow.step ? Theme.violet.opacity(0.12) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("install.steps.a11y", index + 1, Self.titles.count, title))
                .accessibilityAddTraits(index == flow.step ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Step ③: the XSide module in the app for every checked device, with where each device stands.
struct InAppStep: View {
    let model: AppModel
    @Bindable var flow: InstallFlow

    private var appName: String {
        flow.draft.name.isEmpty ? flow.info?.name ?? flow.ipa.deletingPathExtension().lastPathComponent : flow.draft.name
    }

    /// The checked devices; those where the app already is show their status.
    private var lines: [DeviceSyncLine] {
        let record = model.records.first { $0.id == flow.existing?.id }
        return flow.deviceIDs.map { id in
            DeviceSyncLine(deviceID: id, deviceName: model.devices.first { $0.id == id }?.name ?? L("popover.unknownDevice"),
                           installation: record?.installations.first { $0.deviceID == id },
                           lastSeen: record.flatMap { model.channelSeen[JobKey(recordID: $0.id, deviceID: id)] },
                           live: record.map { model.isLive(JobKey(recordID: $0.id, deviceID: id)) } ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L("install.steps.inApp"))
            InAppSettingsSection(
                settings: flow.inApp, appName: appName,
                hasFeatures: Binding(get: { !flow.withoutXSideFeatures }, set: { on in
                    flow.draft.withoutXSideFeatures = !on
                }),
                edit: { change in flow.editInApp(change) },
                statuses: flow.existing == nil ? [] : lines,
                columns: true)
        }
    }
}

/// Without the steps (an app already installed, "Revoir les options" off): every option the
/// install will apply, each group with "Modifier".
struct InstallSummaryView: View {
    let model: AppModel
    let flow: InstallFlow

    var body: some View {
        let info = flow.info
        let duoOn = flow.deviceIDs.filter { flow.duoDevices.contains($0) && model.duoState(for: $0, app: info?.duo).canTurnOn }
        let iCloudOn = model.iCloudState(app: info?.icloud).canTurnOn ? flow.deviceIDs.filter(flow.iCloudDevices.contains) : []
        let lines = InstallSummary.lines(options: flow.draft.options, inApp: flow.inApp,
                                         withoutXSideFeatures: flow.withoutXSideFeatures,
                                         openAppAfter: flow.openAppAfter, openTrustPage: flow.openTrustPage,
                                         offersKeychain: info?.sharedKeychainGroups.isEmpty == false,
                                         duoDevices: duoOn.map(deviceName),
                                         offersDuo: flow.deviceIDs.contains { model.isDuo($0) },
                                         iCloudDevices: iCloudOn.map(deviceName),
                                         offersICloud: info?.icloud?.usesICloud == true)
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(L("install.summary.title"))
            group(L("install.optionsTitle"), lines.install, step: 1)
            group(L("install.steps.inApp"), lines.inApp, step: 2)
            Text(L("install.summary.note", info?.name ?? ""))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func group(_ title: String, _ lines: [InstallSummary.Line], step: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(L("install.summary.edit")) {
                    withAnimation(.smooth(duration: 0.2)) { flow.go(to: step) }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let (name, value) = text(line)
                HStack(alignment: .firstTextBaseline) {
                    Text(name).font(.system(size: 12))
                    Spacer(minLength: 12)
                    Text(value)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            .padding(.vertical, 2)
        }
        .padding(.bottom, 4)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func yesNo(_ on: Bool) -> String { L(on ? "install.summary.yes" : "install.summary.no") }

    private func deviceName(_ id: String) -> String {
        model.devices.first { $0.id == id }?.name ?? L("popover.unknownDevice")
    }

    private func text(_ line: InstallSummary.Line) -> (String, String) {
        switch line {
        case .appUnchanged: (L("install.summary.app"), L("install.summary.asInIPA"))
        case .displayName(let v): (L("install.field.name"), v)
        case .bundleID(let v): (L("install.field.bundleID"), v)
        case .version(let v): (L("install.field.version"), v)
        case .customIcon: (L("install.field.icon"), L("install.summary.custom"))
        case .fileSharing: (L("install.field.fileSharing"), yesNo(true))
        case .iPadFullScreen: (L("install.field.iPadFullScreen"), yesNo(true))
        case .proMotion: (L("install.field.proMotion"), yesNo(true))
        case .minimumOS(let v): (L("install.field.minOS"), v)
        case .shareKeychain(let on):
            (L("install.field.shareKeychain", flow.info.map(InstallOptionsSection.vendor(of:)) ?? ""), yesNo(on))
        case .duoCompatibility(let devices):
            (L("duo.option"), devices.isEmpty ? yesNo(false) : devices.joined(separator: ", "))
        case .iCloudSignedOut(let devices):
            (L("icloud.option"), devices.isEmpty ? yesNo(false) : devices.joined(separator: ", "))
        case .openAppAfter(let on): (L("settings.openAppAfterInstall"), yesNo(on))
        case .openTrustPage(let on): (L("settings.openTrustSettings"), yesNo(on))
        case .xsideFeatures(let on): (L("inApp.features"), yesNo(on))
        case .messages(let level): (L("inApp.messages"), level.label)
        case .showValidity(let on): (InAppOption.showValidity.title, yesNo(on))
        case .alertLate(let on): (InAppOption.alertLate.title, yesNo(on))
        case .refreshCard(let on): (InAppOption.refreshCard.title, yesNo(on))
        case .reminder(let on): (InAppOption.reminder.title, yesNo(on))
        case .language(let language): (L("inApp.language"), language.label)
        case .autoRefresh(let on): (L("inApp.autoRefresh"), yesNo(on))
        }
    }
}
