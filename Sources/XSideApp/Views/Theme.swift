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

/// XSide's switch: drawn like the macOS one (same sizes per control size, a knob that slides),
/// filled with the brand gradient when on, neutral grey when off. Used for every XSide toggle
/// (`.toggleStyle(.xside)`). In a grouped Form the label sits on the left as the system's does
/// (title and note lines), elsewhere the switch follows the label.
struct XSideSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            XSideSwitch(isOn: configuration.$isOn)
        } label: {
            configuration.label
        }
        // VoiceOver reads a switch, with its label and on/off value.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

extension ToggleStyle where Self == XSideSwitchStyle {
    static var xside: XSideSwitchStyle { XSideSwitchStyle() }
}

/// The switch itself: focusable with Tab (keyboard navigation), Space toggles it, and a focus
/// ring in the system's accent color shows where the focus is.
private struct XSideSwitch: View {
    @Binding var isOn: Bool
    @FocusState private var isFocused: Bool
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The system switch's track size for each control size.
    private var size: CGSize {
        switch controlSize {
        case .mini: CGSize(width: 26, height: 15)
        case .small: CGSize(width: 32, height: 18)
        default: CGSize(width: 38, height: 22)
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() }
    }

    var body: some View {
        Button(action: toggle) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.primary.opacity(0.16)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(isOn ? 0 : 0.08), lineWidth: 0.5))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: size.width, height: size.height)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(isEnabled)
        .focused($isFocused)
        .focusEffectDisabled() // the ring below follows the capsule, not a rectangle
        .overlay {
            if isFocused {
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 3)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
        .onKeyPress(.space) {
            toggle()
            return .handled
        }
    }
}
