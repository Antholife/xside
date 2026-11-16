import AppKit
import SwiftUI
import XSideCore

/// "Source de mise à jour" in the install window: an optional GitHub link, what to do when a
/// release comes out, and (once the repo's files are known) which variant to follow. The link is
/// validated by `GitHubSource.parse`; the releases are read off the main actor.
struct UpdateSourceSection: View {
    let model: AppModel
    @Bindable var flow: InstallFlow

    /// What the last look at the repo's releases found (names of the newest release's `.ipa`s).
    private enum Check: Equatable {
        case idle, checking, failed, none
        case found([String])
    }
    @State private var check = Check.idle
    /// The file the variant was derived from, only while it belongs to the repo now in the field.
    private var chosenName: String? {
        flow.draft.updateVariant != nil && flow.draft.updateVariantSource == parsed ? flow.draft.updateVariantName : nil
    }

    private var parsed: GitHubSource? { GitHubSource.parse(flow.draft.updateSourceURL) }
    private var isEmpty: Bool { flow.draft.updateSourceURL.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L("update.source.title"))
            VStack(alignment: .leading, spacing: 0) {
                OptionRow(symbol: "arrow.down.circle.fill", title: L("update.source.link"),
                          detail: L("update.source.link.note")) { EmptyView() }
                HStack(spacing: 8) {
                    TextField(L("update.source.link"), text: $flow.draft.updateSourceURL,
                              prompt: Text(L("update.source.placeholder")))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled()
                        .onSubmit { Task { await look() } }
                    statusPill
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 9)
                statusDetail
                if !isEmpty, parsed != nil {
                    Divider().padding(.leading, 48)
                    OptionRow(symbol: "bolt.fill", title: L("update.mode.title"), detail: nil) {
                        Picker(L("update.mode.title"), selection: $flow.draft.updateMode) {
                            Text(L("update.mode.notify")).tag(UpdateMode.notify)
                            Text(L("update.mode.auto")).tag(UpdateMode.auto)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    Label(L("update.mode.note"), systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 48)
                        .padding(.trailing, 12)
                        .padding(.bottom, 10)
                }
            }
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(flow.isRunning)
        }
        // A new link (or a valid one first typed) is looked at once the typing pauses.
        .task(id: flow.draft.updateSourceURL) {
            // A variant already chosen for this very repo (the view was rebuilt): keep it.
            if chosenName != nil { return }
            // Otherwise the variant belongs to another repo (or none): drop it.
            check = .idle
            flow.draft.updateVariant = nil
            flow.draft.updateVariantSource = nil
            flow.draft.updateVariantName = nil
            guard parsed != nil else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await look()
        }
    }

    @ViewBuilder private var statusPill: some View {
        if !isEmpty {
            if parsed != nil {
                Label(L("update.source.recognized"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemGreen))
            } else {
                Label(L("update.source.invalid"), systemImage: "xmark.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
        }
    }

    @ViewBuilder private var statusDetail: some View {
        if parsed != nil {
            Group {
                switch check {
                case .idle:
                    if let chosenName { note(L("update.source.tracking", chosenName), symbol: "checkmark.seal.fill", orange: false) }
                case .checking:
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(L("update.source.checking")) }
                case .failed:
                    note(L("update.source.failed"), symbol: "exclamationmark.triangle.fill", orange: true)
                case .none:
                    note(L("update.source.noAsset"), symbol: "exclamationmark.triangle.fill", orange: true)
                case .found(let names):
                    if let chosenName {
                        HStack(spacing: 8) {
                            note(L("update.source.tracking", chosenName), symbol: "checkmark.seal.fill", orange: false)
                            if names.count > 1 {
                                Button(L("update.source.choose")) { choose(from: names) }
                                    .controlSize(.small)
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            note(L("update.source.multiple"), symbol: "list.bullet", orange: false)
                            Button(L("update.source.choose")) { choose(from: names) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.bottom, 10)
        }
    }

    private func note(_ text: String, symbol: String, orange: Bool) -> some View {
        Label(text, systemImage: symbol)
            .foregroundStyle(orange ? Color(nsColor: .systemOrange) : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Reads the repo's releases; one `.ipa` in the newest release is followed as is, several ask.
    private func look() async {
        guard let repo = parsed else { return }
        check = .checking
        do {
            let all = try await model.installableIPAs(of: repo)
            guard !Task.isCancelled, repo == parsed else { return }
            guard let newest = all.first?.tag else { check = .none; return }
            let names = all.filter { $0.tag == newest }.map(\.asset.name)
            check = .found(names)
            // One file: followed silently. Several: the person opens the choice ("Choisir").
            if names.count == 1 { adopt(names[0], of: names, repo: repo) }
        } catch {
            guard !Task.isCancelled else { return }
            check = .failed
        }
    }

    private func choose(from names: [String]) {
        guard let picked = UpdateSourceAlerts.chooseVariant(app: flow.appDisplayName, names: names,
                                                            current: chosenName) else { return }
        if let repo = parsed { adopt(picked, of: names, repo: repo) }
    }

    private func adopt(_ name: String, of names: [String], repo: GitHubSource) {
        flow.draft.updateVariant = VariantSelector.make(chosen: name, others: names.filter { $0 != name })
        flow.draft.updateVariantSource = repo
        flow.draft.updateVariantName = name
    }
}

/// The variant choice, as an app-modal alert (an accessory view holds the list; see `AppRowAlerts`).
@MainActor
enum UpdateSourceAlerts {
    /// The asset name the person picked, or nil if cancelled.
    static func chooseVariant(app: String, names: [String], current: String?) -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("update.variant.title")
        alert.informativeText = L("update.variant.message", app)

        let width: CGFloat = 380
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: names)
        if let current, let i = names.firstIndex(of: current) { popup.selectItem(at: i) }
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true

        let tracker = TrackLabel(names: names, popup: popup, width: width)
        popup.target = tracker
        popup.action = #selector(TrackLabel.changed)
        tracker.changed()

        let stack = NSStackView(views: [popup, tracker.label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.frame = NSRect(x: 0, y: 0, width: width, height: stack.fittingSize.height)
        alert.accessoryView = stack

        alert.addButton(withTitle: L("update.variant.follow"))
        alert.addButton(withTitle: L("install.cancel")).keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.titleOfSelectedItem
    }

    /// Says which name parts will be recognized for the selected file.
    private final class TrackLabel: NSObject {
        let names: [String]
        let popup: NSPopUpButton
        let label: NSTextField
        init(names: [String], popup: NSPopUpButton, width: CGFloat) {
            self.names = names
            self.popup = popup
            label = NSTextField(wrappingLabelWithString: "")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = width
        }
        @objc func changed() {
            let i = popup.indexOfSelectedItem
            guard names.indices.contains(i) else { return }
            let v = VariantSelector.make(chosen: names[i], others: names.filter { $0 != names[i] })
            label.stringValue = L("update.variant.track", v.stableTokens.joined(separator: ", "))
        }
    }
}
