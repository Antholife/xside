import SwiftUI
import XSideCore

/// Settings > Mes apps: the device first, then its apps, then the selected app's XSide module
/// options on the right (device feedback 3, E6: settings belong to each installation, an app on a
/// device, so the device is picked first; the per-device tabs on the right are gone). Whether the
/// app gets XSide's features at all is the app's, the same on every device. The "…" menu of a row
/// in the panel, and the panel's "Mes apps" button, open this page on that app and device
/// (`AppModel.settingsApp`). Changes are stamped by the Mac and reach the app at its next
/// check-in or signing; "Rafraîchissement automatique" pauses or resumes it right away.
struct AppsSettingsPage: View {
    let model: AppModel

    /// Devices with at least one app, in the panel's order.
    private var groups: [DeviceGroup] { model.deviceGroups.filter { !$0.apps.isEmpty } }

    /// The installation shown: the one asked for, else the first device's first app.
    private var selected: AppEntry? {
        let groups = groups
        let all = groups.flatMap(\.apps)
        return all.first { $0.id == model.settingsApp } ?? groups.first?.apps.first
    }

    var body: some View {
        let groups = groups
        if groups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(L("settings.apps.empty"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let entry = selected
            let group = groups.first { $0.id == entry?.installation.deviceID } ?? groups[0]
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    devicePicker(groups, current: group, entry: entry)
                        .padding([.horizontal, .top], 10)
                    appList(group, selected: entry)
                }
                .frame(width: 210)
                Divider()
                if let entry {
                    AppSettingsContent(model: model, entry: entry)
                        .id(entry.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// The devices: segmented up to three, a menu beyond; the device's name alone when it's the only one.
    @ViewBuilder private func devicePicker(_ groups: [DeviceGroup], current: DeviceGroup, entry: AppEntry?) -> some View {
        if groups.count == 1 {
            Label(current.name, systemImage: (current.kind == .iPad ? "ipad" : "iphone"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            let binding = Binding(get: { current.id }, set: { id in
                guard let group = groups.first(where: { $0.id == id }), let first = group.apps.first else { return }
                // The same app on that device when it has it, else its first.
                model.settingsApp = (group.apps.first { $0.record.id == entry?.record.id } ?? first).id
            })
            if groups.count <= 3 {
                Picker(L("appSettings.device"), selection: binding) {
                    ForEach(groups) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                Picker(L("appSettings.device"), selection: binding) {
                    ForEach(groups) { Label($0.name, systemImage: ($0.kind == .iPad ? "ipad" : "iphone")).tag($0.id) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private func appList(_ group: DeviceGroup, selected: AppEntry?) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(group.apps) { entry in
                    AppListRow(model: model, entry: entry, isSelected: entry.id == selected?.id) {
                        model.settingsApp = entry.id
                    }
                }
            }
            .padding(10)
            .reportsPaneHeight("list", adding: 40) // the device picker above
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// One app of the device: icon and name.
private struct AppListRow: View {
    let model: AppModel
    let entry: AppEntry
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AppIconView(icon: model.icons.image(for: entry.record), isPaused: entry.installation.refreshPaused, size: 24)
                Text(entry.record.options.displayName ?? entry.record.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.violet.opacity(0.28))
                                 : isHovering ? AnyShapeStyle(Theme.hoverFill) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One installation's XSide settings: a brand header (icon, name, device), then the options.
private struct AppSettingsContent: View {
    let model: AppModel
    let entry: AppEntry

    private var appName: String { entry.record.options.displayName ?? entry.record.displayName }
    private var deviceName: String {
        model.devices.first { $0.id == entry.installation.deviceID }?.name
            ?? model.deviceGroups.first { $0.id == entry.installation.deviceID }?.name
            ?? L("popover.unknownDevice")
    }
    private var settings: InAppSettings {
        entry.installation.seededInApp(reminder: AppModel.setting(AppModel.deviceReminderKey), at: entry.installation.installedAt)
    }
    private var hasFeatures: Bool {
        !entry.record.options.resolvedWithoutXSideFeatures(default: AppModel.withoutXSideFeaturesByDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if entry.record.installations.count > 1 {
                        Text(L("appSettings.perDevice", entry.record.installations.count))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    InAppSettingsSection(
                        settings: settings, appName: appName,
                        hasFeatures: Binding(get: { hasFeatures }, set: { on in
                            Task { await model.setWithoutXSideFeatures(!on, recordID: entry.record.id) }
                        }),
                        edit: { change in Task { await model.editInApp(entry.id, change) } },
                        setAutoRefresh: { on in
                            Task {
                                if on {
                                    await model.resumeRefreshing(entry)
                                } else if AppRowAlerts.confirmStopRefreshing(app: appName, device: deviceName) {
                                    // Asked as from the row's "Arrêter de rafraîchir".
                                    await model.stopRefreshing(entry)
                                }
                            }
                        },
                        statuses: [DeviceSyncLine(deviceID: entry.installation.deviceID, deviceName: deviceName,
                                                  installation: entry.installation, lastSeen: model.channelSeen[entry.id],
                                                  live: model.isLive(entry.id))],
                        isDisabled: !model.canManage(entry))
                    Text(L("appSettings.note"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .reportsPaneHeight("detail", adding: 64) // the header above
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIconView(icon: model.icons.image(for: entry.record), isPaused: entry.installation.refreshPaused, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(appName)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(L("appSettings.subtitle", deviceName))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.brand)
    }
}
