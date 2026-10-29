import SwiftUI
import XSideCore

/// One installed app: duration ring, name, next refresh, and the localized error if the last attempt failed.
struct AppRow: View {
    let entry: AppEntry
    /// Step of a running refresh or reinstall, if any.
    let step: JobStage?
    let canRefresh: Bool
    /// Wi-Fi refresh is off and the device is only on Wi-Fi.
    let needsUSB: Bool
    let onRefresh: () -> Void

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
        .contextMenu {
            Button(L("popover.refreshNow"), systemImage: "arrow.clockwise", action: onRefresh)
                .disabled(!canRefresh)
        }
    }

    private func row(validity: Validity, now: Date) -> some View {
        HStack(spacing: 10) {
            RingView(validity: validity, isBusy: step != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.record.options.displayName ?? entry.record.displayName)
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
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    private func subtitle(validity: Validity, now: Date) -> String {
        if let step { return step.rowText }
        if validity.isExpired { return L("popover.expired") }
        let next = entry.installation.expiresAt.addingTimeInterval(-RefreshPlanner.threshold)
        guard next > now else { return L("popover.refreshPending") }
        let when = next.formatted(.dateTime.weekday(.wide).hour().minute().locale(appLocale))
        return L("popover.nextRefresh", when)
    }
}
