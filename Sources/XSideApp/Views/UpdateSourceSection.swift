import AppKit
import SwiftUI
import XSideCore

/// "Source de mise à jour" in the install window: an optional GitHub link. You type the link, press
/// « Vérifier le lien », and a sheet checks the repo, lets you pick the file to follow (when several)
/// and the mode (notify / auto), then confirm. Once set, the card shows a summary with « Modifier »
/// and a way to remove it. The link is validated by `GitHubSource.parse`; releases are read off the
/// main actor via `AppModel.installableIPAs`.
struct UpdateSourceSection: View {
    let model: AppModel
    @Bindable var flow: InstallFlow
    @State private var showsSheet = false

    private var parsed: GitHubSource? { GitHubSource.parse(flow.draft.updateSourceURL) }
    private var isEmpty: Bool { flow.draft.updateSourceURL.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Configured: a variant chosen for the very repo in the field now (so the summary is shown).
    private var chosenName: String? {
        flow.draft.updateVariant != nil && flow.draft.updateVariantSource == parsed ? flow.draft.updateVariantName : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(L("update.source.title"))
                Text(L("update.source.caption"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                OptionRow(symbol: "arrow.down.circle.fill", title: L("update.source.link"),
                          detail: L("update.source.link.note")) { EmptyView() }
                if let chosenName {
                    Divider().padding(.leading, 48)
                    configuredRow(chosenName)
                } else {
                    Divider().padding(.leading, 48)
                    editRow
                }
            }
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(flow.updateLinkError ? Color(nsColor: .systemOrange) : .clear, lineWidth: 1.5))
            .disabled(flow.isRunning)
        }
        .sheet(isPresented: $showsSheet) {
            if let repo = parsed {
                UpdateSourceSheet(model: model, flow: flow, repo: repo) { showsSheet = false }
            }
        }
    }

    /// The link field, a trash button to clear it and the « Vérifier le lien » button (enabled once
    /// the link is a valid GitHub repo). A pending link that blocked « Suivant » is flagged here.
    @ViewBuilder private var editRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(L("update.source.link"), text: $flow.draft.updateSourceURL,
                          prompt: Text(L("update.source.placeholder")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .onChange(of: flow.draft.updateSourceURL) { _, _ in flow.updateLinkError = false }
                    .onSubmit { if parsed != nil { showsSheet = true } }
                statusPill
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if !isEmpty {
                    Button(action: clearLink) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help(L("update.source.clear"))
                }
                Button(L("update.source.verify")) { showsSheet = true }
                    .buttonStyle(GradientButtonStyle())
                    .fixedSize()
                    .disabled(parsed == nil)
            }
            if flow.updateLinkError {
                Label(L("update.source.mustVerify"), systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private func clearLink() {
        flow.draft.updateSourceURL = ""
        flow.updateLinkError = false
    }

    /// The summary once a source is set: the followed file, the mode, « Modifier », and a remove button.
    private func configuredRow(_ name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color(nsColor: .systemGreen))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("update.source.tracking", name) + " · " + modeLabel)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let repo = parsed {
                    Text("github.com/\(repo.owner)/\(repo.repo)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Button(L("install.summary.edit")) { showsSheet = true }
                .controlSize(.small)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("update.source.remove"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var modeLabel: String { L(flow.draft.updateMode == .auto ? "update.mode.auto" : "update.mode.notify") }

    private func remove() {
        flow.draft.updateVariant = nil
        flow.draft.updateVariantSource = nil
        flow.draft.updateVariantName = nil
        flow.draft.updateSourceURL = ""
        flow.updateLinkError = false
    }

    @ViewBuilder private var statusPill: some View {
        if !isEmpty {
            if parsed != nil {
                Label(L("update.source.recognized"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemGreen))
            } else {
                Label(L("update.source.invalid"), systemImage: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
        }
    }
}

/// The sheet opened by « Vérifier le lien »: it reads the repo's releases, lets the person pick the
/// file to follow (when several) and the mode, and on « Valider » writes the choice into the draft.
struct UpdateSourceSheet: View {
    let model: AppModel
    @Bindable var flow: InstallFlow
    let repo: GitHubSource
    let dismiss: () -> Void

    private enum Phase: Equatable { case verifying, failed, noAsset, ready([String]) }
    @State private var phase: Phase = .verifying
    @State private var all: [(tag: String, isPrerelease: Bool, asset: ReleaseAsset)] = []
    @State private var picked: String?        // the variant asset name
    @State private var installedTag: String?  // the release the person is on (baseline)
    @State private var mode: UpdateMode = .notify
    @State private var interval: TimeInterval?
    @State private var step = 0 // 0 variant · 1 current version · 2 mode + frequency
    @State private var downloading: Double?   // progress while fetching the newest, nil when idle
    @State private var downloadFailed = false

    private var ready: Bool { if case .ready = phase { true } else { false } }
    private var busy: Bool { downloading != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("update.source.title")).font(.system(size: 15, weight: .bold))
                Text("github.com/\(repo.owner)/\(repo.repo)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                switch step {
                case 0:
                    verifyBanner
                    if case .ready(let names) = phase, names.count > 1 { variantPicker(names) }
                case 1:
                    tagStep
                default:
                    modeCards
                    intervalRow
                }
            }
            .padding(18)
            .frame(minHeight: 120, alignment: .top)
            Divider()
            footer
        }
        .frame(width: 460)
        .onAppear {
            mode = flow.draft.updateMode
            interval = flow.draft.updateInterval
            picked = flow.draft.updateVariantSource == repo ? flow.draft.updateVariantName : nil
            installedTag = flow.draft.updateInstalledTag
        }
        .task { await look() }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            if step == 0 {
                Button(L("install.cancel"), action: dismiss).controlSize(.large).keyboardShortcut(.cancelAction)
                    .disabled(busy)
            } else {
                Button(L("install.back")) { withAnimation(.smooth(duration: 0.15)) { step -= 1 } }.controlSize(.large)
                    .disabled(busy)
            }
            if step < 2 {
                Button(L("install.next")) { goNext() }
                    .buttonStyle(GradientButtonStyle()).controlSize(.large).frame(minWidth: 120)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance || busy)
            } else {
                Button(L("update.source.validate"), action: validate)
                    .buttonStyle(GradientButtonStyle()).controlSize(.large).frame(minWidth: 120)
                    .keyboardShortcut(.defaultAction)
                    .disabled(installedTag == nil || busy)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var canAdvance: Bool {
        switch step {
        case 0: return ready && picked != nil
        case 1: return installedTag != nil
        default: return true
        }
    }

    private func goNext() {
        if step == 0 { // entering the version step: default to the auto-detected tag, else nothing
            if installedTag == nil || !releaseTags.contains(where: { $0.tag == installedTag }) {
                installedTag = autoDetectedTag // nil when it can't be told: the person must pick
            }
        }
        withAnimation(.smooth(duration: 0.15)) { step += 1 }
    }

    /// Releases that have an asset for the chosen variant, newest first — the versions to pick from.
    private var releaseTags: [(tag: String, asset: String)] {
        guard let picked, case .ready(let names) = phase else { return [] }
        let selector = VariantSelector.make(chosen: picked, others: names.filter { $0 != picked })
        var seen = Set<String>(), out: [(String, String)] = []
        for e in all where selector.matches(e.asset.name) && !seen.contains(e.tag) {
            seen.insert(e.tag); out.append((e.tag, e.asset.name))
        }
        return out
    }

    /// Best-effort guess of the release the person is installing: the one whose variant asset name
    /// carries the IPA's own app version (e.g. `…_21.44.4.ipa`). nil when it can't be told.
    private var autoDetectedTag: String? {
        guard let version = flow.info?.version, !version.isEmpty else { return nil }
        return releaseTags.first { $0.asset.contains(version) }?.tag
    }

    private var tagStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("update.source.whichTag")).font(.system(size: 13, weight: .semibold))
            Text(L("update.source.whichTag.note")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $installedTag) {
                ForEach(releaseTags, id: \.tag) { r in
                    Text(UpdateChecker.displayTag(r.tag)).tag(Optional(r.tag))
                }
            }
            .labelsHidden().pickerStyle(.menu).padding(.top, 2)
            if autoDetectedTag == nil {
                Label(L("update.source.whichTag.undetected"), systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemOrange))
            } else if let installedTag, installedTag == autoDetectedTag {
                Label(L("update.source.whichTag.detected"), systemImage: "wand.and.stars")
                    .font(.system(size: 11)).foregroundStyle(Theme.violet)
            }
            if let newest = newestTag, let installedTag, installedTag != newest { newerOffer(newest) }
        }
    }

    /// Newest release available for the chosen variant (the first of `releaseTags`).
    private var newestTag: String? { releaseTags.first?.tag }

    /// Shown in the version step when the person is not on the newest release: a button that
    /// downloads the newest and restarts the install on it, with a progress bar while it fetches.
    private func newerOffer(_ newest: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bolt.fill").font(.system(size: 13)).foregroundStyle(Theme.brand).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("update.newer.title")).font(.system(size: 12.5, weight: .semibold))
                    Text(L("update.newer.note", UpdateChecker.displayTag(installedTag ?? ""), UpdateChecker.displayTag(newest)))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let frac = downloading {
                ProgressView(value: frac).controlSize(.small)
                Text(L("update.newer.downloading", UpdateChecker.displayTag(newest)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack {
                    Spacer(minLength: 0)
                    Button(L("update.newer.install", UpdateChecker.displayTag(newest))) { installNewest(newest) }
                        .buttonStyle(GradientButtonStyle()).controlSize(.small).fixedSize()
                }
            }
            if downloadFailed {
                Label(L("update.newer.failed"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemOrange))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.brand.opacity(0.25), lineWidth: 1))
    }

    private func installNewest(_ newest: String) {
        guard case .ready(let names) = phase, let picked,
              let asset = all.first(where: { $0.tag == newest && $0.asset.name == releaseTags.first?.asset })?.asset else { return }
        let seed = AppModel.UpdateSourceSeed(
            url: flow.draft.updateSourceURL,
            variant: VariantSelector.make(chosen: picked, others: names.filter { $0 != picked }),
            variantSource: repo, variantName: picked, mode: mode, interval: interval, installedTag: newest)
        downloadFailed = false
        downloading = 0
        Task {
            do {
                try await model.installNewestAtInstall(asset: asset, appName: flow.info?.name, seed: seed) { f in
                    Task { @MainActor in downloading = f }
                }
                dismiss()
            } catch {
                downloading = nil
                downloadFailed = true
            }
        }
    }

    private var intervalRow: some View {
        HStack(spacing: 10) {
            Text(L("update.interval.title")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            UpdateIntervalControl(seconds: $interval, allowsGlobalDefault: true, allowsNever: true,
                                  globalDefaultSeconds: AppModel.updateCheckInterval)
        }
    }

    @ViewBuilder private var verifyBanner: some View {
        switch phase {
        case .verifying:
            banner { HStack(spacing: 7) { ProgressView().controlSize(.small); Text(L("update.source.checking")) } }
        case .failed:
            banner(color: .systemOrange) { Label(L("update.source.failed"), systemImage: "exclamationmark.triangle.fill") }
        case .noAsset:
            banner(color: .systemOrange) { Label(L("update.source.noAsset"), systemImage: "exclamationmark.triangle.fill") }
        case .ready:
            banner(color: .systemGreen) { Label(L("update.verify.ready"), systemImage: "checkmark.circle.fill") }
        }
    }

    private func banner<Content: View>(color: NSColor? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 12.5))
            .foregroundStyle(color.map { Color(nsColor: $0) } ?? .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func variantPicker(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("update.variant.which")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Picker("", selection: $picked) {
                ForEach(names, id: \.self) { name in Text(name).tag(Optional(name)) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            if let picked {
                let selector = VariantSelector.make(chosen: picked, others: names.filter { $0 != picked })
                Text(L("update.variant.track", selector.stableTokens.joined(separator: ", ")))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("update.mode.title")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ModeCard(symbol: "bell.fill", title: L("update.mode.notify"), detail: L("update.mode.notify.detail"),
                     selected: mode == .notify) { mode = .notify }
            ModeCard(symbol: "bolt.fill", title: L("update.mode.auto"), detail: L("update.mode.auto.detail"),
                     selected: mode == .auto) { mode = .auto }
        }
    }

    /// Reads the repo's releases; the newest release's `.ipa`s are the files to choose among.
    private func look() async {
        phase = .verifying
        do {
            let fetched = try await model.installableIPAs(of: repo)
            all = fetched
            guard let newest = fetched.first?.tag else { phase = .noAsset; return }
            let names = fetched.filter { $0.tag == newest }.map(\.asset.name)
            phase = .ready(names)
            // Keep a still-valid pick (reopening « Modifier »); otherwise follow the first file.
            if !(picked.map(names.contains) ?? false) { picked = names.first }
        } catch {
            phase = .failed
        }
    }

    private func validate() {
        guard case .ready(let names) = phase, let picked, let installedTag else { return }
        flow.draft.updateVariant = VariantSelector.make(chosen: picked, others: names.filter { $0 != picked })
        flow.draft.updateVariantSource = repo
        flow.draft.updateVariantName = picked
        flow.draft.updateMode = mode
        flow.draft.updateInterval = interval
        flow.draft.updateInstalledTag = installedTag
        flow.updateLinkError = false
        dismiss()
    }
}

/// One selectable mode card: a radio, an icon, the title and its explanation; the selected one is
/// outlined in the brand colour.
private struct ModeCard: View {
    let symbol: String
    let title: String
    let detail: String
    let selected: Bool
    let select: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().strokeBorder(selected ? Theme.violet : Color.secondary.opacity(0.5), lineWidth: 1.5)
                    if selected { Circle().fill(Theme.violet).frame(width: 9, height: 9) }
                }
                .frame(width: 17, height: 17)
                .padding(.top, 1)
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(selected ? Theme.violet.opacity(0.08) : Theme.cardFill))
            .overlay(shape.strokeBorder(selected ? Theme.violet : Color.primary.opacity(0.08),
                                        lineWidth: selected ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
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
