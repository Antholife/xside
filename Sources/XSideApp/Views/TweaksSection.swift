import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XSideCore

/// « Tweaks »: the person's own tweaks for this app, the install window's step ③ or Settings >
/// Mes apps. One line, then one compact card per tweak (its dependencies indented under the first
/// tweak that needs them), the files being checked, why the last ones couldn't be added (orange
/// lines, never an alert), and the drop zone with « Ajouter un tweak… ». Empty, it says what
/// tweaks are for and the drop zone is bigger.
struct TweaksSection<Cards: View, Header: View>: View {
    let isEmpty: Bool
    /// The empty step's sentence (the install window says where to manage them later).
    var emptyIntro = L("tweaks.intro")
    let beingAdded: [String]
    let errors: [String]
    var isDisabled = false
    let add: ([URL]) -> Void
    @ViewBuilder let header: Header
    @ViewBuilder let cards: Cards
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle(L("tweaks.section"))
                    Spacer(minLength: 8)
                    header
                }
                Text(isEmpty ? emptyIntro : L("tweaks.intro"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
            cards
            dropZone
            ForEach(beingAdded, id: \.self) { name in
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L("tweaks.adding", name))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dropZone: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isTargeted ? AnyShapeStyle(Theme.violet) : AnyShapeStyle(.secondary))
            Text(L(isEmpty ? "tweaks.drop" : "tweaks.dropKinds"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L("tweaks.add")) { if let urls = Self.choose() { add(urls) } }
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isEmpty ? 24 : 10)
        .background(isTargeted ? Theme.violet.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isTargeted ? Theme.violet : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !isDisabled, !files.isEmpty else { return false }
            add(files)
            return true
        } isTargeted: { isTargeted = $0 && !isDisabled }
        .disabled(isDisabled)
    }

    /// `.deb` and `.dylib` files, `.framework` and `.bundle` folders (any file can be picked: one
    /// XSide can't use says so in the section).
    @MainActor static func choose() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = L("tweaks.add").replacingOccurrences(of: "…", with: "")
        return panel.runModal() == .OK && !panel.urls.isEmpty ? panel.urls : nil
    }
}

/// One device's part of a tweak card: its chip when folded, its verdict when unfolded.
struct TweakRow: Identifiable {
    let deviceID: String
    /// The device's full name: the switch's description and the iOS version problem.
    let deviceName: String
    /// As is, and with « Injecter quand même » (nil: not known yet).
    let verdict: TweakVerdict?
    let forcedVerdict: TweakVerdict?
    let isOn: Bool
    let isForced: Bool
    /// Settings > Mes apps: what the last signing did with it.
    var result: String?
    /// Its last signing on this device injected it: a ❌ from the check made here (no app files,
    /// no SDK) doesn't switch it off; the next signing checks it again.
    var signedAnyway = false
    /// A `Depends` package is missing on this device (« Dépendances » settles it).
    var missingHere = false

    var id: String { deviceID }
    /// The chip's name: « iPhone Duo » for « iPhone Duo de Anthony ».
    var shortName: String { DeviceShortName.short(deviceName) }

    /// What applies: the forced verdict when « Injecter quand même » is on and allowed.
    var applied: TweakVerdict? { isForced && verdict?.canOverride == true ? forcedVerdict ?? verdict : verdict }
    var isBlocked: Bool {
        if case .incompatible? = applied { return !signedAnyway }
        return false
    }
    var isForcedIn: Bool { isForced && verdict?.canOverride == true }
}

/// A tweak, folded to one line: icon, name (« converti » when it is), version · author · target
/// (or « Dépendance de … » with its origin), and per device a chip with ✓/🔧/✕ and its switch.
/// A missing dependency shows instead as « ⚠ manque 1 dépendance », a tweak only a jailbreak can
/// run as « ✕ a besoin d'un jailbreak » (no switch). Unfolded: the verdicts explained, « Injecter
/// quand même sur … », its dependencies (settled right there), « Mettre à jour », « Retirer ».
/// Unfolded at first when something needs a look (🔧, ✕, a missing dependency).
struct TweakCard: View {
    let package: TweakPackage
    let rows: [TweakRow]
    /// The tweaks it is a dependency of (empty: a tweak of its own).
    var dependencyOf: [String] = []
    var dependencies: TweakDependencyState?
    /// The lines of the card's own last action (« Mettre à jour »).
    var ownState: TweakDependencyState?
    var isDisabled = false
    let removeHelp: String
    let setOn: (String, Bool) -> Void
    let setForce: (String, Bool) -> Void
    let remove: () -> Void
    /// « Mettre à jour » (a dependency a trusted repo offers); network only on the click.
    var update: (() -> Void)?
    @State private var expanded: Bool?

    private var isDependency: Bool { !dependencyOf.isEmpty }
    private var missingCount: Int { dependencies?.missingCount ?? 0 }
    private var appliedVerdicts: [TweakVerdict] { rows.compactMap(\.applied) }
    private var isConverted: Bool { appliedVerdicts.contains { if case .converted = $0 { true } else { false } } }
    /// Every device: ❌ because only a jailbreak can run it.
    private var needsJailbreak: Bool {
        !rows.isEmpty && rows.allSatisfy { if case .incompatible(.needsJailbreak)? = $0.verdict { true } else { false } }
    }
    private var needsALook: Bool {
        missingCount > 0 || appliedVerdicts.contains { if case .compatible = $0 { false } else { true } }
    }
    private var isExpanded: Bool { expanded ?? (!isDependency && needsALook) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            folded
            if isExpanded {
                Divider()
                details
                    .padding(.leading, 54)
                    .padding(.trailing, 12)
                    .padding(.vertical, 10)
            }
        }
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.leading, isDependency ? 28 : 0)
    }

    // MARK: Folded

    private var meta: String {
        var parts: [String] = []
        if isDependency { parts.append(L("tweaks.dependencyOf", dependencyOf.joined(separator: ", "))) }
        if let v = package.version, !v.isEmpty { parts.append(v) }
        if isDependency {
            parts.append(TweakText.origin(package.origin))
        } else {
            if let a = package.author, !a.isEmpty { parts.append(a) }
            if let t = package.targetBundleID { parts.append(t) }
        }
        return parts.joined(separator: " · ")
    }

    private var folded: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if isConverted {
                        Text(L("tweaks.tag.converted"))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .foregroundStyle(Theme.violet)
                            .background(Theme.violet.opacity(0.12), in: Capsule())
                    }
                }
                Text(meta).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            chips.fixedSize()
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L(isExpanded ? "tweaks.fold" : "tweaks.unfold", package.name))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func toggle() {
        withAnimation(.smooth(duration: 0.18)) { expanded = !isExpanded }
    }

    private var icon: some View {
        Image(systemName: isDependency ? "link" : "puzzlepiece.extension.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.violet)
            .frame(width: 30, height: 30)
            .background(isDependency ? Color.clear : Theme.violet.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if isDependency {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.violet, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
    }

    @ViewBuilder private var chips: some View {
        if missingCount > 0 {
            TweakChip(kind: .incompatible, symbol: "exclamationmark.triangle.fill",
                      text: missingCount == 1 ? L("tweaks.chip.missingOne") : L("tweaks.chip.missing", missingCount))
        } else if needsJailbreak {
            TweakChip(kind: .incompatible, symbol: "xmark", text: L("tweaks.chip.jailbreak"))
        } else {
            deviceChips
        }
    }

    private var deviceChips: some View {
        HStack(spacing: 6) {
            ForEach(rows) { row in
                DeviceChip(packageName: package.name, row: row, isDisabled: isDisabled) { setOn(row.deviceID, $0) }
            }
        }
    }

    // MARK: Unfolded

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The chips gave way to « manque … »: the switches are here.
            if missingCount > 0, !needsJailbreak { deviceChips }
            if isDependency {
                TweakStatusLine(text: L("tweaks.dependencyFor", dependencyOf.joined(separator: ", ")),
                                kind: .compatible)
                if rows.contains(where: { if case .compatible? = $0.applied { false } else { $0.applied != nil } }) { verdicts }
            } else {
                verdicts
            }
            overrides
            ForEach(package.notes, id: \.self) { note in
                Label(TweakText.note(note), systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let dependencies, dependencies.isWorthShowing {
                TweakDependencyBlock(state: dependencies, isDisabled: isDisabled)
            }
            if let ownState {
                // « Mettre à jour »: its progress and how it went.
                let key = package.packageID
                if ownState.beingAdded.contains(key) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(ownState.progress[key] ?? L("deps.checking")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if let notice = ownState.notices[key] {
                    Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemGreen)).fixedSize(horizontal: false, vertical: true)
                }
                if let error = ownState.errors[key] {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange)).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                if let update {
                    Button(L("tweaks.update"), action: update)
                        .help(L("tweaks.update.help"))
                        .disabled(ownState?.beingAdded.contains(package.packageID) == true)
                }
                Button(L("tweaks.remove"), action: remove).help(removeHelp)
            }
            .controlSize(.small)
            .disabled(isDisabled)
        }
    }

    /// One block when every device says the same, else one per device with its name.
    @ViewBuilder private var verdicts: some View {
        let known = rows.filter { $0.verdict != nil }
        if let first = known.first, known.allSatisfy({ same($0, first) }) {
            TweakVerdictLines(package: package, row: first)
        } else {
            ForEach(known) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.deviceName).font(.system(size: 11, weight: .semibold))
                    TweakVerdictLines(package: package, row: row)
                }
            }
        }
        ForEach(rows.filter { $0.result != nil }) { row in
            Text(rows.count > 1 ? row.shortName + " : " + (row.result ?? "") : row.result ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func same(_ a: TweakRow, _ b: TweakRow) -> Bool {
        a.applied == b.applied && a.isForcedIn == b.isForcedIn && a.signedAnyway == b.signedAnyway
            && !Self.mentionsDevice(a.applied)
    }

    /// An iOS version problem names its device: never merged.
    private static func mentionsDevice(_ v: TweakVerdict?) -> Bool {
        if case .incompatible(.iOSVersion)? = v { true } else { false }
    }

    /// « Injecter quand même sur <appareil> », only where the problem allows it.
    @ViewBuilder private var overrides: some View {
        ForEach(rows.filter { $0.verdict?.canOverride == true }) { row in
            Toggle(L("tweaks.forceOn", row.shortName), isOn: Binding(get: { row.isForced }, set: { setForce(row.deviceID, $0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .accessibilityLabel(L("tweaks.forceOn", row.deviceName))
        }
    }
}

/// ✓ / 🔧 / ✕ chip, with or without a switch.
private struct TweakChip: View {
    let kind: TweakStatusLine.Kind
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).lineLimit(1)
        } icon: {
            Image(systemName: symbol).font(.system(size: 10, weight: .heavy))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(kind.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(kind.tint.opacity(0.13), in: Capsule())
    }
}

/// A device's chip: the verdict there, the device's short name and the switch. Only the chip
/// names the device; the switch's description says it all (« Activer X sur iPhone Duo de … »).
private struct DeviceChip: View {
    let packageName: String
    let row: TweakRow
    let isDisabled: Bool
    let setOn: (Bool) -> Void

    private var kind: TweakStatusLine.Kind {
        if row.isForcedIn { return .forced }
        if row.missingHere, !row.isOn { return .incompatible }
        switch row.applied {
        case .compatible?: return .compatible
        case .converted?: return .converted
        case .incompatible?: return row.signedAnyway ? .forced : .incompatible
        case nil: return .unknown
        }
    }

    private var symbol: String {
        switch kind {
        case .compatible: "checkmark"
        case .converted: "wrench.and.screwdriver.fill"
        case .incompatible: "xmark"
        case .forced: "exclamationmark.triangle.fill"
        case .unknown: "ellipsis"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .heavy))
            Text(row.shortName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Toggle(L("tweaks.enable.a11y", packageName, row.deviceName),
                   isOn: Binding(get: { row.isOn && !row.isBlocked }, set: setOn))
                .labelsHidden()
                .toggleStyle(.xside)
                .controlSize(.mini)
                // A dependency missing here: it can't be turned on (it can be turned off).
                .disabled(isDisabled || row.isBlocked || row.verdict == nil || (row.missingHere && !row.isOn))
                .accessibilityLabel(L("tweaks.enable.a11y", packageName, row.deviceName))
                .help(L("tweaks.enable.a11y", packageName, row.deviceName))
        }
        .foregroundStyle(kind.tint)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(kind.tint.opacity(0.13), in: Capsule())
    }
}

/// A device's verdict, explained: the tinted status line (the reason for ✕), every change for 🔧,
/// « Injecté quand même — … » when forced, and the note for a tweak kept despite a ✕.
private struct TweakVerdictLines: View {
    let package: TweakPackage
    let row: TweakRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let verdict = row.verdict {
                if row.isForcedIn, case .incompatible(let problem) = verdict {
                    forcedExplanation(problem)
                } else {
                    explanation(verdict)
                }
                if row.signedAnyway, case .incompatible? = row.applied {
                    Label(L("tweaks.signedAnyway"), systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One line, « Injecté quand même — fait pour une autre app (…) », then what XSide changes
    /// when the forced tweak is converted. Another problem still stands.
    @ViewBuilder private func forcedExplanation(_ problem: TweakProblem) -> some View {
        if case .incompatible? = row.forcedVerdict, let forced = row.forcedVerdict {
            explanation(forced)
        } else {
            let reason = TweakText.problem(problem, package: package, deviceName: row.deviceName)
            TweakStatusLine(text: L("tweaks.status.forced") + " — " + (reason.first.map { $0.lowercased() } ?? "") + reason.dropFirst(),
                            kind: .forced)
            if case .converted(let list)? = row.forcedVerdict { conversions(list) }
        }
    }

    @ViewBuilder private func explanation(_ verdict: TweakVerdict) -> some View {
        switch verdict {
        case .compatible:
            TweakStatusLine(text: L("tweaks.status.compatible"), kind: .compatible)
        case .converted(let list):
            TweakStatusLine(text: L("tweaks.status.convertedLong"), kind: .converted)
            conversions(list)
        case .incompatible(let problem):
            TweakStatusLine(text: L("tweaks.status.incompatible") + " — "
                                + TweakText.problem(problem, package: package, deviceName: row.deviceName),
                            kind: .incompatible)
        }
    }

    private func conversions(_ list: [TweakConversion]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, c in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("•")
                    Text(TweakText.conversion(c)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
    }
}

/// ✅ / 🔧 / ❌ on a tinted line.
struct TweakStatusLine: View {
    enum Kind {
        case compatible, converted, incompatible, forced, unknown

        var tint: Color {
            switch self {
            case .compatible: Color(nsColor: .systemGreen)
            case .converted, .forced: Color(nsColor: .systemOrange)
            case .incompatible: Color(nsColor: .systemRed)
            case .unknown: Color.secondary
            }
        }
    }
    let text: String
    let kind: Kind

    private var symbol: String {
        switch kind {
        case .compatible: "checkmark.seal.fill"
        case .converted: "wrench.and.screwdriver.fill"
        case .incompatible: "xmark.octagon.fill"
        case .forced: "exclamationmark.triangle.fill"
        case .unknown: "ellipsis.circle"
        }
    }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(kind.tint)
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

extension AppModel {
    /// A card's dependencies, with this model's lines and actions.
    func dependencyState(_ target: DependencyTarget, rows: [DependencyRow], names: [String: String]) -> TweakDependencyState {
        TweakDependencyState(rows: rows, deviceNames: names, errors: dependencyErrors, notices: dependencyNotices,
                             progress: dependencyProgress, beingAdded: dependenciesBeingAdded,
                             addDeb: { dep, urls in Task { await self.addDependencyDeb(urls, for: dep, target: target) } },
                             download: { dep in
                                 guard let tweak = self.dependencyRows(target)?.package else { return }
                                 Task { await self.downloadDependency(dep, for: tweak, target: target) }
                             })
    }

    /// Its own lines (« Mettre à jour »).
    var ownDependencyState: TweakDependencyState {
        TweakDependencyState(rows: [], errors: dependencyErrors, notices: dependencyNotices,
                             progress: dependencyProgress, beingAdded: dependenciesBeingAdded)
    }
}

/// Step ③: the window's tweaks, one chip per checked device.
struct InstallTweaksSection: View {
    let model: AppModel
    @Bindable var flow: InstallFlow

    var body: some View {
        let order = DependencyRows.cardOrder(flow.tweaks.map(\.package))
        TweaksSection(isEmpty: flow.tweaks.isEmpty, emptyIntro: L("tweaks.intro.empty"),
                      beingAdded: flow.tweaksBeingAdded, errors: flow.tweakErrors, isDisabled: flow.isRunning,
                      add: { urls in Task { await model.addTweaks(urls, to: flow) } }) {
            EmptyView()
        } cards: {
            ForEach(order, id: \.package.id) { item in
                if let draft = flow.tweaks.first(where: { $0.id == item.package.id }) {
                    card(draft, dependencyOf: item.dependencyOf)
                }
            }
        }
        .disabled(flow.isRunning)
        .onChange(of: flow.deviceIDs, initial: true) { model.syncTweakDevices(flow) }
    }

    private func card(_ draft: TweakDraft, dependencyOf: [String]) -> some View {
        let target = DependencyTarget.draft(tweakID: draft.id)
        let found = model.dependencyRows(target)
        let isDependency = !dependencyOf.isEmpty
        return TweakCard(package: draft.package, rows: rows(draft), dependencyOf: dependencyOf,
                         dependencies: found.map { model.dependencyState(target, rows: $0.rows, names: $0.deviceNames) },
                         ownState: isDependency ? model.ownDependencyState : nil,
                         isDisabled: flow.isRunning, removeHelp: L("tweaks.remove.help"),
                         setOn: { id, on in model.setTweak(draft.id, enabled: on, for: id, in: flow) },
                         setForce: { id, on in model.setTweakForce(draft.id, on, for: id, in: flow) },
                         remove: {
                             guard !isDependency || model.confirmRemovingDependency(draft.package, target: target) else { return }
                             model.removeTweak(draft.id, from: flow)
                         },
                         update: isDependency && !TrustedRepos.offering(draft.package.packageID).isEmpty
                             ? { Task { await model.updateDependency(draft.package, target: target) } } : nil)
            .id(draft.id)
    }

    private func rows(_ draft: TweakDraft) -> [TweakRow] {
        flow.deviceIDs.map { id in
            TweakRow(deviceID: id, deviceName: model.deviceName(id),
                     verdict: draft.verdicts[id], forcedVerdict: draft.forcedVerdicts[id],
                     isOn: draft.enabledDevices.contains(id), isForced: draft.force.contains(id),
                     signedAnyway: draft.injectedOn.contains(id),
                     missingHere: !(draft.missingDependencies[id] ?? []).isEmpty)
        }
    }
}

/// Settings > Mes apps: the installation's tweaks (one chip: this device), what its last signing
/// did with each, the pending line while its choice isn't in the app yet, and « Dépendances
/// téléchargées » for every app.
struct InstalledTweaksSection<Notice: View>: View {
    let model: AppModel
    let entry: AppEntry
    let deviceName: String
    @ViewBuilder let pendingNotice: Notice
    @State private var showsDownloads = false

    private var listed: [(TweakPackage, TweakUse)] {
        let pool = entry.record.tweaks ?? []
        return (entry.installation.tweaks ?? []).compactMap { use in pool.first { $0.id == use.id }.map { ($0, use) } }
    }

    var body: some View {
        let disabled = !model.canManage(entry)
        let listed = listed
        let order = DependencyRows.cardOrder(listed.map(\.0))
        TweaksSection(isEmpty: listed.isEmpty, beingAdded: model.tweaksBeingAdded[entry.id] ?? [],
                      errors: model.tweakErrors[entry.id] ?? [], isDisabled: disabled,
                      add: { urls in Task { await model.addTweaks(urls, for: entry) } }) {
            Button(L("downloads.open")) { showsDownloads = true }
                .buttonStyle(.link)
                .font(.system(size: 11))
        } cards: {
            ForEach(order, id: \.package.id) { item in
                if let pair = listed.first(where: { $0.0.id == item.package.id }) {
                    card(pair.0, use: pair.1, dependencyOf: item.dependencyOf, disabled: disabled)
                }
            }
            pendingNotice
        }
        .sheet(isPresented: $showsDownloads) {
            DownloadedDependenciesView(model: model) { showsDownloads = false }
        }
    }

    private func card(_ package: TweakPackage, use: TweakUse, dependencyOf: [String], disabled: Bool) -> some View {
        let target = DependencyTarget.entry(entry.id, tweakID: package.id)
        let found = model.dependencyRows(target)
        let isDependency = !dependencyOf.isEmpty
        let v = model.tweakVerdicts(package, for: entry)
        let signed = entry.installation.signedChoices?.tweaks?.contains(package.id) == true
        let row = TweakRow(deviceID: entry.installation.deviceID, deviceName: deviceName,
                           verdict: v.verdict, forcedVerdict: v.forced, isOn: use.enabled, isForced: use.force == true,
                           result: TweakText.result(entry.installation.tweakResults?[package.id], package: package,
                                                    enabled: use.enabled, signed: signed, deviceName: deviceName),
                           signedAnyway: {
                               if case .injected? = entry.installation.tweakResults?[package.id] { true } else { false }
                           }(),
                           missingHere: !model.missingDependencies(package, for: entry).isEmpty)
        return TweakCard(package: package, rows: [row], dependencyOf: dependencyOf,
                         dependencies: found.map { model.dependencyState(target, rows: $0.rows, names: $0.deviceNames) },
                         ownState: isDependency ? model.ownDependencyState : nil,
                         isDisabled: disabled, removeHelp: L("tweaks.remove.helpOne"),
                         setOn: { _, on in Task { await model.setTweak(package.id, enabled: on, for: entry) } },
                         setForce: { _, on in Task { await model.setTweakForce(package.id, on, for: entry) } },
                         remove: {
                             guard !isDependency || model.confirmRemovingDependency(package, target: target) else { return }
                             Task { await model.removeTweak(package.id, for: entry) }
                         },
                         update: isDependency && !TrustedRepos.offering(package.packageID).isEmpty
                             ? { Task { await model.updateDependency(package, target: target) } } : nil)
            .id(package.id)
    }
}
