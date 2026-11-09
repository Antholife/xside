import AppKit
import SwiftUI
import XSideCore

/// One installed app: duration ring, name, next refresh, and the localized error if the last attempt failed.
/// A paused app (the user stopped refreshing it) stays, greyed, until it's resumed or removed.
struct AppRow: View {
    let entry: AppEntry
    /// Step of a running refresh or reinstall, if any.
    let step: JobStage?
    let canRefresh: Bool
    /// No job runs on the row: it can be uninstalled, paused, resumed or removed from the list.
    let canManage: Bool
    let isUninstalling: Bool
    /// Wi-Fi refresh is off and the device is only on Wi-Fi.
    let needsUSB: Bool
    let deviceName: String
    /// The running step's percentage, when its tool reports one.
    var percent: Int?
    /// A notification was about this app: the row glows while the panel opens.
    var isHighlighted = false
    /// The app's icon (custom or its own), nil until known.
    let icon: NSImage?
    let onRefresh: () -> Void
    /// Each asks for confirmation first (see `AppRowAlerts`).
    let onUninstall: () -> Void
    let onStopRefreshing: () -> Void
    /// Pauses this app for a while (device feedback 3, E5), without confirmation: it resumes by itself.
    let onPause: (Date) -> Void
    let onResume: () -> Void
    let onRemoveFromList: () -> Void
    /// Opens Settings > Mes apps on this app and device.
    let onXSideSettings: () -> Void
    /// XSide found the app stopped (at launch, or while in use): a red box under the row, across
    /// its whole width, and a badge on its icon, until dismissed or the notice ends by itself.
    var crash: CrashFlag?
    /// "Why does it crash?": the crash window on this app.
    var onWhyCrash: () -> Void = {}
    /// "Ignore" on the crash box.
    var onDismissCrash: () -> Void = {}
    /// Every automatic refresh is paused (the panel's Pause): the row looks paused too, as for
    /// its own pause (device feedback round 2, M2), but keeps its own actions.
    var globallyPaused = false

    /// This app's own refreshes are stopped (its actions offer Resume).
    private var isPaused: Bool { entry.installation.refreshPaused }
    /// The paused look: its own pause, or the global one.
    private var looksPaused: Bool { isPaused || globallyPaused }

    @State private var isHovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            row(validity: Validity(expiresAt: entry.installation.expiresAt, now: context.date), now: context.date)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isHovering ? Theme.hoverFill : .clear))
        .background { if isHighlighted { HighlightGlow(part: .fill) } }
        .overlay { if isHighlighted { HighlightGlow(part: .border) } }
        .animation(.easeOut(duration: 0.4), value: isHighlighted)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { actions }
        // VoiceOver can't hover: the menu's actions are actions of the row.
        .accessibilityElement(children: .combine)
        .modifier(RowActions(isPaused: isPaused, canRefresh: canRefresh, canManage: canManage,
                             deviceName: deviceName, onRefresh: onRefresh, onUninstall: onUninstall,
                             onStopRefreshing: onStopRefreshing, onResume: onResume,
                             onRemoveFromList: onRemoveFromList))
        .accessibilityAction(named: L("popover.app.xsideSettings"), onXSideSettings)
        .accessibilityAction(named: L("popover.app.whyCrash"), onWhyCrash)
        .modifier(CrashDismissAction(hasCrash: crash != nil, onDismiss: onDismissCrash))
    }

    private var appName: String { entry.record.options.displayName ?? entry.record.displayName }

    @ViewBuilder private var actions: some View {
        Button(L("popover.app.xsideSettings"), systemImage: "slider.horizontal.3", action: onXSideSettings)
        Button(L("popover.app.whyCrash"), systemImage: "stethoscope", action: onWhyCrash)
        Divider()
        if isPaused {
            Button(L("popover.app.resumeRefreshing"), systemImage: "play.circle", action: onResume)
                .disabled(!canManage)
            Divider()
            Button(L("popover.app.uninstallFrom", deviceName), systemImage: "trash", role: .destructive,
                   action: onUninstall)
                .disabled(!canManage)
            Button(L("popover.app.removeFromList"), systemImage: "minus.circle", action: onRemoveFromList)
                .disabled(!canManage)
        } else {
            Button(L("popover.refreshNow"), systemImage: "arrow.clockwise", action: onRefresh)
                .disabled(!canRefresh)
            Divider()
            Button(L("popover.app.uninstallFrom", deviceName), systemImage: "trash", role: .destructive,
                   action: onUninstall)
                .disabled(!canManage)
            // Like the panel's Pause, for this app alone (device feedback 3, E5).
            Menu {
                Button(L("popover.app.pause.hours")) { onPause(Date().addingTimeInterval(2 * 3600)) }
                Button(L("popover.app.pause.day")) { onPause(Date().addingTimeInterval(86_400)) }
                Button(L("settings.pause.untilResumed"), action: onStopRefreshing)
            } label: {
                Label(L("popover.app.pause"), systemImage: "pause.circle")
            }
            .disabled(!canManage)
        }
    }

    /// The row, then the crash box under it at the row's full width (aligned with the icon), so
    /// the row's own layout never changes with it.
    private func row(validity: Validity, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            mainRow(validity: validity, now: now)
            if step == nil, let crash {
                CrashRowBox(flag: crash, appName: appName, onWhy: onWhyCrash, onDismiss: onDismissCrash)
            }
        }
    }

    private func mainRow(validity: Validity, now: Date) -> some View {
        HStack(spacing: 10) {
            AppIconView(icon: icon, isBusy: step != nil || isUninstalling, isPaused: looksPaused,
                        hasCrash: crash != nil && step == nil)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(appName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(looksPaused ? .secondary : .primary)
                        .lineLimit(1)
                    // The version on that device, once an install or refresh has recorded it (the
                    // record's may be a newer .ipa not installed there yet).
                    if let version = entry.installation.appVersion {
                        Text(version)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
                let subtitle = subtitle(validity: validity, now: now)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(validity.isExpired && step == nil && !looksPaused ? Color(nsColor: .systemRed) : .secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(subtitle) // the whole text when it's cut
                // Nothing to plug in nor to fix while paused: no refresh will be attempted.
                if step == nil, !looksPaused, needsUSB,
                   entry.installation.expiresAt.timeIntervalSince(now) <= RefreshPlanner.threshold {
                    Text(L("popover.plugInUSB"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Asked for, but the last signing installed it without (Settings > Mes apps says more).
                if step == nil, entry.installation.duoCompatibility == true, entry.installation.duoCompatibilityMissing == true {
                    Text(L("duo.missing.row"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if step == nil, entry.installation.iCloudSignedOut == true, entry.installation.iCloudSignedOutMissing == true {
                    Text(L(entry.installation.iCloudSignedOutSkippedForModule == true ? "icloud.missing.row.module" : "icloud.missing.row"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if step == nil, !looksPaused, let key = entry.installation.lastErrorKey {
                    Text(localizedRowError(key: key))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            // Refreshing is in the … menu (and the row's context menu and VoiceOver actions).
            RingView(validity: validity, isPaused: looksPaused, isBusy: step != nil || isUninstalling, size: 28)
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
    }

    private func subtitle(validity: Validity, now: Date) -> String {
        if isUninstalling { return L("popover.app.uninstalling") }
        if let step { return percent.map { "\(step.rowText) \(percentText($0))" } ?? step.rowText }
        if isPaused, let end = entry.installation.pausedUntil, end > now {
            return L("popover.app.pausedUntil", end.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(appLocale)))
        }
        if looksPaused {
            // Stopped from the iPhone (its "Rafraîchissement automatique"): said so. The global
            // pause, when the app's own refreshes aren't stopped.
            let prefix = !isPaused ? "popover.pausedAll"
                : entry.installation.pausedBy == .device ? "popover.pausedDevice" : "popover.paused"
            if validity.isExpired { return L(prefix + ".expired") }
            if Calendar.current.isDateInToday(validity.expiresAt) { return L(prefix + ".expiresToday") }
            return L(prefix + ".expiresIn", validity.daysLeft)
        }
        if validity.isExpired { return L("popover.expired") }
        let next = entry.installation.expiresAt.addingTimeInterval(-RefreshPlanner.threshold)
        guard next > now else { return L("popover.refreshPending") }
        let when = next.formatted(.dateTime.weekday(.wide).hour().minute().locale(appLocale))
        return L("popover.nextRefresh", when)
    }
}

/// Under the row, when the app stopped (at launch, or while in use): what happened in a few words,
/// "See why" (the crash window) and "Ignore". Red; orange once a reinstall since waits for the
/// next check.
private struct CrashRowBox: View {
    let flag: CrashFlag
    let appName: String
    let onWhy: () -> Void
    let onDismiss: () -> Void

    private var tint: Color { Color(nsColor: flag.supersededAt == nil ? .systemRed : .systemOrange) }

    var body: some View {
        let cause = CrashWording(flag.diagnosis, app: appName).title
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(L(flag.supersededAt != nil ? "popover.app.crashLine.before"
                       : flag.duringUse == true ? "popover.app.crashLine.inUse" : "popover.app.crashLine", cause))
                    .font(.system(size: 11, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(tint)
            HStack(spacing: 8) {
                Button(L("crash.seeWhy"), action: onWhy)
                    .buttonStyle(CrashFilledButtonStyle(tint: tint))
                Button(L("crash.ignore"), action: onDismiss)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
    }
}

/// VoiceOver: "Ignore" on the row while it shows a crash.
private struct CrashDismissAction: ViewModifier {
    let hasCrash: Bool
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        if hasCrash {
            content.accessibilityAction(named: L("crash.ignore"), onDismiss)
        } else {
            content
        }
    }
}

/// A violet halo pulsing around a row: "this is the one". The fill goes behind the row (the
/// app's icon stays crisp), the border over it.
private struct HighlightGlow: View {
    enum Part { case fill, border }
    let part: Part
    @State private var bright = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        Group {
            switch part {
            case .fill:
                shape.fill(Theme.violet.opacity(bright ? 0.18 : 0.06))
                    .shadow(color: Theme.violet.opacity(bright ? 0.5 : 0), radius: 8)
            case .border:
                shape.strokeBorder(Theme.brand, lineWidth: 1.5).opacity(bright ? 1 : 0.4)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .onAppear {
            // Reduce Motion: lit, without pulsing.
            if reduceMotion { bright = true; return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { bright = true }
        }
    }
}

/// The app's icon in its rounded square, greyed while paused, with a spinner over it while a job
/// runs on the row. A brand-colored square until the icon is known.
struct AppIconView: View {
    let icon: NSImage?
    var isBusy = false
    var isPaused = false
    /// The app stopped at launch: a red badge on its corner.
    var hasCrash = false
    var size: CGFloat = 38

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: size * 0.225, style: .continuous) }

    var body: some View {
        ZStack {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                shape.fill(Theme.brand)
                Image(systemName: "app.dashed")
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            if isBusy {
                shape.fill(.black.opacity(0.35))
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        .saturation(isPaused ? 0 : 1)
        .opacity(isPaused ? 0.6 : 1)
        .overlay(alignment: .bottomTrailing) {
            if hasCrash {
                Image(systemName: "exclamationmark")
                    .font(.system(size: size * 0.24, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(Circle().fill(Color(nsColor: .systemRed)))
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: size * 0.12, y: size * 0.12)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The menu's actions as VoiceOver actions of the row (it can't hover), for the row's state.
private struct RowActions: ViewModifier {
    let isPaused: Bool
    let canRefresh: Bool
    let canManage: Bool
    let deviceName: String
    let onRefresh: () -> Void
    let onUninstall: () -> Void
    let onStopRefreshing: () -> Void
    let onResume: () -> Void
    let onRemoveFromList: () -> Void

    func body(content: Content) -> some View {
        if isPaused {
            content
                .accessibilityAction(named: L("popover.app.resumeRefreshing")) { if canManage { onResume() } }
                .accessibilityAction(named: L("popover.app.uninstallFrom", deviceName)) { if canManage { onUninstall() } }
                .accessibilityAction(named: L("popover.app.removeFromList")) { if canManage { onRemoveFromList() } }
        } else {
            content
                .accessibilityAction(named: L("popover.refreshNow")) { if canRefresh { onRefresh() } }
                .accessibilityAction(named: L("popover.app.uninstallFrom", deviceName)) { if canManage { onUninstall() } }
                .accessibilityAction(named: L("popover.app.stopRefreshing")) { if canManage { onStopRefreshing() } }
        }
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

    /// True when the user confirmed pausing the refreshes of `app` on `device`.
    static func confirmStopRefreshing(app: String, device: String) -> Bool {
        run(title: L("popover.app.stopTitle", app), message: L("popover.app.stopMessage", app, device),
            confirm: L("popover.app.stop"), cancel: L("install.cancel"), destructive: true)
    }

    /// True when the user confirmed forgetting `app` on `device` (it stays on the device).
    static func confirmRemoveFromList(app: String, device: String) -> Bool {
        run(title: L("popover.app.removeTitle", app), message: L("popover.app.removeMessage", device),
            confirm: L("popover.app.remove"), cancel: L("install.cancel"), destructive: true)
    }

    /// True when the user confirmed removing the device from XSide (nothing is uninstalled).
    static func confirmRemoveDevice() -> Bool {
        run(title: L("popover.device.removeTitle"), message: L("popover.device.removeMessage"),
            confirm: L("popover.device.remove"), cancel: L("install.cancel"), destructive: true)
    }

    /// Shows why the uninstall failed. `offerPause`: the alert also offers to stop refreshing it
    /// instead (pointless for a paused app); true when the user chose that.
    static func uninstallFailed(app: String, device: String, error: any Error, offerPause: Bool) -> Bool {
        let title = L("popover.app.uninstallFailedTitle", app, device)
        guard offerPause else {
            run(title: title, message: localizedMessage(error), confirm: nil, cancel: L("popover.app.close"),
                destructive: false)
            return false
        }
        return run(title: title, message: localizedMessage(error) + "\n\n" + L("popover.app.uninstallFailedFallback"),
                   confirm: L("popover.app.stopRefreshing"), cancel: L("popover.app.close"), destructive: false)
    }

    /// The first button (Return) confirms; the second one (Escape) cancels. Without `confirm`,
    /// the only button closes the alert.
    @discardableResult
    private static func run(title: String, message: String, confirm: String?, cancel: String,
                            destructive: Bool) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        guard let confirm else {
            alert.addButton(withTitle: cancel)
            alert.runModal()
            return false
        }
        let confirmButton = alert.addButton(withTitle: confirm)
        confirmButton.hasDestructiveAction = destructive
        alert.addButton(withTitle: cancel).keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
