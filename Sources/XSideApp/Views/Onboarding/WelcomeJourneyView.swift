import AppKit
import os
import SwiftUI
import XSideCore

/// The welcome window: progress dots, the current step, then Back / Skip / Continue. Opens at first
/// launch, and at each launch while the environment fails (see `MenuBarLabel`).
struct WelcomeWindowRoot: View {
    let model: AppModel
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        WelcomeJourneyView(model: model)
            .id(language)
            .frame(width: 600, height: 560)
            // The scene's title is read once: follow the in-app language.
            .navigationTitle(L("onboarding.window"))
            // Outside `.id` so a language change doesn't report a close/open.
            .background(WindowVisibilityReader { model.onboardingWindowVisibilityChanged($0) })
    }
}

private struct WelcomeJourneyView: View {
    private static let logger = Log("app")

    let model: AppModel
    @AppStorage(JourneyStep.completedKey) private var completed = false
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var forward = true
    /// The step's content goes on below the visible area.
    @State private var moreBelow = false
    @State private var notifications = NotificationPermission()
    @State private var login = LaunchAtLogin()

    private var step: JourneyStep { model.journeyStep }

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(current: step)
                .padding(.top, 6)
            ZStack {
                // Only the step scrolls: the dots above and the buttons below stay in view.
                ScrollView(.vertical) {
                    page
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.visible)
                // More below: a fade and a chevron say so (overlay scrollbars stay hidden at rest).
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 4
                } action: { _, more in
                    withAnimation(.easeOut(duration: 0.2)) { moreBelow = more }
                }
                .overlay(alignment: .bottom) {
                    if moreBelow { MoreBelowHint() }
                }
                .id(step)
                .transition(.push(from: forward ? .trailing : .leading))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .background { Backdrop().ignoresSafeArea() }
        .onAppear { Self.logger.notice("welcome journey shown at \(String(describing: step))") }
        // The first probe result can make the saved step unreachable (Xcode uninstalled since).
        .onChange(of: model.environment == nil) { _, pending in
            if !pending { model.capJourneyAtBlockingStep() }
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .language: LanguageStepView()
        case .welcome: WelcomeStepView()
        case .howItWorks: HowItWorksStepView()
        case .goodToKnow: GoodToKnowStepView()
        case .xcode: XcodeStepView(model: model)
        case .account: AccountStepView(model: model)
        case .certificate: CertificateStepView(model: model)
        case .notifications: NotificationsStepView(permission: notifications)
        case .launchAtLogin: LaunchAtLoginStepView(login: login)
        case .device: DeviceStepView(model: model)
        case .ready: ReadyStepView()
        }
    }

    // MARK: Footer

    /// "Skip" only on the explainers, straight to the checks. Optional steps need none: "Continue"
    /// already moves on, and leaving one off (launch at login, notifications) is a choice.
    private var showsSkip: Bool { step.isExplainer }

    private var footer: some View {
        HStack(spacing: 8) {
            if let previous = step.previous {
                Button { go(to: previous) } label: {
                    Label(L("journey.back"), systemImage: "chevron.left").labelStyle(.titleAndIcon)
                }
                .buttonStyle(JourneyTextButtonStyle())
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
            model.journeyStep = .language
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

/// Bottom fade with a bouncing chevron: the step scrolls.
private struct MoreBelowHint: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor).opacity(0), Color(nsColor: .windowBackgroundColor)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 44)
            Image(systemName: "chevron.compact.down")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, options: .repeat(.periodic(delay: 1.5)))
                .padding(.bottom, 4)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
