import AppKit
import SwiftUI
import XSideCore

/// One device's line: whether the app there talks to XSide, and where the Mac's changes stand.
struct DeviceSyncLine: Identifiable {
    let deviceID: String
    let deviceName: String
    /// nil: not installed there yet (the values go with the install).
    let installation: Installation?
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
                    TimelineView(.periodic(from: .now, by: 60)) { context in
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
        line.installation.map { ReachabilityStatus.of(installation: $0, now: now) }
    }

    private var dotColor: Color {
        if case .joinable? = status { return Theme.reachable }
        return Theme.unreachable
    }

    private var reachability: String {
        if !hasFeatures { return L("inApp.reach.noFeatures") }
        switch status {
        case nil: return L("inApp.reach.notInstalled")
        case .joinable?: return L("inApp.reach.joinable")
        case .neverConnected?: return L("inApp.reach.never")
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
        case .pending: return L("inApp.delivery.pending", line.deviceName)
        case .sentWithSigning(let date): return L("inApp.delivery.sent", Self.format(date))
        case .confirmed(let date): return L("inApp.delivery.confirmed", line.deviceName, Self.format(date))
        }
    }

    static func format(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(appLocale))
    }
}
