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

    /// Set by `XSideApp` before launch finishes: the status item is created from it.
    static var model: AppModel?

    /// XSide's menu-bar icon and its popover (see `StatusPopover`).
    private func installStatusItem() {
        guard let model = Self.model else { return }
        popover.install(label: MenuBarLabel(model: model, appDelegate: self), content: PopoverView(model: model),
                        onVisibilityChange: { model.popoverVisibilityChanged($0) })
        spinner.button = popover.button
        Notifier.openPanelHandler = { [weak self] job in
            if let job { model.highlight(JobKey(recordID: job.recordID, deviceID: job.deviceID)) }
            self?.popover.show()
        }
        Notifier.refreshHandler = { [weak self] job in
            Self.logger.notice("refresh from a notification")
            // Can't start now (device not seen yet, already running, setup to fix): the panel says why.
            if !model.refreshNow(job) {
                model.highlight(JobKey(recordID: job.recordID, deviceID: job.deviceID))
                self?.popover.show()
            }
        }
        if let window = popover.button?.window { menuBarDrop.attach(to: window) }
        #if DEBUG
        // Debug-only: XSIDE_OPEN_POPOVER=1 opens the panel at launch, to look at it.
        if ProcessInfo.processInfo.environment["XSIDE_OPEN_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                // XSIDE_HIGHLIGHT=1: as if a notification about the first app was clicked.
                if ProcessInfo.processInfo.environment["XSIDE_HIGHLIGHT"] == "1",
                   let record = model.records.first, let installation = record.installations.first {
                    model.highlight(JobKey(recordID: record.id, deviceID: installation.deviceID))
                }
                self?.popover.show()
            }
        }
        #endif
    }

    /// Shows the turning arrow on the menu-bar icon while XSide works.
    func setWorking(_ working: Bool) {
        spinner.setWorking(working)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        dockPresence.start()
        installStatusItem()
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

