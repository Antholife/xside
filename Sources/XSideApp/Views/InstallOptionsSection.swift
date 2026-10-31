import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XSideCore

/// The folded "Options" section: prefilled with the options remembered for the app.
struct InstallOptionsSection: View {
    let model: AppModel
    @Bindable var flow: InstallFlow
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(L("install.options"))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded { grid.transition(.opacity) }
        }
        .padding(10)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var grid: some View {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                field(L("install.field.name"), text: $flow.draft.name, prompt: flow.info?.name)
                field(L("install.field.bundleID"), text: $flow.draft.bundleID, prompt: model.defaultBundleID(for: flow))
                if model.usesNewAppID(flow) { warning(L("install.warning.newBundleID")) }
                field(L("install.field.version"), text: $flow.draft.version, prompt: flow.info?.version)
                iconRow
                toggle(L("install.field.fileSharing"), isOn: $flow.draft.fileSharing)
                toggle(L("install.field.iPadFullScreen"), isOn: $flow.draft.iPadFullScreen)
                toggle(L("install.field.proMotion"), isOn: $flow.draft.proMotion)
                field(L("install.field.minOS"), text: $flow.draft.minOS, prompt: "")
                if !flow.draft.minOS.trimmingCharacters(in: .whitespaces).isEmpty {
                    warning(L("install.warning.minOS"))
                }
                // Only offered when the app asks for shared groups; off unless the user trusts the IPA.
                if let info = flow.info, !info.sharedKeychainGroups.isEmpty {
                    toggle(L("install.field.shareKeychain", info.sharedKeychainVendor ?? Self.vendor(of: info.bundleID)), isOn: $flow.draft.shareKeychain)
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        KeychainShareNote(groups: info.sharedKeychainGroups, isOn: flow.draft.shareKeychain)
                    }
                }
            }
            .font(.system(size: 12))
            .padding(.top, 10)
            .padding(.leading, 4)
            .disabled(flow.isRunning)
    }

    /// "com.google" for com.google.ios.youtube (fallback when the entitlements name no vendor).
    private static func vendor(of bundleID: String) -> String {
        bundleID.split(separator: ".").prefix(2).joined(separator: ".")
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String?) -> some View {
        GridRow {
            label(title)
            TextField(title, text: text, prompt: prompt.map { Text($0) })
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        GridRow {
            label(title)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private func warning(_ text: String) -> some View {
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var iconRow: some View {
        GridRow(alignment: .center) {
            label(L("install.field.icon"))
            HStack(spacing: 8) {
                if let path = flow.draft.iconPath, let image = NSImage(contentsOf: model.iconURL(path)) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                Button(L("install.field.iconChoose"), action: chooseIcon)
                    .controlSize(.small)
                if flow.draft.iconPath != nil {
                    Button {
                        flow.draft.iconPath = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help(L("install.field.iconRemove"))
                    .accessibilityLabel(L("install.field.iconRemove"))
                }
            }
        }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { flow.draft.iconPath = url.path }
    }
}

/// Under "Keychain shared with …": what it's for, the groups asked as small chips, and the risk
/// in orange only once it's turned on.
private struct KeychainShareNote: View {
    let groups: [String]
    let isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("install.keychain.what"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The groups the app declares, for the curious (they come from the app itself).
            FlowChips(items: groups)
            if isOn {
                Label(L("install.keychain.risk"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

/// Small monospaced chips that wrap onto as many lines as needed.
private struct FlowChips: View {
    let items: [String]

    var body: some View {
        WrapLayout(spacing: 4) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.cardFill, in: Capsule())
            }
        }
    }
}

/// Left-to-right layout that starts a new line when the next item doesn't fit.
private struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
