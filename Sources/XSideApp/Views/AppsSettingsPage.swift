import SwiftUI
import XSideCore

/// Settings > Mes apps: the installed apps (one row per app and device), and for the one
/// selected its XSide-in-app options with where its device stands. Replaces the per-app
/// "Réglages XSide…" window (device feedback 2026-11-08); the "…" menu of a row in the panel opens
/// this page on that app (`AppModel.settingsApp`). Changes are stamped by the Mac and reach the app
/// at its next check-in or signing; "Rafraîchissement automatique" pauses or resumes it right away.
struct AppsSettingsPage: View {
    let model: AppModel

    /// Devices with at least one app, in the panel's order.
    private var groups: [DeviceGroup] { model.deviceGroups.filter { !$0.apps.isEmpty } }

    /// The app shown: the one asked for, else the first one.
    private var selected: AppEntry? {
        let all = groups.flatMap(\.apps)
        return all.first { $0.id == model.settingsApp } ?? all.first
    }

    var body: some View {
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
            HStack(spacing: 0) {
                appList
                    .frame(width: 210)
                Divider()
                if let entry = selected {
                    AppSettingsContent(model: model, entry: entry)
                        .id(entry.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var appList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groups) { group in
                    // The device only matters when there are several.
                    if groups.count > 1 {
                        Label(group.name, systemImage: group.kind == .iPad ? "ipad" : "iphone")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, group.id == groups.first?.id ? 0 : 8)
                            .padding(.bottom, 2)
                    }
                    ForEach(group.apps) { entry in
                        AppListRow(model: model, entry: entry, isSelected: entry.id == selected?.id) {
                            model.settingsApp = entry.id
                        }
                    }
                }
            }
            .padding(10)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// One app in the list: icon, name, a pause mark when its refreshes are paused.
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
                                                  installation: entry.installation)],
                        isDisabled: !model.canManage(entry))
                    Text(L("appSettings.note"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
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
