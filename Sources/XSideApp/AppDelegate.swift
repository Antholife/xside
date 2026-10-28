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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
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
            Self.logger.notice("openIPA(\(url.path, privacy: .public))")
            if let openIPA { openIPA(url) } else { pending.append(url) }
        }
    }
}
