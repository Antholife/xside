import AppKit
import SwiftUI
import XSideCore

/// One device's line: whether the app there talks to XSide, and where the Mac's changes stand.
struct DeviceSyncLine: Identifiable {
    let deviceID: String
    let deviceName: String
    /// nil: not installed there yet (the values go with the install).
    let installation: Installation?
    /// The Mac's last sight of it in this run (see `AppModel.channelSeen`).
    var lastSeen: Date? = nil
    /// The app is open there now (`AppModel.liveInstallations`, observed: the line flips by itself).
    var live = false
    /// The app's last check-in on this device by an earlier installation (`AppLibrary.lastConnection`).
    var connectedBefore: Date? = nil
    var id: String { deviceID }
}

struct DeviceSyncList: View {
    let lines: [DeviceSyncLine]
    /// The app gets XSide's features (its choice now): without them nothing is sent nor reached.
    let hasFeatures: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L("inApp.status.title"))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(lines) { line in
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        DeviceSyncRow(line: line, hasFeatures: hasFeatures, now: context.date)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct DeviceSyncRow: View {
    let line: DeviceSyncLine
    let hasFeatures: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(line.deviceName).font(.system(size: 12, weight: .semibold))
            }
            Text(reachability)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 13)
            if let delivery {
                Text(delivery)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 13)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var status: ReachabilityStatus? {
        line.installation.map { ReachabilityStatus.of(installation: $0, now: now, lastSeen: line.lastSeen, watching: line.live,
                                                      connectedBefore: line.connectedBefore) }
    }

    /// Green while the app is open (changes arrive live), paler when it is reachable at its next
    /// opening, grey otherwise.
    private var dotColor: Color {
        guard hasFeatures else { return Theme.unreachable }
        switch status {
        case .openNow?: return Theme.reachable
        case .joinable?, .connectedBefore?: return Theme.reachable.opacity(0.45)
        default: return Theme.unreachable
        }
    }

    private var reachability: String {
        if !hasFeatures { return L("inApp.reach.noFeatures") }
        switch status {
        case nil: return L("inApp.reach.notInstalled")
        case .openNow?: return L("inApp.reach.openNow", line.deviceName)
        case .joinable?: return L("inApp.reach.joinable")
        case .neverConnected?: return L("inApp.reach.never")
        case .connectedBefore?: return L("inApp.reach.connectedBefore")
        case .channelComing?: return L("inApp.reach.channelComing")
        case .notSeenSince(let date)?: return L("inApp.reach.notSeen", Self.format(date))
        // Signed without them, turned back on since: they come with the next signing.
        case .noFeatures?: return L("inApp.reach.featuresComing")
        }
    }

    private var delivery: String? {
        guard hasFeatures, let installation = line.installation else { return nil }
        switch SettingsDelivery.of(installation: installation) {
        case .nothing: return nil
        case .pending:
            // What is pending, by name (device feedback 3, E3): "Rafraîchissement automatique : activé — en attente".
            let fields = SettingsDelivery.pendingFields(of: installation)
            guard let s = installation.inApp, !fields.isEmpty else { return L("inApp.delivery.pending", line.deviceName) }
            return L("inApp.delivery.pendingFields", fields.map { Self.describe($0, in: s) }.joined(separator: " · "))
        case .sentWithSigning(let date): return L("inApp.delivery.sent", Self.format(date))
        case .confirmed(let date): return L("inApp.delivery.confirmed", line.deviceName, Self.format(date))
        }
    }

    /// "Rappel avant l'expiration : désactivé".
    static func describe(_ field: InAppField, in s: InAppSettings) -> String {
        func onOff(_ on: Bool) -> String { L(on ? "inApp.value.on" : "inApp.value.off") }
        switch field {
        case .showValidity: return L("inApp.field.value", InAppOption.showValidity.title, onOff(s.showValidity.value))
        case .alertLate: return L("inApp.field.value", InAppOption.alertLate.title, onOff(s.alertLate.value))
        case .refreshCard: return L("inApp.field.value", InAppOption.refreshCard.title, onOff(s.refreshCard.value))
        case .reminder: return L("inApp.field.value", InAppOption.reminder.title, onOff(s.reminder.value))
        case .language: return L("inApp.field.value", L("inApp.language"), s.language.value.label)
        case .autoRefresh: return L("inApp.field.value", L("inApp.autoRefresh"), onOff(s.autoRefresh.value))
        }
    }

    static func format(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(appLocale))
    }
}
