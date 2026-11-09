import SwiftUI
import XSideCore

/// Settings > Mes apps: the device first, then its apps, then the selected app's XSide module
/// options on the right (device feedback 3, E6, laid out again in feedback 5, G2: a device card
/// that opens a menu of the devices, then the device's apps with version and validity; settings belong to each installation, an app on a
/// device, so the device is picked first; the per-device tabs on the right are gone). Whether the
/// app gets XSide's features at all is the app's, the same on every device. The "…" menu of a row
/// in the panel, and the panel header's "Mes apps" button, open this page on that app and device
/// (`AppModel.settingsApp`). Changes are stamped by the Mac and reach the app at once while it's
/// open (its watch), otherwise at its next check-in or signing; "Rafraîchissement automatique"
/// pauses or resumes it right away.
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
                    DeviceChooser(groups: groups, current: group) { picked in
                        guard let first = picked.apps.first else { return }
                        // The same app on that device when it has it, else its first.
                        model.settingsApp = (picked.apps.first { $0.record.id == entry?.record.id } ?? first).id
                    }
                    .padding([.horizontal, .top], 12)
                    .padding(.bottom, 4)
                    appList(group, selected: entry)
                }
                .frame(width: Self.listWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(.background.secondary.opacity(0.5))
                Divider()
                if let entry {
                    AppSettingsContent(model: model, entry: entry)
                        .id(entry.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// The middle column: wide enough for "iPhone Duo de Anthony" on one line beside its icon
    /// (device feedback 5, G2). `SettingsView` widens the window on this page to fit it.
    static let listWidth: CGFloat = 260

    private func appList(_ group: DeviceGroup, selected: AppEntry?) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("appSettings.appsOnDevice"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                ForEach(group.apps) { entry in
                    AppListRow(model: model, entry: entry, isSelected: entry.id == selected?.id) {
                        model.settingsApp = entry.id
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .reportsPaneHeight("list", adding: 84) // the device chooser above
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The device whose apps are listed: a card with its icon, full name and app count. With several
/// devices it opens a menu of them (device feedback 5, G2: the segmented control clipped long
/// names and overflowed its column).
private struct DeviceChooser: View {
    let groups: [DeviceGroup]
    let current: DeviceGroup
    let choose: (DeviceGroup) -> Void

    var body: some View {
        if groups.count == 1 {
            DeviceChooserLabel(group: current, isMenu: false)
                .accessibilityElement(children: .combine)
        } else {
            Menu {
                ForEach(groups) { group in
                    Button {
                        choose(group)
                    } label: {
                        // A checkmark on the device shown, its icon on the others.
                        Label(L("appSettings.deviceItem", group.name, group.apps.count),
                              systemImage: group.id == current.id ? "checkmark" : symbol(group))
                    }
                }
            } label: {
                DeviceChooserLabel(group: current, isMenu: true)
            }
            .menuStyle(.button)
            .buttonStyle(DeviceChooserStyle())
            .menuIndicator(.hidden)
            .accessibilityLabel(L("appSettings.device"))
            .accessibilityValue(current.name)
        }
    }

    private func symbol(_ group: DeviceGroup) -> String { group.kind == .iPad ? "ipad" : "iphone" }
}

private struct DeviceChooserLabel: View {
    let group: DeviceGroup
    let isMenu: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: group.kind == .iPad ? "ipad" : "iphone")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L(group.apps.count == 1 ? "appSettings.appCount.one" : "appSettings.appCount", group.apps.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isMenu {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// The chooser card's hover and press, like the panel's tiles.
private struct DeviceChooserStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DeviceChooserBody(configuration: configuration)
    }
}

private struct DeviceChooserBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.violet.opacity(isHovering ? 0.08 : 0)).allowsHitTesting(false))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// One app of the device: icon, name, version and validity, and a badge while it's paused.
private struct AppListRow: View {
    let model: AppModel
    let entry: AppEntry
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    private var caption: String {
        let validity = Validity(expiresAt: entry.installation.expiresAt, now: Date())
        let expiry = validity.isExpired ? L("popover.expired")
            : Calendar.current.isDateInToday(validity.expiresAt) ? L("appSettings.row.expiresToday")
            : L("appSettings.row.expiresIn", validity.daysLeft)
        let version = entry.installation.appVersion ?? entry.record.options.version ?? entry.record.version
        return version.map { L("appSettings.row.version", $0) + " · " + expiry } ?? expiry
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AppIconView(icon: model.icons.image(for: entry.record), isPaused: entry.installation.refreshPaused, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.record.options.displayName ?? entry.record.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        // Beside the name: the caption keeps the row's width.
                        if entry.installation.refreshPaused {
                            Text(L("appSettings.row.paused"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color(nsColor: .systemOrange))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color(nsColor: .systemOrange).opacity(0.15), in: Capsule())
                                .fixedSize()
                        }
                    }
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                    CompatibilityFixesSection {
                        duoOption
                        iCloudOption
                    }
                }
                .padding(16)
                .reportsPaneHeight("detail", adding: 64) // the header above
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// "Simulate signed-out iCloud": an install option like the Duo one, from the next signing.
    private var iCloudOption: some View {
        let on = entry.installation.iCloudSignedOut == true
        return CompatibilityFixCard {
            ICloudOptionRow(state: model.iCloudState(app: entry.record.icloud), appName: appName, deviceName: nil,
                            isOn: Binding(get: { on }, set: { value in
                                Task { await model.setICloudSignedOut(value, for: entry) }
                            }),
                            missing: on && entry.installation.iCloudSignedOutMissing == true,
                            skippedForModule: entry.installation.iCloudSignedOutSkippedForModule == true)
            .disabled(!model.canManage(entry))
            HStack(spacing: 8) {
                Text(L("duo.nextSigning"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(L("duo.refreshNow")) {
                    _ = model.refreshNow(RefreshJob(recordID: entry.record.id, deviceID: entry.installation.deviceID))
                }
                .controlSize(.small)
                .disabled(!model.canManage(entry))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    /// An install option, not part of the XSide module: applied at this installation's next
    /// signing (a refresh, which can be started from here).
    private var duoOption: some View {
        let on = entry.installation.duoCompatibility == true
        return CompatibilityFixCard {
            DuoOptionRow(state: model.duoState(for: entry.installation.deviceID, app: entry.record.duo,
                                               installation: entry.installation),
                         appName: appName, deviceName: nil,
                         isOn: Binding(get: { on }, set: { value in
                             Task { await model.setDuoCompatibility(value, for: entry) }
                         }),
                         needsModule: entry.record.duo?.needsLegacyModule == true,
                         missing: on && entry.installation.duoCompatibilityMissing == true,
                         storedChoice: true)
            .disabled(!model.canManage(entry))
            HStack(spacing: 8) {
                Text(L("duo.nextSigning"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(L("duo.refreshNow")) {
                    _ = model.refreshNow(RefreshJob(recordID: entry.record.id, deviceID: entry.installation.deviceID))
                }
                .controlSize(.small)
                .disabled(!model.canManage(entry))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
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
