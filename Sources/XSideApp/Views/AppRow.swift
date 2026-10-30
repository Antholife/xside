import AppKit
import SwiftUI
import XSideCore

/// One installed app: duration ring, name, next refresh, and the localized error if the last attempt failed.
struct AppRow: View {
    let entry: AppEntry
    /// Step of a running refresh or reinstall, if any.
    let step: JobStage?
    let canRefresh: Bool
    /// No job runs on the row: it can be uninstalled or no longer refreshed.
    let canManage: Bool
    let isUninstalling: Bool
    /// Wi-Fi refresh is off and the device is only on Wi-Fi.
    let needsUSB: Bool
    let deviceName: String
    let onRefresh: () -> Void
    /// Each asks for confirmation first (see `AppRowAlerts`).
    let onUninstall: () -> Void
    let onStopRefreshing: () -> Void

    @State private var isHovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            row(validity: Validity(expiresAt: entry.installation.expiresAt, now: context.date), now: context.date)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isHovering ? Theme.hoverFill : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { actions }
        // VoiceOver can't hover: the menu's actions are actions of the row.
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: L("popover.refreshNow")) { if canRefresh { onRefresh() } }
        .accessibilityAction(named: L("popover.app.uninstallFrom", deviceName)) { if canManage { onUninstall() } }
        .accessibilityAction(named: L("popover.app.stopRefreshing")) { if canManage { onStopRefreshing() } }
    }

    private var appName: String { entry.record.options.displayName ?? entry.record.displayName }

    @ViewBuilder private var actions: some View {
        Button(L("popover.refreshNow"), systemImage: "arrow.clockwise", action: onRefresh)
            .disabled(!canRefresh)
        Divider()
        Button(L("popover.app.uninstallFrom", deviceName), systemImage: "trash", role: .destructive,
               action: onUninstall)
            .disabled(!canManage)
        Button(L("popover.app.stopRefreshing"), systemImage: "stop.circle", action: onStopRefreshing)
            .disabled(!canManage)
    }

    private func row(validity: Validity, now: Date) -> some View {
        HStack(spacing: 10) {
            RingView(validity: validity, isBusy: step != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(appName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle(validity: validity, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(validity.isExpired && step == nil ? Color(nsColor: .systemRed) : .secondary)
                    .lineLimit(1)
                if step == nil, needsUSB,
                   entry.installation.expiresAt.timeIntervalSince(now) <= RefreshPlanner.threshold {
                    Text(L("popover.plugInUSB"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if step == nil, let key = entry.installation.lastErrorKey {
                    Text(localizedRowError(key: key))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if isHovering && canRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(L("popover.refreshNow"))
                .accessibilityLabel(L("popover.refreshNow"))
                .transition(.opacity)
            }
            Menu { actions } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("popover.app.menu", appName))
            .accessibilityLabel(L("popover.app.menu", appName))
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    private func subtitle(validity: Validity, now: Date) -> String {
        if isUninstalling { return L("popover.app.uninstalling") }
        if let step { return step.rowText }
        if validity.isExpired { return L("popover.expired") }
        let next = entry.installation.expiresAt.addingTimeInterval(-RefreshPlanner.threshold)
        guard next > now else { return L("popover.refreshPending") }
        let when = next.formatted(.dateTime.weekday(.wide).hour().minute().locale(appLocale))
        return L("popover.nextRefresh", when)
    }
}

/// The row's confirmations and the uninstall failure, as app-modal alerts: a SwiftUI alert
/// would close with the menu-bar panel, which loses focus as soon as one shows.
@MainActor
enum AppRowAlerts {
    /// True when the user confirmed uninstalling `app` from `device`.
    static func confirmUninstall(app: String, device: String) -> Bool {
        run(title: L("popover.app.uninstallTitle", app, device), message: L("popover.app.uninstallMessage"),
            confirm: L("popover.app.uninstall"), cancel: L("install.cancel"), destructive: true)
    }

    /// True when the user confirmed no longer refreshing `app` on `device`.
    static func confirmStopRefreshing(app: String, device: String) -> Bool {
        run(title: L("popover.app.stopTitle", app), message: L("popover.app.stopMessage", app, device),
            confirm: L("popover.app.stop"), cancel: L("install.cancel"), destructive: true)
    }

    /// Shows why the uninstall failed. True when the user chose to stop refreshing it instead.
    static func uninstallFailed(app: String, device: String, error: any Error) -> Bool {
        run(title: L("popover.app.uninstallFailedTitle", app, device),
            message: localizedMessage(error) + "\n\n" + L("popover.app.uninstallFailedFallback"),
            confirm: L("popover.app.stopRefreshing"), cancel: L("popover.app.close"), destructive: false)
    }

    /// The first button (Return) confirms; the second one (Escape) cancels.
    private static func run(title: String, message: String, confirm: String, cancel: String,
                            destructive: Bool) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let confirmButton = alert.addButton(withTitle: confirm)
        confirmButton.hasDestructiveAction = destructive
        alert.addButton(withTitle: cancel).keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
