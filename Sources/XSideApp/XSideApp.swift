import AppKit
import SwiftUI

@main
struct XSideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var engine: BackgroundEngine

    init() {
        #if DEBUG
        WakeDebug.runIfRequested()
        #endif
        let model = AppModel()
        let engine = BackgroundEngine(model: model)
        _model = State(initialValue: model)
        _engine = State(initialValue: engine)
        engine.start() // idempotent
        LaunchAtLogin.applyDefaultOnFirstLaunch()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            MenuBarLabel(model: model, appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.window)

        // A MenuBarExtra can't be opened programmatically: IPAs from Finder open this window instead.
        Window("XSide", id: InstallWindow.id) {
            InstallWindowRoot(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // Shown at launch when the Mac isn't ready (see `MenuBarLabel`); closes itself once it is.
        Window(L("onboarding.window"), id: OnboardingWindow.id) {
            OnboardingWindowRoot(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
        }
    }
}

/// The menu-bar icon. It exists from launch, so it is
/// where Finder's "Open With" / Services get wired to the install window.
private struct MenuBarLabel: View {
    let model: AppModel
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var onboardingShown = false

    /// The template glyph from the bundle's `MenuBarIcon.pdf`; falls back to an SF Symbol when it
    /// isn't bundled (e.g. under `swift run`).
    private static var icon: Image {
        guard let image = NSImage(named: "MenuBarIcon") else {
            return Image(systemName: "arrow.triangle.2.circlepath")
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return Image(nsImage: image)
    }

    /// Opens the onboarding window the first time a probe fails in this launch.
    private func showOnboardingIfNeeded() {
        guard model.environmentFailed, !onboardingShown else { return }
        onboardingShown = true
        openWindow(id: OnboardingWindow.id)
        NSApp.activate()
    }

    var body: some View {
        Self.icon
            .onChange(of: model.environmentFailed) { showOnboardingIfNeeded() }
            .onAppear {
                appDelegate.openIPA = { url in openWindow.presentInstall(url, model: model) }
                showOnboardingIfNeeded()
                model.showInstallWindow = {
                    openWindow(id: InstallWindow.id)
                    NSApp.activate()
                }
            }
    }
}
