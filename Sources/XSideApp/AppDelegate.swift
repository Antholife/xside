import AppKit
import os
import XSideCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Log("app")

    /// Called for each `.ipa` URL (Open With, double-click, Services). URLs that arrive before a
    /// handler is installed (cold launch from Finder) are kept and delivered once it is set.
    var openIPA: (@MainActor (URL) -> Void)? {
        didSet {
            guard let openIPA else { return }
            let queued = pending
            pending.removeAll()
            queued.forEach(openIPA)
        }
    }
    private var pending: [URL] = []
    private let dockPresence = DockPresence()
    private lazy var menuBarDrop = MenuBarDrop { [weak self] urls in self?.dispatch(urls) }
    private let spinner = MenuBarSpinner()
    let popover = StatusPopover()

    /// Opens the panel as a popover from the status item (see `StatusPopover`). The item may not
    /// exist yet at launch: retried for a few seconds.
    func attachPopover(model: AppModel, attempt: Int = 0) {
        let attached = popover.attach(content: { PopoverView(model: model) },
                                      onVisibilityChange: { model.popoverVisibilityChanged($0) })
        #if DEBUG
        // Debug-only: XSIDE_OPEN_POPOVER=1 opens the panel at launch, to look at it.
        if attached, ProcessInfo.processInfo.environment["XSIDE_OPEN_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.popover.show() }
        }
        #endif
        if attached { Self.logger.notice("popover attached (attempt \(attempt))") }
        guard !attached, attempt < 20 else {
            if !attached { Self.logger.error("popover not attached: no status item button") }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.attachPopover(model: model, attempt: attempt + 1)
        }
    }

    /// Shows the turning arrow on the menu-bar icon while XSide works. The status item may not
    /// exist yet at launch: retried for a few seconds.
    func setWorking(_ working: Bool, attempt: Int = 0) {
        guard !spinner.setWorking(working), attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.setWorking(working, attempt: attempt + 1)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        dockPresence.start()
        attachMenuBarDrop(attempt: 0)
        #if DEBUG
        // Debug-only: XSIDE_APPEARANCE=dark|light forces the appearance, to check both looks.
        switch ProcessInfo.processInfo.environment["XSIDE_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        #endif
    }

    /// True while quitting would stop the refresh of a valid app (set by the menu-bar label).
    var quitStopsRefreshes: (@MainActor () -> Bool)?

    /// Every quit (popover button, ⌘Q, Dock, `osascript`) is confirmed while an app would expire
    /// without its refresh, except a logout, restart or shutdown, which is never held up.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard quitStopsRefreshes?() == true, !Self.isSystemQuit() else { return .terminateNow }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("quit.confirm.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("popover.quit"))
        alert.addButton(withTitle: L("install.cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// The quit comes from a logout, restart or shutdown (`kAEQuitReason` of the quit event).
    private static func isSystemQuit() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue
                ?? event.paramDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue else { return false }
        let system: Set<OSType> = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog,
                                   kAERestart, kAEShutDown]
        return system.contains(reason)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        dispatch(urls)
    }

    @objc func installIPA(_ pboard: NSPasteboard, userData: String?,
                          error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self],
                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard urls.contains(where: Self.isIPA) else {
            error.pointee = L("services.noIPA") as NSString
            return
        }
        dispatch(urls)
    }

    /// The status item appears shortly after launch: retry for a few seconds.
    private func attachMenuBarDrop(attempt: Int) {
        guard !menuBarDrop.attach(), attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.attachMenuBarDrop(attempt: attempt + 1)
        }
    }

    static func isIPA(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "ipa"
    }

    private func dispatch(_ urls: [URL]) {
        for url in urls where Self.isIPA(url) {
            Self.logger.notice("openIPA(\(url.path))")
            if let openIPA { openIPA(url) } else { pending.append(url) }
        }
    }
}
