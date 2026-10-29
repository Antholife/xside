import AppKit
import SwiftUI

@main
struct XSideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var engine: BackgroundEngine

    init() {
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

        // The first-launch journey (see `MenuBarLabel` for when it opens by itself).
        Window(L("onboarding.window"), id: WelcomeWindow.id) {
            WelcomeWindowRoot(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// The menu-bar icon. It exists from launch, so it is
/// where Finder's "Open With" / Services get wired to the install window.
private struct MenuBarLabel: View {
    let model: AppModel
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage(JourneyStep.completedKey) private var journeyCompleted = false
    @State private var journeyShown = false

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

    /// Opens the welcome journey once per launch: at once while it was never finished, else the
    /// first time a probe fails (it then opens at the failing step).
    private func showJourneyIfNeeded() {
        guard !journeyShown, !journeyCompleted || model.environmentFailed else { return }
        journeyShown = true
        openWindow.presentJourney(model)
    }

    /// Opens the .ipa received during setup, once the journey is finished and the environment OK.
    private func openQueuedIPA() {
        guard journeyCompleted, !model.environmentFailed, let url = model.queuedIPA else { return }
        model.queuedIPA = nil
        openWindow.presentInstall(url, model: model)
    }

    var body: some View {
        Self.icon
            .onChange(of: model.environmentFailed) {
                showJourneyIfNeeded()
                openQueuedIPA()
            }
            .onChange(of: journeyCompleted) { openQueuedIPA() }
            .onAppear {
                appDelegate.openIPA = { url in
                    if journeyCompleted && !model.environmentFailed {
                        openWindow.presentInstall(url, model: model)
                    } else {
                        model.queuedIPA = url
                        openWindow.presentJourney(model)
                    }
                }
                showJourneyIfNeeded()
                model.showInstallWindow = {
                    openWindow(id: InstallWindow.id)
                    NSApp.activate()
                }
            }
    }
}
