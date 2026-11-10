import SwiftUI
import XSideCore

/// How the last refresh of an installation ended, for its pending bar (`AppModel.refreshResults`).
enum RefreshResult: Equatable {
    case done(Date)
    /// The reason, in plain words (what the panel's row says).
    case failed(String)
}

extension AppModel {
    /// A refresh just succeeded: the bar says so for a few seconds, then fades.
    func showRefreshDone(_ key: JobKey) {
        let at = Date()
        refreshResults[key] = .done(at)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.refreshResults[key] == .done(at) else { return }
            withAnimation(.easeOut(duration: 0.4)) { self.refreshResults[key] = nil }
        }
    }

    /// The failure's words: the panel row's for an `XSideError`, the generic message otherwise;
    /// a device Xcode can't see is named, with what to do (device round 3, F1).
    static func refreshFailureText(_ error: any Error, deviceName: String) -> String {
        if error as? XSideError == .deviceUnavailable { return L("error.deviceUnavailable.named", deviceName) }
        return (error as? XSideError).map { localizedRowError(key: $0.key) } ?? localizedMessage(error)
    }

    /// The signing-time options of this installation whose choice isn't in the installed copy yet,
    /// read from the library's current state (a switch changed here is in it as soon as stored).
    func pendingSigningChanges(_ entry: AppEntry) -> Set<SigningTimeSetting> {
        let current = currentEntry(entry.id) ?? entry
        let without = current.installation.withoutXSideFeaturesHere == true
            || current.record.options.resolvedWithoutXSideFeatures(default: AppModel.withoutXSideFeaturesByDefault)
        return current.installation.pendingSigningChanges(wantsWithoutXSideFeatures: without)
    }

    /// Why « Rafraîchir maintenant » can't start this installation's refresh now, in plain words
    /// (its help, mega review U2); nil when it can, or when a job on the row is the reason.
    func refreshBlockedReason(_ entry: AppEntry) -> String? {
        let current = currentEntry(entry.id) ?? entry
        if current.installation.refreshPaused { return L("pending.refreshNow.paused") }
        guard !canRefresh(current), jobs[entry.id] == nil, !removingDevices.contains(entry.installation.deviceID) else { return nil }
        if !isPipelineReady { return L("pending.refreshNow.noSigning") }
        return L("pending.refreshNow.deviceAway", deviceWithArticle(DeviceShortName.short(deviceName(entry.installation.deviceID))))
    }

    /// The listed tweaks whose switch or « Injecter quand même » differs from the last signing
    /// (nothing known before a signing with tweaks): their card says « en attente ».
    func pendingTweakIDs(_ entry: AppEntry) -> Set<String> {
        let installation = (currentEntry(entry.id) ?? entry).installation
        guard let signed = installation.signedChoices else { return [] }
        let signedOn = Set(signed.tweaks ?? []), signedForced = Set(signed.forcedTweaks ?? [])
        return Set((installation.tweaks ?? []).filter { u in
            u.enabled != signedOn.contains(u.id) || (u.enabled && (u.force == true) != signedForced.contains(u.id))
        }.map(\.id))
    }
}

/// « l'iPhone Duo » / « the iPhone Duo » for a name that starts with iPhone, iPad or iPod; the
/// name as is otherwise (« Retirer de l'iPad Air 5 », « Retirer de Mac de Léa »).
func deviceWithArticle(_ name: String) -> String {
    let lower = name.lowercased()
    return ["iphone", "ipad", "ipod"].contains(where: lower.hasPrefix) ? L("device.withArticle", name) : name
}

/// The small orange « en attente » on an option or a tweak whose change waits for a refresh.
struct PendingBadge: View {
    var body: some View {
        Text(L("pending.badge"))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(nsColor: .systemOrange))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color(nsColor: .systemOrange).opacity(0.15), in: Capsule())
            .fixedSize()
            .help(L("pending.badge.help"))
    }
}

/// Settings > Mes apps, right under the header (device round 3, R3-2): one bar instead of a
/// notice under each option. « N changements en attente », what they are, « s'appliqueront au
/// prochain rafraîchissement » and « Rafraîchir maintenant ». Then the refresh of this
/// installation, wherever it was started (here, the panel, a notification, the schedule), like
/// the crash box: running (its step and the progress bar, from `AppModel.jobs`), done (green, a
/// few seconds), failed (red, the reason, « Voir le détail » in the panel, « Réessayer »).
/// Nothing when nothing is pending and no refresh is shown.
struct PendingChangesBar: View {
    let model: AppModel
    let entry: AppEntry
    let appName: String
    let deviceName: String

    private static let order: [SigningTimeSetting] = [.xsideModule, .duoCompatibility, .iCloudSignedOut, .tweaks]
    private var job: RefreshJob { RefreshJob(recordID: entry.record.id, deviceID: entry.installation.deviceID) }

    private enum Shown: Equatable { case none, pending, running, done, failed }

    var body: some View {
        let pending = model.pendingSigningChanges(entry)
        let stage = model.jobs[entry.id]
        let result = model.refreshResults[entry.id]
        let shown: Shown = stage != nil ? .running
            : result.map { if case .done = $0 { .done } else { .failed } } ?? (pending.isEmpty ? .none : .pending)
        Group {
            switch shown {
            case .none: EmptyView()
            case .pending: pendingView(pending)
            case .running: running(stage ?? .waiting)
            case .done: if case .done(let at)? = result { done(at) }
            case .failed: if case .failed(let reason)? = result { failed(reason, stillPending: !pending.isEmpty) }
            }
        }
        .animation(.easeOut(duration: 0.25), value: shown)
    }

    private func names(_ pending: Set<SigningTimeSetting>) -> String {
        Self.order.filter(pending.contains).map { L("pending.what.\($0.rawValue)") }.joined(separator: " · ")
    }

    private func pendingView(_ pending: Set<SigningTimeSetting>) -> some View {
        let current = model.currentEntry(entry.id) ?? entry
        let paused = current.installation.refreshPaused
        return bar(tint: Color(nsColor: .systemOrange)) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(pending.count == 1 ? "pending.bar.count.one" : "pending.bar.count", pending.count))
                    .font(.system(size: 12.5, weight: .semibold))
                Text(names(pending) + " — " + L(pending.count == 1 ? "pending.bar.when.one" : "pending.bar.when"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Stopped for this app: no refresh will apply them until it is resumed (mega review U2).
                if paused {
                    Text(L("pending.refreshNow.paused"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if paused {
                Button(L("settings.pause.resume")) { Task { await model.resumeRefreshing(current) } }
                    .controlSize(.small)
                    .disabled(!model.canManage(current))
            } else {
                refreshButton(disabled: !model.canRefresh(current), help: model.refreshBlockedReason(current))
            }
        }
    }

    private func running(_ stage: JobStage) -> some View {
        let installation = (model.currentEntry(entry.id) ?? entry).installation
        let steps = ProgressStep.list(includingWifiCheck: false, includingDuo: installation.duoCompatibility == true,
                                      includingLegacy32: entry.record.legacy32 == true,
                                      includingICloud: installation.iCloudSignedOut == true,
                                      includingTweaks: !installation.enabledTweakIDs.isEmpty)
        let timeline = StepTimeline(steps: steps, stage: stage)
        let percent = model.stepPercent[entry.id]
        let step = stage.label + (percent.map { " " + percentText($0) } ?? "")
        return bar(tint: Theme.violet) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("pending.bar.running", appName, deviceName))
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("pending.bar.step", step, timeline.position, timeline.total))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(timeline.completedCount), total: Double(max(timeline.total, 1)))
                    .progressViewStyle(.linear)
                    .tint(Theme.violet)
                    .accessibilityLabel(L("pending.bar.running", appName, deviceName))
            }
            Spacer(minLength: 8)
            refreshButton(disabled: true)
        }
    }

    private func done(_ at: Date) -> some View {
        let green = Color(nsColor: .systemGreen)
        return bar(tint: green) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("pending.bar.done"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(green)
                Text(L("pending.bar.doneDetail", appName, at.formatted(.dateTime.hour().minute().locale(appLocale)),
                       deviceWithArticle(DeviceShortName.short(deviceName))))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .transition(.opacity)
    }

    private func failed(_ reason: String, stillPending: Bool) -> some View {
        let red = Color(nsColor: .systemRed)
        return bar(tint: red) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("pending.bar.failed"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(red)
                Text(stillPending ? L("pending.bar.failedKept", reason.hasSuffix(".") ? String(reason.dropLast()) : reason) : reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // What the panel shows for a failure: its row, highlighted.
            Button(L("pending.bar.seeDetail")) { Notifier.openPanelHandler?(job) }
                .controlSize(.small)
            Button(L("pending.bar.retry")) { _ = model.refreshNow(job) }
                .controlSize(.small)
                .disabled(!model.canRefresh(model.currentEntry(entry.id) ?? entry))
                .help(model.refreshBlockedReason(entry) ?? "")
        }
        // Listed again at once: « Réessayer » follows the device's state from now on (then every
        // 15 s while Mes apps shows).
        .onAppear {
            #if DEBUG
            if SnapshotRenderer.folder != nil { return } // the harness lists no device
            #endif
            model.refreshDevices()
        }
    }

    private func refreshButton(disabled: Bool, help: String? = nil) -> some View {
        Button(L("pending.refreshNow")) { _ = model.refreshNow(job) }
            .controlSize(.small)
            .disabled(disabled)
            .help(help ?? "")
    }

    private func bar<Content: View>(tint: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) { content() }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
            .accessibilityElement(children: .contain)
    }
}
