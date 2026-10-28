import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "io.github.xside.XSide", category: "app")

    /// Called for each `.ipa` URL (Open With, double-click, Services, drag and drop).
    /// A later task assigns the real handler.
    var openIPA: @MainActor (URL) -> Void = { url in
        AppDelegate.logger.notice("openIPA(\(url.path, privacy: .public))")
    }

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

    private static func isIPA(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "ipa"
    }

    private func dispatch(_ urls: [URL]) {
        for url in urls where Self.isIPA(url) { openIPA(url) }
    }
}
