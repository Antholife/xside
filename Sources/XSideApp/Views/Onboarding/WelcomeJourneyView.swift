import AppKit
import os
import SwiftUI

/// The welcome window: progress dots, the current step, then Back / Skip / Continue. Opens at first
/// launch, and at each launch while the environment fails (see `MenuBarLabel`).
struct WelcomeWindowRoot: View {
    let model: AppModel
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        WelcomeJourneyView(model: model)
            .id(language)
            .frame(width: 560, height: 460)
            // Outside `.id` so a language change doesn't report a close/open.
            .background(WindowVisibilityReader { model.onboardingWindowVisibilityChanged($0) })
    }
}

private struct WelcomeJourneyView: View {
    private static let logger = Logger(subsystem: "io.github.xside.XSide", category: "app")

    let model: AppModel
    @AppStorage(JourneyStep.completedKey) private var completed = false
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var forward = true
    @State private var notifications = NotificationPermission()
    @State private var login = LaunchAtLogin()

    private var step: JourneyStep { model.journeyStep }

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(current: step)
                .padding(.top, 6)
            ZStack {
                page
                    .id(step)
                    .transition(.push(from: forward ? .trailing : .leading))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .background { Backdrop().ignoresSafeArea() }
        .onAppear { Self.logger.notice("welcome journey shown at \(String(describing: step), privacy: .public)") }
        // The first probe result can make the saved step unreachable (Xcode uninstalled since).
        .onChange(of: model.environment == nil) { _, pending in
            if !pending { model.capJourneyAtBlockingStep() }
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: WelcomeStepView()
        case .howItWorks: HowItWorksStepView()
        case .goodToKnow: GoodToKnowStepView()
        case .xcode: XcodeStepView(model: model)
        case .account: AccountStepView(model: model)
        case .notifications: NotificationsStepView(permission: notifications)
        case .launchAtLogin: LaunchAtLoginStepView(login: login)
        case .device: DeviceStepView(model: model)
        case .ready: ReadyStepView()
        }
    }

    // MARK: Footer

    /// "Skip" on the explainers (to the checks), and on optional steps whose goal isn't reached yet.
    private var showsSkip: Bool {
        switch step {
        case .howItWorks, .goodToKnow: true
        case .notifications: notifications.state == .notDetermined || notifications.state == .denied
        case .launchAtLogin: !login.isEnabled
        case .device: !model.pairedDevices.contains(where: \.isAvailable)
        default: false
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let previous = step.previous {
                Button { go(to: previous) } label: {
                    Label(L("journey.back"), systemImage: "chevron.left").labelStyle(.titleAndIcon)
                }
                .buttonStyle(JourneyTextButtonStyle())
                .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if showsSkip, let next = step.isExplainer ? .xcode : step.next {
                Button(L("journey.skip")) { go(to: next) }
                    .buttonStyle(JourneyTextButtonStyle())
            }
            Button(step == .ready ? L("journey.finish") : L("journey.continue"), action: advance)
                .buttonStyle(GradientButtonStyle())
                .frame(width: 150)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isJourneyStepDone(step))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .animation(.smooth, value: showsSkip)
    }

    private func advance() {
        guard model.isJourneyStepDone(step) else { return }
        if let next = step.next {
            go(to: next)
        } else {
            completed = true
            model.journeyStep = .welcome
            Self.logger.notice("welcome journey completed")
            dismissWindow(id: WelcomeWindow.id)
        }
    }

    /// The direction is applied first, so the leaving page also slides the right way.
    private func go(to target: JourneyStep) {
        forward = target > step
        Task { @MainActor in
            withAnimation(.smooth(duration: 0.4)) { model.journeyStep = target }
        }
    }
}

/// Window background with a soft brand glow at the top (light and dark).
private struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Theme.violet.opacity(0.16), Theme.pink.opacity(0.05), .clear],
                           center: .top, startRadius: 10, endRadius: 380)
        }
    }
}
