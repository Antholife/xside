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
        content
            // Devices listed at the panel's pace while this page shows (« Réessayer » waits for them).
            .onAppear { model.isMyAppsShown = true }
            .onDisappear { model.isMyAppsShown = false }
    }

    @ViewBuilder private var content: some View {
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
                        // Changes waiting for a refresh (device round 3, R3-1).
                        if !model.pendingSigningChanges(entry).isEmpty {
                            Circle()
                                .fill(Color(nsColor: .systemOrange))
                                .frame(width: 7, height: 7)
                                .help(L("appSettings.row.pending"))
                                .accessibilityLabel(L("appSettings.row.pending"))
                        }
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

/// The three tabs of an app's detail (device round 3, R3-1), remembered from one app to the next.
enum AppSettingsTab: String, CaseIterable {
    case module, fixes, tweaks

    static let storageKey = "appSettings.tab"
    var title: String { L("appSettings.tab.\(rawValue)") }

    /// The signing-time options shown on the tab.
    var settings: Set<SigningTimeSetting> {
        switch self {
        case .module: [.xsideModule]
        case .fixes: [.duoCompatibility, .iCloudSignedOut]
        case .tweaks: [.tweaks]
        }
    }
}

/// One installation's XSide settings: a brand header (icon, name, device), the pending bar, then
/// the three tabs: « Module XSide » (the features switch, the in-app settings, the device status,
/// the note), « Correctifs » (Duo, iCloud, 32 bits) and « Tweaks ».
private struct AppSettingsContent: View {
    let model: AppModel
    let entry: AppEntry
    @AppStorage(AppSettingsTab.storageKey) private var tabName = AppSettingsTab.module.rawValue
    @State private var showsIPAContent = false

    private var tab: AppSettingsTab { AppSettingsTab(rawValue: tabName) ?? .module }
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
        entry.installation.withoutXSideFeaturesHere != true
            && !entry.record.options.resolvedWithoutXSideFeatures(default: AppModel.withoutXSideFeaturesByDefault)
    }
    /// Read from the library's current installation, not the value this view was built with: a
    /// switch changed here is in it as soon as it is stored (device round 2, item 10).
    private var pending: Set<SigningTimeSetting> { model.pendingSigningChanges(entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PendingChangesBar(model: model, entry: entry, appName: appName, deviceName: deviceName)
                .padding([.horizontal, .top], 16)
            tabBar
                .padding(.horizontal, 16)
                .padding(.top, 12)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case .module: moduleTab
                    case .fixes: fixesTab
                    case .tweaks: InstalledTweaksSection(model: model, entry: entry, deviceName: deviceName)
                    }
                }
                .padding(16)
                .reportsPaneHeight("detail", adding: 64 + 44 + barHeight) // the header, the tabs and the bar above
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .sheet(isPresented: $showsIPAContent) {
            IPAContentSheet(model: model, recordID: entry.record.id, appName: appName) { showsIPAContent = false }
        }
    }

    /// Room for the pending bar when it shows.
    private var barHeight: CGFloat {
        pending.isEmpty && (model.jobs[entry.id] == nil || isUninstalling) && model.refreshResults[entry.id] == nil ? 0 : 72
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(AppSettingsTab.allCases, id: \.self) { t in
                tabButton(t)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func pendingCount(_ t: AppSettingsTab) -> Int {
        let n = pending.intersection(t.settings).count
        guard t == .tweaks, n > 0 else { return n }
        return max(1, model.pendingTweakIDs(entry).count)
    }

    private func tabButton(_ t: AppSettingsTab) -> some View {
        let selected = t == tab
        let toSettle = t == .tweaks ? model.tweaksToSettleCount(entry) : 0
        let waiting = pendingCount(t)
        var a11y: [String] = []
        if toSettle > 0 { a11y.append(L("appSettings.tab.toSettle", toSettle)) }
        if waiting > 0 { a11y.append(L(waiting == 1 ? "pending.bar.count.one" : "pending.bar.count", waiting)) }
        return Button {
            tabName = t.rawValue
        } label: {
            HStack(spacing: 6) {
                Text(t.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                if toSettle > 0 {
                    TabBadge(text: L("appSettings.tab.toSettle", toSettle), tint: Color(nsColor: .systemRed))
                }
                if waiting > 0 {
                    TabBadge(text: "\(waiting)", tint: Color(nsColor: .systemOrange))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.clear))
                .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityValue(a11y.joined(separator: ", "))
        .help(a11y.joined(separator: " · "))
    }

    // MARK: « Module XSide »

    @ViewBuilder private var moduleTab: some View {
        if entry.record.installations.count > 1 {
            Text(L("appSettings.perDevice", entry.record.installations.count))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        InAppSettingsSection(
            settings: settings, appName: appName,
            hasFeatures: Binding(get: { hasFeatures }, set: { on in
                Task { await model.setXSideFeatures(on, for: entry) }
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
                                      live: model.isLive(entry.id),
                                      connectedBefore: model.connectedBefore(entry.record, deviceID: entry.installation.deviceID))],
            featuresPending: pending.contains(.xsideModule),
            isDisabled: !model.canManage(entry))
        Text(L("appSettings.note"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        manageZone
    }

    /// « Retirer de la liste » and « Désinstaller de … » (red), found without opening « ⋯ ».
    private var manageZone: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(spacing: 8) {
                Button(L("popover.app.removeFromList"), action: removeFromList)
                    .disabled(!canManage)
                Button(role: .destructive, action: uninstall) {
                    if isUninstalling {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(L("popover.app.uninstalling"))
                        }
                    } else {
                        Text(L("popover.app.uninstallFrom", deviceName))
                            .foregroundStyle(canManage ? Color(nsColor: .systemRed) : .secondary)
                    }
                }
                .disabled(!canManage)
                Spacer(minLength: 0)
            }
            .help(blockedReason ?? "")
        }
        .padding(.top, 4)
    }

    // MARK: « Correctifs »

    private var fixesTab: some View {
        CompatibilityFixesSection {
            duoOption
            iCloudOption
            CompatibilityFixCard { Legacy32InfoRow(appName: appName, applied: entry.record.legacy32, foldsDetails: true) }
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
                            skippedForModule: entry.installation.iCloudSignedOutSkippedForModule == true,
                            pending: pending.contains(.iCloudSignedOut), foldsDetails: true)
            .disabled(!model.canManage(entry))
        }
    }

    /// An install option, not part of the XSide module: applied at this installation's next
    /// signing (a refresh, which the pending bar can start).
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
                         mayShowBlack: entry.record.duo?.mayShowBlack == true,
                         missing: on && entry.installation.duoCompatibilityMissing == true,
                         storedChoice: true, pending: pending.contains(.duoCompatibility), foldsDetails: true)
            .disabled(!model.canManage(entry))
        }
    }

    // MARK: Actions (the panel row's, see `AppActions`)

    private var canManage: Bool { model.canManage(entry) }
    private var blockedReason: String? { model.manageBlockedReason(entry) }
    private var isUninstalling: Bool { model.uninstalling.contains(entry.id) }

    /// Once the app is gone from the list: the device's next app, or the page's own fallback
    /// (another device's first app, or « aucune app »). Not when another app was picked meanwhile.
    private var moveOn: @MainActor () -> Void {
        let gone = entry.id
        let ids = model.deviceGroups.first { $0.id == gone.deviceID }?.apps.map(\.id) ?? []
        let next = AppManagement.selection(afterRemoving: gone, from: ids)
        return { [model] in
            if model.settingsApp == nil || model.settingsApp == gone { model.settingsApp = next }
        }
    }

    private func uninstall() {
        AppActions.uninstall(entry, deviceName: deviceName, model: model, present: AppActions.inWindow, done: moveOn)
    }

    private func removeFromList() {
        AppActions.removeFromList(entry, deviceName: deviceName, model: model, present: AppActions.inWindow, done: moveOn)
    }

    private func stopRefreshing() {
        AppActions.stopRefreshing(entry, deviceName: deviceName, model: model, present: AppActions.inWindow)
    }

    /// « ⋯ » in the header: the panel row's actions, greyed with the reason on hover while busy.
    private var actionsButton: some View {
        Menu {
            ForEach(Array(AppManagement.menu(isPaused: entry.installation.refreshPaused).enumerated()), id: \.offset) { _, item in
                menuItem(item)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(blockedReason ?? L("popover.app.menu", appName))
        .accessibilityLabel(L("popover.app.menu", appName))
    }

    @ViewBuilder private func menuItem(_ item: AppManagement.Item) -> some View {
        switch item {
        case .refresh:
            Button(L("popover.refreshNow"), systemImage: "arrow.clockwise") { _ = model.refreshNow(entry.job) }
                .disabled(!model.canRefresh(entry))
                .help(blockedReason ?? model.refreshBlockedReason(entry) ?? "")
        case .pause:
            Menu {
                AppPauseDurations(onPause: { AppActions.pause(entry, until: $0, model: model) },
                                  onStopRefreshing: stopRefreshing)
            } label: {
                Label(L("popover.app.pause"), systemImage: "pause.circle")
            }
            .disabled(!canManage)
            .help(blockedReason ?? "")
        case .stop:
            Button(L("popover.app.stopRefreshing"), systemImage: "stop.circle", action: stopRefreshing)
                .disabled(!canManage)
                .help(blockedReason ?? "")
        case .resume:
            Button(L("popover.app.resumeRefreshing"), systemImage: "play.circle") { AppActions.resume(entry, model: model) }
                .disabled(!canManage)
                .help(blockedReason ?? "")
        case .separator:
            Divider()
        case .ipaContent:
            // Read only: never greyed.
            Button(L("ipaContent.menu"), systemImage: "doc.text.magnifyingglass") {
                DispatchQueue.main.async { showsIPAContent = true }
            }
        case .removeFromList:
            Button(L("popover.app.removeFromList"), systemImage: "minus.circle", action: removeFromList)
                .disabled(!canManage)
                .help(blockedReason ?? "")
        case .uninstall:
            Button(isUninstalling ? L("popover.app.uninstalling") : L("popover.app.uninstallFrom", deviceName),
                   systemImage: "trash", role: .destructive, action: uninstall)
                .disabled(!canManage)
                .help(blockedReason ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIconView(icon: model.icons.image(for: entry.record), isBusy: model.jobs[entry.id] != nil || isUninstalling,
                        isPaused: entry.installation.refreshPaused, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(appName)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                // « Désinstallation… » as on the panel's row while it runs.
                Text(isUninstalling ? L("appSettings.subtitle", deviceName) + " · " + L("popover.app.uninstalling")
                                    : L("appSettings.subtitle", deviceName))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 0)
            actionsButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.brand)
    }
}

/// A tab's count: « 1 à régler » in red, pending changes in orange.
private struct TabBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint, in: Capsule())
            .fixedSize()
    }
}
