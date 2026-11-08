import SwiftUI
import XSideCore

/// Settings > Mes apps: the installed apps, one row per app, and for the one selected its XSide
/// module options on the right, device by device: settings belong to each installation (app on a
/// device), so an app on several devices gets one tab per device above its options (device
/// feedback round 2, M6: the list used to repeat the app under each device's header, which read
/// as two different apps). Whether the app gets XSide's features at all is the app's, shown the
/// same on each tab. Replaces the per-app "Réglages XSide…" window (device feedback 2026-11-08); the
/// "…" menu of a row in the panel opens this page on that app and device (`AppModel.settingsApp`).
/// Changes are stamped by the Mac and reach the app at its next check-in or signing; "Rafraîchissement
/// automatique" pauses or resumes it right away.
struct AppsSettingsPage: View {
    let model: AppModel

    /// One app and its installations, in the panel's order (by device, then app).
    struct AppItem: Identifiable {
        let record: AppRecord
        var entries: [AppEntry]
        var id: UUID { record.id }
    }

    /// Every app with at least one installation, each once.
    private var items: [AppItem] {
        var result: [AppItem] = []
        for entry in model.deviceGroups.flatMap(\.apps) {
            if let i = result.firstIndex(where: { $0.id == entry.record.id }) {
                result[i].entries.append(entry)
            } else {
                result.append(AppItem(record: entry.record, entries: [entry]))
            }
        }
        return result
    }

    /// The installation shown: the one asked for, else the first.
    private var selected: AppEntry? {
        let all = items.flatMap(\.entries)
        return all.first { $0.id == model.settingsApp } ?? all.first
    }

    var body: some View {
        let items = items
        if items.isEmpty {
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
                appList(items)
                    .frame(width: 210)
                Divider()
                if let entry = selected, let item = items.first(where: { $0.id == entry.record.id }) {
                    AppSettingsContent(model: model, entry: entry, siblings: item.entries)
                        .id(entry.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func appList(_ items: [AppItem]) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    AppListRow(model: model, item: item, isSelected: item.id == selected?.record.id) {
                        // Stays on the device shown when the app has it, else its first.
                        let device = selected?.installation.deviceID
                        model.settingsApp = (item.entries.first { $0.installation.deviceID == device } ?? item.entries[0]).id
                    }
                }
            }
            .padding(10)
            .reportsPaneHeight("list")
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// One app in the list: icon, name, and its devices when it's on several (paused ones marked).
private struct AppListRow: View {
    let model: AppModel
    let item: AppsSettingsPage.AppItem
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    private var deviceNames: String {
        item.entries.map { entry in
            model.deviceGroups.first { $0.id == entry.installation.deviceID }?.name ?? L("popover.unknownDevice")
        }.formatted(.list(type: .and))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AppIconView(icon: model.icons.image(for: item.record),
                            isPaused: item.entries.allSatisfy(\.installation.refreshPaused), size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.record.options.displayName ?? item.record.displayName)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if item.entries.count > 1 {
                        Text(deviceNames)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
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
    /// Every installation of the app (this one included): one tab each when there are several.
    let siblings: [AppEntry]

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
    /// An installation of the app has XSide's module (see `InAppSettingsSection.setDeleteFirst`).
    private var hasModule: Bool {
        entry.record.installations.contains { $0.withoutXSideFeatures != true }
    }
    /// The confirmation's "delete first" choice, handed from its callback to the features binding
    /// set right after it (a box: both run in the same action).
    @State private var deleteFirst = Box()
    final class Box { var value = false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if siblings.count > 1 { devicePicker }
                    InAppSettingsSection(
                        settings: settings, appName: appName,
                        hasFeatures: Binding(get: { hasFeatures }, set: { on in
                            let deletes = !on && deleteFirst.value
                            deleteFirst.value = false
                            Task { await model.setWithoutXSideFeatures(!on, deleteFirst: deletes, recordID: entry.record.id) }
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
                        isDisabled: !model.canManage(entry),
                        setDeleteFirst: hasModule ? { deleteFirst.value = $0 } : nil)
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

    private func name(of e: AppEntry) -> String {
        model.devices.first { $0.id == e.installation.deviceID }?.name
            ?? model.deviceGroups.first { $0.id == e.installation.deviceID }?.name
            ?? L("popover.unknownDevice")
    }

    /// One tab per device: its settings are its own.
    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L("appSettings.device"), selection: Binding(get: { entry.id }, set: { model.settingsApp = $0 })) {
                ForEach(siblings) { e in
                    Text(name(of: e)).tag(e.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(L("appSettings.perDevice", siblings.count))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
