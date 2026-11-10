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
    /// Off because the person uninstalled its dependency here (« Désactivé : tu as retiré … »):
    /// its switch can be turned back on (it then shows « À régler » as usual).
    var dependencyRemoved = false

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

/// One card of the grouped list (device round 2, mockup tweaks-step-v2): the tweak, its group,
/// its rows per device, its dependencies (missing ones settled in « À régler », the others
/// nested under it, ↳) and what its buttons do.
struct TweakCardItem: Identifiable {
    let package: TweakPackage
    let rows: [TweakRow]
    let group: TweakGroups.Group
    var dependencies: TweakDependencyState?
    var nested: [NestedDependency] = []
    let setOn: (String, Bool) -> Void
    let setForce: (String, Bool) -> Void
    let remove: () -> Void
    /// Settings > Mes apps: its change waits for the next refresh (« en attente »).
    var isPending = false
    var id: String { package.id }
}

/// A dependency the person added or downloaded, under the tweak that needs it: its status per
/// device, « Retirer » (trash, or the context menu) and « Mettre à jour ».
struct NestedDependency: Identifiable {
    let package: TweakPackage
    let rows: [TweakRow]
    let remove: () -> Void
    var update: (() -> Void)?
    var id: String { package.id }
}

/// The tweaks in three groups: « À régler » (red, first; blocks « Suivant » in the install
/// window), « Prêts » (what will be injected, a switch per device) and « Pas compatibles » (grey,
/// foldable, never injected). A trash on every row (and « Retirer » in its context menu).
struct GroupedTweakCards: View {
    let items: [TweakCardItem]
    /// The install window: « À régler » blocks « Suivant ». Settings > Mes apps: it isn't injected.
    let blocksNext: Bool
    var isDisabled = false
    let removeHelp: String
    /// The lines of each dependency's last action (« Mettre à jour », by package id).
    var lines: TweakDependencyState
    @State private var showsIncompatible = true

    private func items(_ group: TweakGroups.Group) -> [TweakCardItem] { items.filter { $0.group == group } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let toSettle = items(.toSettle), ready = items(.ready), incompatible = items(.incompatible)
            if !toSettle.isEmpty {
                section(.toSettle, count: toSettle.count) {
                    ForEach(toSettle) { card($0) }
                }
            }
            if !ready.isEmpty {
                section(.ready, count: ready.count) {
                    ForEach(ready) { card($0) }
                }
            }
            if !incompatible.isEmpty {
                section(.incompatible, count: incompatible.count) {
                    if showsIncompatible {
                        ForEach(incompatible) { card($0).opacity(0.75) }
                    }
                }
            }
        }
    }

    private func card(_ item: TweakCardItem) -> some View {
        TweakCard(item: item, isDisabled: isDisabled, removeHelp: removeHelp, lines: lines)
            .id(item.id)
    }

    @ViewBuilder private func section<Content: View>(_ group: TweakGroups.Group, count: Int,
                                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(group, count: count)
            content()
        }
    }

    private func header(_ group: TweakGroups.Group, count: Int) -> some View {
        let (symbol, title, caption, tint): (String, String, String, Color) = switch group {
        case .toSettle: ("exclamationmark.triangle.fill", L("tweaks.group.toSettle"),
                         L(blocksNext ? "tweaks.group.toSettle.next" : "tweaks.group.toSettle.later", count),
                         Color(nsColor: .systemRed))
        case .ready: ("checkmark", L("tweaks.group.ready"), L("tweaks.group.ready.count", count), Color(nsColor: .systemGreen))
        case .incompatible: ("xmark", L("tweaks.group.incompatible"), L("tweaks.group.incompatible.count", count), Color.secondary)
        }
        return HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .heavy))
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).kerning(0.4)
            Text("· " + caption).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if group == .incompatible {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showsIncompatible ? 0 : -90))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard group == .incompatible else { return }
            withAnimation(.smooth(duration: 0.18)) { showsIncompatible.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(group == .incompatible ? .isButton : .isHeader)
    }
}

/// One tweak: its row (icon, name, « converti », version · author · what it is; the device
/// chips and switches when it will be injected; the trash), then by group: what to settle and how
/// (« À régler »), the changes on request and its dependencies nested (↳) (« Prêts »).
struct TweakCard: View {
    let item: TweakCardItem
    var isDisabled = false
    let removeHelp: String
    var lines: TweakDependencyState
    @State private var showsChanges = false

    private var package: TweakPackage { item.package }
    private var rows: [TweakRow] { item.rows }
    private var appliedVerdicts: [TweakVerdict] { rows.compactMap(\.applied) }
    private var conversions: [TweakConversion] {
        var out: [TweakConversion] = []
        for v in appliedVerdicts { if case .converted(let list) = v { for c in list where !out.contains(c) { out.append(c) } } }
        return out
    }
    private var isConverted: Bool { !conversions.isEmpty }
    private var warnings: [TweakWarning] { TweakClassifier.warnings(package) }
    private var missingCount: Int { item.dependencies?.missingCount ?? 0 }
    /// A device where it works: its switch is worth showing even while something is to settle.
    private var worksSomewhere: Bool { rows.contains { !$0.isBlocked && !$0.missingHere && $0.verdict != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            folded
            switch item.group {
            case .toSettle: toSettle.padding(.leading, 54).padding(.trailing, 12).padding(.bottom, 10)
            case .ready: readyDetails
            case .incompatible: EmptyView()
            }
        }
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if item.group == .toSettle {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .systemRed).opacity(0.45), lineWidth: 1)
            }
        }
        .contextMenu {
            Button(L("tweaks.remove"), role: .destructive, action: item.remove).disabled(isDisabled)
        }
    }

    // MARK: Row

    private var meta: String {
        var parts: [String] = []
        if let v = package.version, !v.isEmpty { parts.append(v) }
        if let a = package.author, !a.isEmpty { parts.append(a) }
        if let what = summary { parts.append(what) }
        return parts.joined(separator: " · ")
    }

    /// What it is, in a few words: « compatible tel quel », or why it can't go in.
    private var summary: String? {
        switch item.group {
        case .ready:
            if appliedVerdicts.allSatisfy({ $0 == .compatible }), !appliedVerdicts.isEmpty, !rows.contains(where: \.isForcedIn) {
                return L("tweaks.meta.asIs")
            }
            return nil
        case .toSettle:
            return nil // its red line says it
        case .incompatible:
            guard missingCount == 0, let row = rows.first(where: { if case .incompatible = $0.applied { true } else { false } }),
                  case .incompatible(let problem)? = row.applied else { return nil }
            let text = TweakText.problem(problem, package: package, deviceName: row.deviceName)
            return (text.first.map { $0.lowercased() } ?? "") + text.dropFirst()
        }
    }

    private var folded: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if item.isPending { PendingBadge() }
                    if isConverted, item.group == .ready {
                        Text(L("tweaks.tag.converted"))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .background(Color(nsColor: .systemOrange).opacity(0.13), in: Capsule())
                    }
                }
                HStack(spacing: 4) {
                    if !meta.isEmpty {
                        Text(meta).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if isConverted, item.group == .ready {
                        Text(meta.isEmpty ? "" : "·").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button(L(showsChanges ? "tweaks.hideChanges" : "tweaks.seeChanges")) {
                            withAnimation(.smooth(duration: 0.18)) { showsChanges.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.violet)
                        .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.group == .ready || (item.group == .toSettle && worksSomewhere && rows.count > 1) {
                chips.fixedSize()
            }
            TrashButton(help: removeHelp, a11y: L("tweaks.remove.a11y", package.name), action: item.remove)
                .disabled(isDisabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var icon: some View {
        Image(systemName: "puzzlepiece.extension.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(item.group == .incompatible ? Color.secondary : Theme.violet)
            .frame(width: 30, height: 30)
            .background((item.group == .incompatible ? Color.secondary : Theme.violet).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(rows) { row in
                DeviceChip(packageName: package.name, row: row, isDisabled: isDisabled) { item.setOn(row.deviceID, $0) }
            }
        }
    }

    // MARK: À régler

    /// The problem in red, then how to settle it: the dependency (download, find, add its .deb,
    /// search the web), « Injecter quand même sur … », or two versions asked at once.
    @ViewBuilder private var toSettle: some View {
        VStack(alignment: .leading, spacing: 6) {
            if missingCount > 0 {
                Text(missingCount == 1 ? L("tweaks.problem.missingOne") : L("tweaks.problem.missingMany", missingCount))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemRed))
            } else {
                ForEach(problemLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                }
                overrides
            }
            if let deps = item.dependencies, deps.isWorthShowing {
                TweakDependencyBlock(state: deps, isDisabled: isDisabled, showsTitle: false)
            }
            warningLines
        }
    }

    /// One line per distinct problem (with its device when they differ).
    private var problemLines: [String] {
        var out: [String] = []
        let blocked = rows.filter { if case .incompatible = $0.applied { !$0.signedAnyway } else { false } }
        for row in blocked {
            guard case .incompatible(let problem)? = row.applied else { continue }
            var text = TweakText.problem(problem, package: package, deviceName: row.deviceName)
            if problem.isOverridable { text += " " + L("tweaks.problem.canForce") }
            let line = blocked.count > 1 && rows.count > 1 ? row.shortName + " : " + text : text
            if !out.contains(line) { out.append(line) }
        }
        // Same problem everywhere: said once.
        if out.count > 1, blocked.allSatisfy({ $0.applied == blocked[0].applied }), case .incompatible(let p)? = blocked.first?.applied,
           !(p.isIOSVersion) {
            var text = TweakText.problem(p, package: package, deviceName: blocked[0].deviceName)
            if p.isOverridable { text += " " + L("tweaks.problem.canForce") }
            return [text]
        }
        return out
    }

    /// « Injecter quand même sur <appareil> », only where the problem allows it.
    @ViewBuilder private var overrides: some View {
        ForEach(rows.filter { $0.verdict?.canOverride == true }) { row in
            Toggle(L("tweaks.forceOn", row.shortName), isOn: Binding(get: { row.isForced }, set: { item.setForce(row.deviceID, $0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .accessibilityLabel(L("tweaks.forceOn", row.deviceName))
                .disabled(isDisabled)
        }
    }

    @ViewBuilder private var warningLines: some View {
        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
            Label(TweakText.warning(warning), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Prêts

    @ViewBuilder private var readyDetails: some View {
        // Off because the person removed its dependency: its note says so, no ✕ line for it.
        let removedOnPurpose = !rows.isEmpty && rows.allSatisfy { $0.dependencyRemoved && !$0.isOn }
        let depRows = removedOnPurpose ? [] : (item.dependencies?.rows ?? []).filter { row in
            row.statuses.contains { if case .notNeeded = $0.status { false } else { true } }
        }
        let results = rows.filter { $0.result != nil }
        let forced = rows.filter(\.isForcedIn)
        let keptAnyway = rows.contains { $0.signedAnyway && { if case .incompatible? = $0.applied { true } else { false } }($0) }
        if showsChanges || !depRows.isEmpty || !item.nested.isEmpty || !results.isEmpty || !warnings.isEmpty || !forced.isEmpty
            || keptAnyway {
            VStack(alignment: .leading, spacing: 4) {
                if showsChanges {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("tweaks.status.convertedLong")).font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(Array(conversions.enumerated()), id: \.offset) { _, c in
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text("•")
                                Text(TweakText.conversion(c)).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                        ForEach(package.notes, id: \.self) { note in
                            Label(TweakText.note(note), systemImage: "info.circle")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, 2)
                }
                ForEach(forced) { row in
                    if case .incompatible(let problem)? = row.verdict {
                        let reason = TweakText.problem(problem, package: package, deviceName: row.deviceName)
                        TweakStatusLine(text: (rows.count > 1 ? row.shortName + " : " : "") + L("tweaks.status.forced") + " — "
                                            + (reason.first.map { $0.lowercased() } ?? "") + reason.dropFirst(),
                                        kind: .forced)
                    }
                }
                if !forced.isEmpty {
                    overrides
                }
                ForEach(rows.filter { $0.signedAnyway && { if case .incompatible? = $0.applied { true } else { false } }($0) }) { row in
                    Label((rows.count > 1 ? row.shortName + " : " : "") + L("tweaks.signedAnyway"), systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                warningLines
                ForEach(results) { row in
                    Text(rows.count > 1 ? row.shortName + " : " + (row.result ?? "") : row.result ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(depRows) { row in
                    let nested = nestedPackage(for: row)
                    NestedDependencyLine(row: row, nested: nested, deviceNames: item.dependencies?.deviceNames ?? [:],
                                         lines: lines, isDisabled: isDisabled)
                }
                // Added dependencies no row names (another version, a Provides): listed too.
                ForEach(item.nested.filter { n in !depRows.contains { nestedPackage(for: $0)?.id == n.id } }) { n in
                    NestedDependencyLine(row: nil, nested: n, deviceNames: item.dependencies?.deviceNames ?? [:],
                                         lines: lines, isDisabled: isDisabled)
                }
            }
            .padding(.leading, 54)
            .padding(.trailing, 12)
            .padding(.bottom, 10)
        }
    }

    /// The added package a row's « ajoutée par toi » is.
    private func nestedPackage(for row: DependencyRow) -> NestedDependency? {
        for s in row.statuses {
            if case .addedByYou(let name) = s.status,
               let n = item.nested.first(where: { $0.package.name == name
                   && ($0.package.packageID == s.dependency.package || $0.package.provides.contains(s.dependency.package)) }) {
                return n
            }
        }
        return nil
    }
}

/// « ↳ Cephei · fournie par XSide ✓ », « ↳ AltList 1.0.4 · ajoutée par toi ✓ 🗑 » (with « Mettre à
/// jour » and « Retirer » in its context menu), one status per device when they disagree.
private struct NestedDependencyLine: View {
    let row: DependencyRow?
    let nested: NestedDependency?
    let deviceNames: [String: String]
    let lines: TweakDependencyState
    let isDisabled: Bool

    private var key: String { nested?.package.packageID ?? row?.dependency.package ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("↳").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("· " + origin).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                    StatusPill(text: pill.text, ok: pill.ok)
                }
                if let nested {
                    TrashButton(help: L("tweaks.dep.remove.help"), a11y: L("tweaks.dep.remove.a11y", nested.package.name),
                                action: nested.remove)
                        .disabled(isDisabled)
                }
            }
            if lines.beingAdded.contains(key) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(lines.progress[key] ?? L("deps.checking")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let notice = lines.notices[key] {
                Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemGreen)).fixedSize(horizontal: false, vertical: true)
            }
            if let error = lines.errors[key] {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemOrange)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            if let nested {
                if let update = nested.update { Button(L("tweaks.update"), action: update).disabled(isDisabled) }
                Button(L("tweaks.remove"), role: .destructive, action: nested.remove).disabled(isDisabled)
            }
        }
    }

    private var title: String {
        if let nested { return nested.package.name + (nested.package.version.map { " " + $0 } ?? "") }
        guard let s = row?.statuses.first else { return "" }
        switch s.status {
        case .providedByXSide(let n), .builtIntoTweak(let n), .jailbreakOnly(let n): return n
        case .addedByYou(let n): return n + (s.addedVersion.map { " " + $0 } ?? "")
        case .missing(let d): return DependencyNames.display(d.package)
        case .notNeeded: return DependencyNames.display(s.dependency.package)
        }
    }

    private var origin: String {
        if let nested { return TweakText.origin(nested.package.origin) }
        switch row?.statuses.first?.status {
        case .providedByXSide?: return L("deps.status.xside").lowercasedFirst
        case .builtIntoTweak?: return L("deps.status.builtIn").lowercasedFirst
        case .addedByYou?: return L("deps.status.yours").lowercasedFirst
        default: return ""
        }
    }

    /// ✓ once when every device agrees, else « ✓ iPhone », « ✕ iPad ».
    private var pills: [(text: String, ok: Bool)] {
        let statuses = row?.statuses ?? []
        func ok(_ s: DependencyStatus) -> Bool {
            switch s {
            case .providedByXSide, .addedByYou, .builtIntoTweak, .notNeeded: true
            case .missing, .jailbreakOnly: false
            }
        }
        if statuses.count <= 1 { return [(statuses.first.map { ok($0.status) } ?? true ? "✓" : "✕", statuses.first.map { ok($0.status) } ?? true)] }
        return statuses.map { s in
            let name = s.deviceID.map { DeviceShortName.short(deviceNames[$0] ?? $0) } ?? ""
            return ((ok(s.status) ? "✓ " : "✕ ") + name, ok(s.status))
        }
    }
}

private struct StatusPill: View {
    let text: String
    let ok: Bool

    var body: some View {
        let tint = ok ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed)
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.13), in: Capsule())
            .fixedSize()
    }
}

/// The row's trash: red on hover; its tooltip says what « Retirer » does.
struct TrashButton: View {
    let help: String
    let a11y: String
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering && isEnabled ? Color(nsColor: .systemRed) : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(a11y)
    }
}

extension String {
    fileprivate var lowercasedFirst: String { (first.map { $0.lowercased() } ?? "") + dropFirst() }
}

extension TweakProblem {
    /// « Injecter quand même » can settle it.
    var isOverridable: Bool { TweakVerdict.incompatible(self).canOverride }
    var isIOSVersion: Bool { if case .iOSVersion = self { true } else { false } }
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
                // A dependency missing here: it can't be turned on (it can be turned off), unless
                // the person removed it on purpose: on again, it shows « À régler » as usual.
                .disabled(isDisabled || row.verdict == nil
                          || (!(row.dependencyRemoved && !row.isOn) && (row.isBlocked || (row.missingHere && !row.isOn))))
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
    func dependencyState(_ target: DependencyTarget, rows: [DependencyRow], names: [String: String],
                         elsewhere: [String: String] = [:]) -> TweakDependencyState {
        TweakDependencyState(rows: rows, deviceNames: names, errors: dependencyErrors, notices: dependencyNotices,
                             progress: dependencyProgress, beingAdded: dependenciesBeingAdded, elsewhere: elsewhere,
                             addDeb: { dep, urls in Task { await self.addDependencyDeb(urls, for: dep, target: target) } },
                             download: { dep in
                                 guard let tweak = self.dependencyRows(target)?.package else { return }
                                 Task { await self.downloadDependency(dep, for: tweak, target: target) }
                             })
    }

    /// Per card (by tweak id): the package ids whose lines another card shows, with that card's
    /// tweak name (`DependencyRows.lineCards`).
    func dependencyLinesElsewhere(_ cards: [TweakPackage], target: (String) -> DependencyTarget) -> [String: [String: String]] {
        var owners = DependencyRows.lineCards(cards.compactMap { p in dependencyRows(target(p.id)).map { (p.id, $0.rows) } })
        // The card that started the last action keeps its lines (while it lists the dependency).
        for (package, tweakID) in dependencyLineOwners where owners[package] != nil && cards.contains(where: { $0.id == tweakID }) {
            owners[package] = tweakID
        }
        let names = Dictionary(cards.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var out: [String: [String: String]] = [:]
        for p in cards {
            for (package, owner) in owners where owner != p.id {
                if let name = names[owner] { out[p.id, default: [:]][package] = name }
            }
        }
        return out
    }

    /// Its own lines (« Mettre à jour »).
    var ownDependencyState: TweakDependencyState {
        TweakDependencyState(rows: [], errors: dependencyErrors, notices: dependencyNotices,
                             progress: dependencyProgress, beingAdded: dependenciesBeingAdded)
    }
}

/// Step ③: the window's tweaks in their three groups, one chip per checked device.
struct InstallTweaksSection: View {
    let model: AppModel
    @Bindable var flow: InstallFlow

    var body: some View {
        let order = DependencyRows.cardOrder(flow.tweaks.map(\.package))
        let elsewhere = model.dependencyLinesElsewhere(order.map(\.package)) { DependencyTarget.draft(tweakID: $0) }
        TweaksSection(isEmpty: flow.tweaks.isEmpty, emptyIntro: L("tweaks.intro.empty"),
                      beingAdded: flow.tweaksBeingAdded, errors: flow.tweakErrors, isDisabled: flow.isRunning,
                      add: { urls in Task { await model.addTweaks(urls, to: flow) } }) {
            EmptyView()
        } cards: {
            GroupedTweakCards(items: items(order, elsewhere: elsewhere), blocksNext: true, isDisabled: flow.isRunning,
                              removeHelp: L("tweaks.remove.help"), lines: model.ownDependencyState)
        }
        .disabled(flow.isRunning)
        .onChange(of: flow.deviceIDs, initial: true) { model.syncTweakDevices(flow) }
    }

    private func items(_ order: [(package: TweakPackage, dependencyOf: [String])],
                       elsewhere: [String: [String: String]]) -> [TweakCardItem] {
        let nestedUnder = TweakNesting.parents(order.map(\.package))
        return order.compactMap { entry -> TweakCardItem? in
            guard nestedUnder[entry.package.id] == nil,
                  let draft = flow.tweaks.first(where: { $0.id == entry.package.id }) else { return nil }
            let target = DependencyTarget.draft(tweakID: draft.id)
            let found = model.dependencyRows(target)
            let nested = order.filter { nestedUnder[$0.package.id] == draft.id }.compactMap { dep -> NestedDependency? in
                guard let d = flow.tweaks.first(where: { $0.id == dep.package.id }) else { return nil }
                let depTarget = DependencyTarget.draft(tweakID: d.id)
                return NestedDependency(package: d.package, rows: rows(d), remove: {
                    guard model.confirmRemovingDependency(d.package, target: depTarget) else { return }
                    model.removeTweak(d.id, from: flow)
                }, update: DependencySources.canDownload(d.package.packageID)
                    ? { Task { await model.updateDependency(d.package, target: depTarget) } } : nil)
            }
            return TweakCardItem(package: draft.package, rows: rows(draft), group: model.draftGroup(draft, in: flow),
                                 dependencies: found.map { model.dependencyState(target, rows: $0.rows, names: $0.deviceNames,
                                                                                 elsewhere: elsewhere[draft.id] ?? [:]) },
                                 nested: nested,
                                 setOn: { id, on in model.setTweak(draft.id, enabled: on, for: id, in: flow) },
                                 setForce: { id, on in model.setTweakForce(draft.id, on, for: id, in: flow) },
                                 remove: { model.removeTweak(draft.id, from: flow) })
        }
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

/// Settings > Mes apps: the installation's tweaks in the same three groups (one chip: this
/// device), what its last signing did with each, the pending line while its choice isn't in the
/// app yet, and the link to every app's downloaded dependencies (Settings > Tweaks).
struct InstalledTweaksSection: View {
    let model: AppModel
    let entry: AppEntry
    let deviceName: String

    private var listed: [(TweakPackage, TweakUse)] { model.listedTweaks(entry) }

    var body: some View {
        let disabled = !model.canManage(entry)
        let listed = listed
        let order = DependencyRows.cardOrder(listed.map(\.0))
        let elsewhere = model.dependencyLinesElsewhere(order.map(\.package)) { DependencyTarget.entry(entry.id, tweakID: $0) }
        TweaksSection(isEmpty: listed.isEmpty, beingAdded: model.tweaksBeingAdded[entry.id] ?? [],
                      errors: model.tweakErrors[entry.id] ?? [], isDisabled: disabled,
                      add: { urls in Task { await model.addTweaks(urls, for: entry) } }) {
            // Every app's kept downloads: Settings > Tweaks (device round 2, item 8).
            Button(L("downloads.open")) { model.settingsPane = .tweaks }
                .buttonStyle(.link)
                .font(.system(size: 11))
        } cards: {
            GroupedTweakCards(items: items(order, listed: listed, elsewhere: elsewhere, disabled: disabled), blocksNext: false,
                              isDisabled: disabled, removeHelp: L("tweaks.remove.helpOne"), lines: model.ownDependencyState)
        }
    }

    private func items(_ order: [(package: TweakPackage, dependencyOf: [String])], listed: [(TweakPackage, TweakUse)],
                       elsewhere: [String: [String: String]], disabled: Bool) -> [TweakCardItem] {
        let nestedUnder = TweakNesting.parents(order.map(\.package))
        let pending = model.pendingTweakIDs(entry)
        return order.compactMap { item -> TweakCardItem? in
            guard nestedUnder[item.package.id] == nil,
                  let (package, use) = listed.first(where: { $0.0.id == item.package.id }) else { return nil }
            let target = DependencyTarget.entry(entry.id, tweakID: package.id)
            let found = model.dependencyRows(target)
            let r = row(package, use: use)
            let nested = order.filter { nestedUnder[$0.package.id] == package.id }.compactMap { dep -> NestedDependency? in
                guard let (p, u) = listed.first(where: { $0.0.id == dep.package.id }) else { return nil }
                let depTarget = DependencyTarget.entry(entry.id, tweakID: p.id)
                return NestedDependency(package: p, rows: [row(p, use: u)], remove: {
                    guard model.confirmRemovingDependency(p, target: depTarget) else { return }
                    Task { await model.removeTweak(p.id, for: entry) }
                }, update: DependencySources.canDownload(p.packageID)
                    ? { Task { await model.updateDependency(p, target: depTarget) } } : nil)
            }
            let group = model.installedTweakGroup(package, use: use, for: entry)
            return TweakCardItem(package: package, rows: [r], group: group,
                                 dependencies: found.map { model.dependencyState(target, rows: $0.rows, names: $0.deviceNames,
                                                                                 elsewhere: elsewhere[package.id] ?? [:]) },
                                 nested: nested,
                                 setOn: { _, on in Task { await model.setTweak(package.id, enabled: on, for: entry) } },
                                 setForce: { _, on in Task { await model.setTweakForce(package.id, on, for: entry) } },
                                 remove: { Task { await model.removeTweak(package.id, for: entry) } },
                                 isPending: pending.contains(package.id))
        }
    }

    private func row(_ package: TweakPackage, use: TweakUse) -> TweakRow {
        let v = model.tweakVerdicts(package, for: entry)
        let signed = entry.installation.signedChoices?.tweaks?.contains(package.id) == true
        let removed = use.enabled ? nil : use.removedDependency
        return TweakRow(deviceID: entry.installation.deviceID, deviceName: deviceName,
                        verdict: v.verdict, forcedVerdict: v.forced, isOn: use.enabled, isForced: use.force == true,
                        result: removed.map { L("tweaks.removedDependency", $0) }
                            ?? TweakText.result(entry.installation.tweakResults?[package.id], package: package,
                                                enabled: use.enabled, signed: signed, deviceName: deviceName),
                        signedAnyway: {
                            if case .injected? = entry.installation.tweakResults?[package.id] { true } else { false }
                        }(),
                        missingHere: !model.missingDependencies(package, for: entry).isEmpty,
                        dependencyRemoved: removed != nil)
    }
}

extension AppModel {
    /// The installation's tweaks with their use there, in its list's order.
    func listedTweaks(_ entry: AppEntry) -> [(TweakPackage, TweakUse)] {
        let pool = entry.record.tweaks ?? []
        return (entry.installation.tweaks ?? []).compactMap { use in pool.first { $0.id == use.id }.map { ($0, use) } }
    }

    /// The group of one of the installation's tweaks (« À régler », « Prêts », « Pas compatibles »).
    func installedTweakGroup(_ package: TweakPackage, use: TweakUse, for entry: AppEntry) -> TweakGroups.Group {
        let v = tweakVerdicts(package, for: entry)
        let signedAnyway = if case .injected? = entry.installation.tweakResults?[package.id] { true } else { false }
        return TweakGroups.group([TweakGroups.DeviceState(verdict: v.verdict, isOn: use.enabled, isForced: use.force == true,
                                                          signedAnyway: signedAnyway,
                                                          missingDependencies: missingDependencies(package, for: entry),
                                                          dependencyRemoved: !use.enabled && use.removedDependency != nil)])
    }

    /// The cards « À régler » on this installation: the Tweaks tab's red badge.
    func tweaksToSettleCount(_ entry: AppEntry) -> Int {
        let listed = listedTweaks(entry)
        let nested = TweakNesting.parents(listed.map(\.0))
        return listed.filter { nested[$0.0.id] == nil && installedTweakGroup($0.0, use: $0.1, for: entry) == .toSettle }.count
    }
}
