import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "io.github.xside.XSide", category: "app")

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
            Self.logger.notice("openIPA(\(url.path, privacy: .public))")
            if let openIPA { openIPA(url) } else { pending.append(url) }
        }
    }
}
