import AppKit
import SwiftUI
import XSideCore

/// `XSide --extract-icon …` is the icon helper (see `AppIconExtractor.runHelper`), handled before
/// anything of the app starts; any other launch is the app.
@main
enum EntryPoint {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == AppIconExtractor.helperFlag {
            exit(AppIconExtractor.runHelper(arguments: Array(arguments.dropFirst(2))))
        }
        XSideApp.main()
    }
}

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
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(JourneyStep.completedKey) private var journeyCompleted = false
    @State private var journeyShown = false

    /// The template glyph from the bundle's `MenuBarIcon.pdf`; falls back to an SF Symbol when it
    /// isn't bundled (e.g. under `swift run`).
    private static let glyph: NSImage? = {
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "XSide")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }()

    /// The glyph, with a small orange (warning) or red (critical) dot when something needs a look.
    private func icon(_ attention: AppModel.Attention?) -> Image {
        guard let glyph = Self.glyph else { return Image(systemName: "arrow.triangle.2.circlepath") }
        guard let attention else { return Image(nsImage: glyph) }
        let key = "\(attention == .critical ? "critical" : "warning").\(colorScheme == .dark ? "dark" : "light")"
        if let cached = Self.badgeCache[key] { return Image(nsImage: cached) }
        let image = Self.badged(glyph, critical: attention == .critical)
        Self.badgeCache[key] = image
        return Image(nsImage: image)
    }

    /// One badged image per level and appearance, made once.
    private static var badgeCache: [String: NSImage] = [:]

    /// Not a template (the dot keeps its color): the glyph is drawn in the menu bar's text color,
    /// resolved at draw time for its light or dark look, with a gap cut around the dot.
    /// Nonisolated: AppKit may run the drawing handler off the main thread.
    private nonisolated static func badged(_ glyph: NSImage, critical: Bool) -> NSImage {
        // The handler only uses this copy, never the main actor's image.
        let mask = glyph.copy() as! NSImage
        let image = NSImage(size: mask.size, flipped: false) { rect in
            mask.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            let dot = NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            (critical ? NSColor.systemRed : NSColor.systemOrange).setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Opens the welcome journey once per launch while it was never finished. Afterwards a failing
    /// probe shows a banner, a notification and the fix in Settings instead.
    private func showJourneyIfNeeded() {
        guard !journeyShown, !journeyCompleted else { return }
        journeyShown = true
        openWindow.presentJourney(model)
    }

    /// Opens the .ipa received during setup, once the journey is finished and the environment OK.
    private func openQueuedIPA() {
        guard journeyCompleted, let url = model.queuedIPA else { return }
        model.queuedIPA = nil
        openWindow.presentInstall(url, model: model)
    }

    var body: some View {
        icon(model.attention)
            // The badged icon is drawn for one appearance: redrawn when the menu bar's changes.
            .id(colorScheme)
            .accessibilityLabel(model.attention == nil ? "XSide" : L("menuBar.attention"))
            .onChange(of: model.environmentFailed) {
                showJourneyIfNeeded()
                openQueuedIPA()
            }
            .onChange(of: journeyCompleted) {
                openQueuedIPA()
                model.updateAttention()
            }
            .onAppear {
                Notifier.openSettingsHandler = { openSettings() }
                appDelegate.quitStopsRefreshes = { [model] in model.quitStopsRefreshes }
                appDelegate.openIPA = { url in
                    if journeyCompleted {
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
