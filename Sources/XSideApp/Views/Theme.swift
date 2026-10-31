import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XSideCore

/// Colors and shared styles of the "style B" look.
enum Theme {
    static let violet = Color(red: 0x7B / 255, green: 0x5C / 255, blue: 0xFF / 255)
    static let pink = Color(red: 0xC9 / 255, green: 0x6F / 255, blue: 0xAD / 255)
    static let brand = LinearGradient(colors: [violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Soft card fill that works in light and dark mode.
    static let cardFill = Color.primary.opacity(0.05)
    /// Faint brand wash behind the popover's content.
    static let brandWash = LinearGradient(colors: [violet.opacity(0.12), pink.opacity(0.05), .clear],
                                          startPoint: .top, endPoint: .bottom)
    static let hoverFill = Color.primary.opacity(0.06)
    static let reachable = Color(nsColor: .systemGreen)
    static let unreachable = Color(nsColor: .tertiaryLabelColor)
}

/// The big gradient button ("＋ Installer une app", "Installer").
struct GradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .frame(maxWidth: .infinity)
            .background(Theme.brand, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            .shadow(color: Theme.violet.opacity(isEnabled ? 0.25 : 0), radius: 6, y: 2)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

extension Device {
    var symbolName: String { kind == .iPad ? "ipad" : "iphone" }

    /// "USB", "Wi-Fi" or "Out of range".
    var transportLabel: String {
        guard isAvailable else { return L("popover.transport.unreachable") }
        return transport == .usb ? L("popover.transport.usb") : L("popover.transport.wifi")
    }
}

extension OpenWindowAction {
    /// Shows the install window for `url` and brings XSide to the front (it is a menu-bar agent).
    @MainActor func presentInstall(_ url: URL, model: AppModel) {
        model.pendingIPA = url
        self(id: InstallWindow.id)
        NSApp.activate()
    }
}

enum InstallWindow {
    static let id = "install"
}

/// Open panel filtered on `.ipa`. Returns nil when cancelled.
@MainActor func chooseIPA() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    // Opened right after the popover closes: XSide isn't active anymore, and a plain activate()
    // is turned down, leaving the panel behind the other apps.
    NSApp.activate(ignoringOtherApps: true)
    panel.orderFrontRegardless()
    return panel.runModal() == .OK ? panel.url : nil
}
