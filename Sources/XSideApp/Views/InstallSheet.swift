import AppKit
import SwiftUI
import XSideCore

/// Root of the install window. Re-created on language change so every `L()` text refreshes
/// (the flow state itself lives in `AppModel`).
struct InstallWindowRoot: View {
    let model: AppModel
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let flow = model.install {
                InstallSheet(model: model, flow: flow) {
                    if !model.dismissFlow() { dismissWindow(id: InstallWindow.id) }
                }
            } else {
                InstallDropZone { url in openWindow.presentInstall(url, model: model) }
            }
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(KeepWindowOnScreen())
        .navigationTitle(L("install.title"))
        .id(language)
        .onAppear(perform: model.installWindowAppeared)
        .onDisappear(perform: model.installWindowDisappeared)
    }
}

/// While installing on one device: the app's icon in a progress ring on the brand gradient, what
/// is installed where, and how far along.
private struct ProgressHeader: View {
    let model: AppModel
    let flow: InstallFlow
    let timeline: StepTimeline

    private var fraction: Double { Double(timeline.completedCount) / Double(max(timeline.total, 1)) }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(.white.opacity(0.22), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(fraction, 0.02))
                    .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.5), value: fraction)
                if !timeline.isWaiting { TurningGlint() }
                AppGlyph(iconURL: flow.draft.iconPath.map(model.iconURL) ?? flow.appIcon, size: 66)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            }
            .frame(width: 104, height: 104)
            Text(L("install.progress.title", flow.info?.name ?? flow.ipa.deletingPathExtension().lastPathComponent))
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(L("install.progress.subtitle", flow.runs.first?.name ?? "", min(timeline.completedCount + 1, timeline.total), timeline.total))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 20)
        .padding(.horizontal, 20)
        .background {
            ZStack {
                LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .top, endPoint: .bottomTrailing)
                Circle().fill(.white.opacity(0.16)).frame(width: 260).blur(radius: 50).offset(y: -90)
            }
            .clipped()
            .ignoresSafeArea(edges: .top)
        }
    }
}

/// A short bright arc going round the progress ring while a step runs.
private struct TurningGlint: View {
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.12)
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            .blur(radius: 1)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}

/// The install window with no install yet (opened from the Dock): drop an .ipa, or pick one.
private struct InstallDropZone: View {
    let open: (URL) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Theme.violet.opacity(0.35), radius: 10, y: 4)
                .scaleEffect(isTargeted ? 1.08 : 1)
            VStack(spacing: 4) {
                Text(L("install.empty.title")).font(.system(size: 15, weight: .semibold))
                Text(L("install.empty.text"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(L("install.empty.choose")) {
                if let url = chooseIPA() { open(url) }
            }
            .buttonStyle(GradientButtonStyle())
            .frame(width: 200)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isTargeted ? Theme.violet.opacity(0.12) : Theme.cardFill)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isTargeted ? Theme.violet : Color.primary.opacity(0.15),
                              style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        }
        .padding(20)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: AppDelegate.isIPA) else { return false }
            open(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// App summary, target devices, folded options, Install button and per-step progress (one row
/// per device when installing on several).
struct InstallSheet: View {
    let model: AppModel
    let flow: InstallFlow
    let close: () -> Void
    /// Natural height of the scrolling middle.
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .running(let stage) = flow.phase, !flow.isMultiDevice {
                ProgressHeader(model: model, flow: flow, timeline: StepTimeline(steps: steps, stage: stage))
            } else {
                header
            }
            VStack(alignment: .leading, spacing: 16) {
                // Only the middle scrolls: the app header and the buttons stay in view, and the window
                // never grows past the screen (the options can be long once unfolded).
                // The middle gets its measured height, capped: a ScrollView alone has no ideal height,
                // so the window would stay at its old size and clip everything when the options unfold.
                ScrollView(.vertical) {
                    content
                        .padding(.horizontal, 20)
                        .padding(.vertical, 2)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(contentHeight, Self.maxContentHeight))
                .padding(.horizontal, -20)
                if !model.queuedIPAs.isEmpty { QueueLine(files: model.queuedIPAs) }
                buttons
            }
            .padding(20)
        }
        .animation(.smooth(duration: 0.25), value: flow.phase)
        // An .ipa dropped on the window replaces this one (queued while an install runs).
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: AppDelegate.isIPA) else { return false }
            model.pendingIPA = url
            return true
        }
    }

    /// Room left for the scrolling middle on the current screen, minus header, buttons and chrome.
    private static var maxContentHeight: CGFloat {
        max(240, (NSScreen.main?.visibleFrame.height ?? 800) - 300)
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch flow.phase {
            case .inspecting:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            case .rejected(let message):
                ErrorText(message)
                ExportLogsLink(model: model)
            case .running(let stage) where !flow.isMultiDevice:
                // One device: the header shows the ring, the steps follow, nothing else.
                InstallProgressView(timeline: StepTimeline(steps: steps, stage: stage), showsBar: false)
            case .editing, .running:
                // The run's status comes first, right under the app header.
                if case .running = flow.phase {
                    EmptyView()
                } else if let failure = flow.failure, case .editing = flow.phase {
                    InstallProgressView(timeline: StepTimeline(steps: steps, stage: failure.stage, failed: true),
                                        failureMessage: failure.message)
                    ExportLogsLink(model: model)
                } else if case .editing(let error?) = flow.phase {
                    ErrorText(error)
                } else if case .editing(nil) = flow.phase, flow.wasCancelled {
                    CancelledNote()
                }
                if flow.isRunning && flow.isMultiDevice {
                    DeviceRunList(model: model, flow: flow, steps: steps)
                } else {
                    DevicePicker(model: model, flow: flow)
                }
                InstallOptionsSection(model: model, flow: flow)
                if case .editing = flow.phase {
                    BlockedNotice(model: model, flow: flow)
                    PreflightNotes(warnings: model.preflightWarnings(for: flow), model: model, flow: flow)
                }
            case .finished:
                if flow.isMultiDevice {
                    DeviceRunList(model: model, flow: flow, steps: steps)
                    summary
                    if !flow.failedDeviceIDs.isEmpty { ExportLogsLink(model: model) }
                } else {
                    InstallProgressView(timeline: StepTimeline(
                        steps: steps, current: flow.wifiCheck != nil ? .wifiCheck : nil, skipped: skippedSteps))
                    Label(L("install.success", flow.runs.first?.name ?? ""), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                }
                // Wi-Fi checks one device at a time, then every first-install guide.
                if let check = flow.wifiCheck {
                    WifiCheckView(model: model, flow: flow, check: check,
                                  deviceName: flow.isMultiDevice ? name(of: flow.wifiDeviceID) : nil)
                        .id(flow.wifiDeviceID)
                } else if !flow.isMultiDevice, flow.runs.first?.wifiVerified == true {
                    Label(L("wifi.ok"), systemImage: "wifi")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                }
                if !flow.retryableDeviceIDs.isEmpty, flow.wifiCheck == nil { BlockedNotice(model: model, flow: flow) }
                if flow.wifiCheck == nil {
                    ForEach(flow.guides, id: \.deviceID) { guide in
                        FirstInstallGuideView(guide: guide,
                                              deviceName: flow.isMultiDevice ? name(of: guide.deviceID) : nil)
                            .onAppear { model.guideDisplayed(guide) }
                    }
                }
            }
        }
    }

    /// Steps of the run, fixed up front: Wi-Fi verification is planned or not, never added later.
    private var steps: [ProgressStep] { ProgressStep.list(includingWifiCheck: flow.wifiStepPlanned) }

    /// The Wi-Fi check ended without success (skipped, USB chosen or window closed).
    private var skippedSteps: Set<ProgressStep> {
        guard flow.wifiStepPlanned, case .finished = flow.phase,
              flow.wifiCheck == nil, flow.runs.first?.wifiVerified != true else { return [] }
        return [.wifiCheck]
    }

    private func name(of deviceID: String?) -> String? {
        flow.runs.first { $0.deviceID == deviceID }?.name
    }

    /// Outcome of a run on several devices.
    @ViewBuilder private var summary: some View {
        let done = flow.succeededCount
        if done == flow.runs.count {
            Label(L("install.successMany", done), systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemGreen))
        } else if done > 0 {
            Label(L("install.successSome", done, flow.runs.count), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemOrange))
        } else if !flow.failedDeviceIDs.isEmpty {
            ErrorText(L("install.failedAll")) // with the cancelled note below if some were cancelled
        }
        if flow.wasCancelled { CancelledNote() }
    }

    /// The app on a brand gradient that runs under the hidden title bar, like What's New.
    private var header: some View {
        HStack(spacing: 14) {
            // A custom icon chosen in the options wins over the app's own.
            AppGlyph(iconURL: flow.draft.iconPath.map(model.iconURL) ?? flow.appIcon, size: 60)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(flow.info?.name ?? flow.ipa.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let version = flow.info?.version {
                    Text(L("whatsNew.version", version))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text(flow.info?.bundleID ?? flow.ipa.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            // Another .ipa without starting over: it replaces this one until an install starts.
            if !flow.isBusy {
                Button {
                    if let url = chooseIPA() { model.pendingIPA = url }
                } label: {
                    Label(L("install.changeApp"), systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.18), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L("install.changeApp.help"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .background {
            ZStack {
                Theme.brand
                Circle().fill(.white.opacity(0.16)).frame(width: 240).blur(radius: 40).offset(x: -170, y: -60)
                Circle().fill(Color(red: 1, green: 0.85, blue: 0.3).opacity(0.25)).frame(width: 180)
                    .blur(radius: 50).offset(x: 190, y: 40)
            }
            .clipped()
            .ignoresSafeArea(edges: .top)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            Spacer()
            switch flow.phase {
            case .finished where !flow.retryableDeviceIDs.isEmpty:
                Button(L("install.done"), action: close)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    .disabled(flow.wifiCheck != nil)
                // Only cancelled devices: nothing failed, plain "Retry".
                Button(L(flow.failedDeviceIDs.isEmpty ? "install.retry" : "install.retryFailed"),
                       action: model.retryFailedInstalls)
                    .buttonStyle(GradientButtonStyle())
                    .frame(width: 170)
                    // During the Wi-Fi check, Return is its "Retry".
                    .keyboardShortcut(flow.wifiCheck == nil ? .defaultAction : nil)
                    .disabled(flow.wifiCheck != nil || !model.isPipelineReady)
            case .finished:
                Button(L("install.done"), action: close)
                    .keyboardShortcut(flow.wifiCheck == nil ? .defaultAction : nil)
                    .controlSize(.large)
                    .disabled(flow.wifiCheck != nil)
            case .inspecting, .rejected:
                Button(L("install.cancel"), action: close)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            case .editing, .running:
                if flow.isRunning {
                    // Immediate, even mid-transfer: no confirmation, so no Escape shortcut either.
                    Button(L("install.cancelRun"), action: model.cancelInstall)
                        .controlSize(.large)
                        .disabled(flow.cancelRequested)
                } else {
                    Button(L("install.cancel"), action: close)
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                }
                if !flow.isRunning {
                    Button(installLabel, action: model.startInstall)
                        .buttonStyle(GradientButtonStyle())
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canInstall)
                }
            }
        }
    }

    private var installLabel: String {
        flow.deviceIDs.isEmpty ? L("install.title") : L("install.onDevicesCount", flow.deviceIDs.count)
    }

    private var canInstall: Bool {
        guard !flow.isRunning, case .success? = model.environment else { return false }
        return model.devices.contains { flow.deviceIDs.contains($0.id) && $0.isAvailable }
    }
}

/// Why "Install" (or "Retry failed") can't be pressed: the first check still running, the
/// environment failing (with its fix), or the chosen devices gone.
/// Before the install: what is likely to fail (old iOS, full device, no App ID left).
private struct PreflightNotes: View {
    let warnings: [InstallPreflight.Warning]
    let model: AppModel
    let flow: InstallFlow

    /// Only "last App ID" left: a note, not a warning.
    private var isNoteOnly: Bool { warnings == [.lastAppID] }

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Label(L(isNoteOnly ? "preflight.title.note" : "preflight.title"),
                      systemImage: isNoteOnly ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isNoteOnly ? Color.secondary : Color(nsColor: .systemOrange))
                    .padding(.bottom, 8)
                ForEach(Array(warnings.enumerated()), id: \.offset) { index, warning in
                    if index > 0 { Divider().padding(.vertical, 8) }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(warning))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(text(warning))
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                            if case .deviceFull(let deviceID, _) = warning {
                                let entries = entries(on: deviceID)
                                if !entries.isEmpty {
                                    FreeASlot(model: model, entries: entries, deviceName: name(deviceID))
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isNoteOnly ? Theme.cardFill : Color(nsColor: .systemOrange).opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isNoteOnly ? Color.primary.opacity(0.06) : Color(nsColor: .systemOrange).opacity(0.25),
                              lineWidth: 0.5))
        }
    }

    private func symbol(_ warning: InstallPreflight.Warning) -> String {
        switch warning {
        case .iOSTooOld: "iphone.gen3.slash"
        case .deviceFull: "square.stack.3d.up.fill"
        case .noAppIDLeft, .lastAppID: "number"
        }
    }

    /// XSide's other apps on the device, soonest to expire first: the likeliest to let go.
    private func entries(on deviceID: String) -> [AppEntry] {
        model.records.filter { $0.id != flow.existing?.id }
            .compactMap { r in r.installations.first { $0.deviceID == deviceID }.map { AppEntry(record: r, installation: $0) } }
            .sorted { $0.installation.expiresAt < $1.installation.expiresAt }
    }

    private func name(_ deviceID: String) -> String {
        model.devices.first { $0.id == deviceID }?.name ?? L("popover.unknownDevice")
    }

    private func text(_ warning: InstallPreflight.Warning) -> String {
        switch warning {
        case .iOSTooOld(let id, let required, let actual): L("preflight.iOSTooOld", name(id), actual, required)
        case .deviceFull(let id, _): L("preflight.deviceFull", name(id))
        case .noAppIDLeft: L("preflight.noAppIDLeft")
        case .lastAppID: L("preflight.lastAppID")
        }
    }
}

/// The apps taking a full device's 3 slots, each with "Uninstall": a slot is freed without
/// leaving the install window.
private struct FreeASlot: View {
    let model: AppModel
    let entries: [AppEntry]
    let deviceName: String

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    AppIconView(icon: model.icons.image(for: entry.record), isBusy: model.uninstalling.contains(entry.id),
                                isPaused: entry.installation.refreshPaused, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(appName(entry)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(Validity(expiresAt: entry.installation.expiresAt, now: Date()).spokenText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(L("popover.app.uninstall")) { uninstall(entry) }
                        .controlSize(.small)
                        .disabled(!model.canManage(entry) || model.uninstalling.contains(entry.id))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                if entry.id != entries.last?.id { Divider().padding(.leading, 48) }
            }
        }
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func appName(_ entry: AppEntry) -> String { entry.record.options.displayName ?? entry.record.displayName }

    private func uninstall(_ entry: AppEntry) {
        let app = appName(entry)
        guard AppRowAlerts.confirmUninstall(app: app, device: deviceName) else { return }
        Task {
            do {
                try await model.uninstall(entry)
            } catch {
                if AppRowAlerts.uninstallFailed(app: app, device: deviceName, error: error,
                                                offerPause: !entry.installation.refreshPaused) {
                    await model.stopRefreshing(entry)
                }
            }
        }
    }
}

private struct BlockedNotice: View {
    let model: AppModel
    let flow: InstallFlow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if flow.isRunning {
            EmptyView()
        } else if model.environment == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("install.blocked.checking")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if let error = model.environmentError {
            VStack(alignment: .leading, spacing: 8) {
                ErrorText(error.localizedMessage)
                Group {
                    // A failed check has nothing to fix: checking again is the action.
                    if error.isSetupCheckFailure {
                        Button(L("onboarding.recheck"), action: model.recheckEnvironment)
                            .disabled(model.isProbing)
                    } else {
                        Button(L("environment.banner.fix")) {
                            model.settingsPane = .signing
                            NSApp.activate()
                            openSettings()
                        }
                    }
                }
                .controlSize(.small)
                .padding(.leading, 22)
            }
        } else if case .editing = flow.phase, !flow.deviceIDs.isEmpty,
                  !model.devices.contains(where: { flow.deviceIDs.contains($0.id) && $0.isAvailable }) {
            Label(L("install.noAvailableDevice"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Next: Foo.ipa, Bar.ipa" — files requested while this install runs.
private struct QueueLine: View {
    let files: [URL]

    var body: some View {
        Label(L("install.queued", files.map(\.lastPathComponent).joined(separator: ", ")),
              systemImage: "clock")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
    }
}

/// The paired devices, several can be checked; only reachable ones. "＋ New device" (or no
/// reachable device at all) shows the first-pairing helper, which watches the list and checks the
/// new device.
private struct DevicePicker: View {
    let model: AppModel
    let flow: InstallFlow
    @State private var helperRequested = false
    @State private var knownIDs: Set<String>?
    @State private var detectedName: String?

    private var devices: [Device] { model.pairedDevices }
    private var showHelper: Bool { helperRequested || !devices.contains(where: \.isAvailable) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L("install.installOn"))
            // Tiles, two per row; the last one adds a device.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(devices) { device in
                    DeviceTile(device: device, isSelected: flow.deviceIDs.contains(device.id),
                               wifiRefresh: Binding(get: { model.devicePrefs.wifiRefresh(for: device.id) },
                                                    set: { model.setWifiRefresh($0, for: device.id) }),
                               isRunning: flow.isRunning) {
                        flow.toggle(device.id)
                    }
                    .disabled(!device.isAvailable || flow.isRunning)
                }
                NewDeviceTile(isOpen: showHelper) { helperRequested.toggle() }
                    .disabled(flow.isRunning)
            }
            if let detectedName {
                Label(L("install.newDevice.detected", detectedName), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemGreen))
            }
            if showHelper && !flow.isRunning { NewDeviceHelp() }
        }
        .onAppear { if knownIDs == nil { knownIDs = availableIDs } }
        .onChange(of: model.devices) { _, _ in checkForNewDevice() }
        // Visibility-gated: refreshes only while the helper is on screen (the task ends with the view).
        .task(id: showHelper && !flow.isRunning) {
            guard showHelper, !flow.isRunning else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await model.listDevices()
            }
        }
    }

    private var availableIDs: Set<String> { Set(devices.filter(\.isAvailable).map(\.id)) }

    private func checkForNewDevice() {
        let known = knownIDs ?? []
        defer { knownIDs = availableIDs }
        guard showHelper, !flow.isRunning,
              let device = devices.first(where: { $0.isAvailable && !known.contains($0.id) }) else { return }
        // The new device replaces the default choice, or joins the user's own.
        if !flow.selectionEdited { flow.deviceIDs = [] }
        if !flow.deviceIDs.contains(device.id) { flow.deviceIDs.append(device.id) }
        flow.selectionEdited = true
        helperRequested = false
        detectedName = device.name
        Task {
            try? await Task.sleep(for: .seconds(4))
            if detectedName == device.name { detectedName = nil }
        }
    }
}

/// A device to install on: big symbol, name, iOS and connection, a check when chosen; chosen, it
/// also offers its "Refresh over Wi-Fi" (the popover's per-device setting).
private struct DeviceTile: View {
    let device: Device
    let isSelected: Bool
    @Binding var wifiRefresh: Bool
    let isRunning: Bool
    let select: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Image(systemName: device.symbolName)
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(isSelected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.secondary))
                        Spacer()
                        ZStack {
                            Circle().strokeBorder(isSelected ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1.5)
                            if isSelected {
                                Circle().fill(Theme.violet)
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 18, height: 18)
                    }
                    Text(device.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let os = device.osVersion {
                            Text("iOS \(os)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(device.isAvailable ? Theme.reachable : Theme.unreachable).frame(width: 6, height: 6)
                            Text(device.transportLabel)
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.cardFill, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isSelected {
                Toggle(L("popover.device.wifiRefresh"), isOn: $wifiRefresh)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.violet)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .disabled(isRunning)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(isSelected ? Theme.violet.opacity(0.13) : isHovering ? Theme.hoverFill : Theme.cardFill))
        .overlay(shape.strokeBorder(isSelected ? Theme.violet : Color.primary.opacity(0.06), lineWidth: isSelected ? 1.5 : 0.5))
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The last tile: how to add a device (opens the help below).
private struct NewDeviceTile: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: isOpen ? "xmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.brand)
                Text(L("install.newDevice")).font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The devices of a run on several devices, one row each with its status. The device being
/// installed shows its step timeline under its row.
private struct DeviceRunList: View {
    let model: AppModel
    let flow: InstallFlow
    let steps: [ProgressStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L("install.devices"))
            VStack(spacing: 0) {
                ForEach(flow.runs) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        DeviceRunRow(run: run, symbolName: symbolName(run.deviceID),
                                     checkingWifi: flow.wifiCheck != nil && flow.wifiDeviceID == run.deviceID)
                        if case .running(let stage) = run.status {
                            InstallProgressView(timeline: StepTimeline(steps: steps, stage: stage))
                                .padding(.leading, 28)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    if run.id != flow.runs.last?.id { Divider().padding(.leading, 38) }
                }
            }
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func symbolName(_ deviceID: String) -> String {
        model.devices.first { $0.id == deviceID }?.symbolName ?? "iphone"
    }
}

private struct DeviceRunRow: View {
    let run: DeviceRun
    let symbolName: String
    let checkingWifi: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 16))
                .frame(width: 18)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.name).font(.system(size: 13, weight: .medium))
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(run.isFailed ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            indicator
                .frame(width: 16, height: 16)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch run.status {
        case .waiting: L("install.step.waiting") + "…"
        case .running(let stage): stage.rowText
        case .succeeded where checkingWifi: L("wifi.title") + "…"
        case .succeeded: run.wifiVerified ? L("install.run.doneWifi") : L("install.run.done")
        case .failed(let failure): failure.message
        case .cancelled: L("install.run.cancelled")
        }
    }

    @ViewBuilder private var indicator: some View {
        switch run.status {
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Color(nsColor: .systemRed))
        case .cancelled:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }
}

/// "Install cancelled.": the last run was stopped by the user (not an error).
private struct CancelledNote: View {
    var body: some View {
        Label(L("install.cancelled"), systemImage: "xmark.circle")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

/// The app's icon: the custom one chosen, else the IPA's own, else a placeholder.
struct AppGlyph: View {
    let iconURL: URL?
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let iconURL, let image = NSImage(contentsOf: iconURL) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.brand
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: size * 0.46, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}

/// Under a failure: the logs, zipped and redacted, ready to attach to a GitHub issue.
struct ExportLogsLink: View {
    let model: AppModel

    var body: some View {
        Button {
            Diagnostics.export(model: model)
        } label: {
            Label(L("logs.exportLink"), systemImage: "doc.text.magnifyingglass")
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
    }
}

struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.octagon.fill")
        }
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: .systemRed))
    }
}
