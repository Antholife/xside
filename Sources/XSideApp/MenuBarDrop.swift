import AppKit

/// Lets an `.ipa` be dropped straight on the menu-bar icon (the popover closes as soon as Finder
/// is clicked, so dropping into it is awkward): the status bar window hosting XSide's icon is
/// registered for file drags, and dragging messages it doesn't route to a view reach its
/// delegate (this object). Clicks are untouched.
@MainActor
final class MenuBarDrop: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let onDrop: @MainActor ([URL]) -> Void
    private weak var window: NSWindow?

    init(onDrop: @escaping @MainActor ([URL]) -> Void) {
        self.onDrop = onDrop
    }

    /// Hooks the status item's window (left alone if it already has a delegate).
    func attach(to statusWindow: NSWindow) {
        guard window == nil, statusWindow.delegate == nil else { return }
        statusWindow.registerForDraggedTypes([.fileURL])
        statusWindow.delegate = self
        window = statusWindow
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
