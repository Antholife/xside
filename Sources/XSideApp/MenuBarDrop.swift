import AppKit

/// Lets an `.ipa` be dropped straight on the menu-bar icon (the popover closes as soon as Finder
/// is clicked, so dropping into it is awkward). SwiftUI's `MenuBarExtra` offers no drop target:
/// the status bar window hosting XSide's icon is registered for file drags, and dragging messages
/// it doesn't route to a view reach its delegate (this object). Clicks are untouched.
@MainActor
final class MenuBarDrop: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let onDrop: @MainActor ([URL]) -> Void
    private weak var window: NSWindow?

    init(onDrop: @escaping @MainActor ([URL]) -> Void) {
        self.onDrop = onDrop
    }

    /// Hooks the status bar window, once SwiftUI has created it. False when it isn't there yet,
    /// or already has a delegate (then nothing is touched).
    @discardableResult
    func attach() -> Bool {
        guard window == nil else { return true }
        guard let statusWindow = NSApp.windows.first(where: { $0.className.contains("NSStatusBarWindow") }),
              statusWindow.delegate == nil else { return false }
        statusWindow.registerForDraggedTypes([.fileURL])
        statusWindow.delegate = self
        window = statusWindow
        return true
    }

    private static func ipas(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(AppDelegate.isIPA)
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.ipas(sender).isEmpty ? [] : .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.ipas(sender).isEmpty ? [] : .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.ipas(sender)
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }
}
