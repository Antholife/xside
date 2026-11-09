import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XSideCore

/// « Tweaks »: the person's own tweaks for this app, under the compatibility fixes (step ②) or
/// in Settings > Mes apps. A drop zone and « Ajouter un tweak… », the files being checked, why
/// the last ones couldn't be added (orange lines, never an alert), then one card per tweak.
struct TweaksSection<Cards: View>: View {
    let beingAdded: [String]
    let errors: [String]
    var isDisabled = false
    let add: ([URL]) -> Void
    @ViewBuilder let cards: Cards
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(L("tweaks.section"))
                Text(L("tweaks.caption"))
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
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isTargeted ? AnyShapeStyle(Theme.violet) : AnyShapeStyle(.secondary))
            Text(L("tweaks.drop"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L("tweaks.add")) { if let urls = Self.choose() { add(urls) } }
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

/// One device's line of a tweak card.
struct TweakRow: Identifiable {
    let deviceID: String
    /// Shown above the row when the card has several devices.
    let label: String?
    /// The device's name, for an iOS version problem and the switch's description.
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

    var id: String { deviceID }

    /// What applies: the forced verdict when « Injecter quand même » is on and allowed.
    var applied: TweakVerdict? { isForced && verdict?.canOverride == true ? forcedVerdict ?? verdict : verdict }
    var isBlocked: Bool {
        if case .incompatible? = applied { return !signedAnyway }
        return false
    }
}

/// A tweak: what it is (name, version, author, target, notes), « Dépendances… » and « Retirer »,
/// then one row per device with its verdict there, fully explained (the reason line highlighted),
/// its switch, and « Injecter quand même » when the problem allows it.
struct TweakCard: View {
    let package: TweakPackage
    let rows: [TweakRow]
    let removeHelp: String
    let setOn: (String, Bool) -> Void
    let setForce: (String, Bool) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(rows) { row in
                Divider().padding(.leading, 48)
                TweakDeviceRow(package: package, row: row, setOn: { setOn(row.deviceID, $0) },
                               setForce: { setForce(row.deviceID, $0) })
            }
        }
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var meta: String {
        var parts: [String] = []
        if let v = package.version, !v.isEmpty { parts.append(L("tweaks.version", v)) }
        if let a = package.author, !a.isEmpty { parts.append(L("tweaks.author", a)) }
        parts.append(TweakText.targetLine(package))
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(package.name)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(package.notes, id: \.self) { note in
                    Label(TweakText.note(note), systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    // The dependencies screen comes with Task 18.
                    Button(L("tweaks.dependencies")) {}
                        .disabled(true)
                        .help(L("tweaks.dependencies.help"))
                    Button(L("tweaks.remove"), action: remove)
                        .help(removeHelp)
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }
}

private struct TweakDeviceRow: View {
    let package: TweakPackage
    let row: TweakRow
    let setOn: (Bool) -> Void
    let setForce: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Color.clear.frame(width: 26, height: 1)
            VStack(alignment: .leading, spacing: 5) {
                if let label = row.label {
                    Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                if let verdict = row.verdict {
                    if verdict.canOverride, row.isForced, case .incompatible(let problem) = verdict {
                        forcedExplanation(problem)
                    } else {
                        explanation(verdict)
                    }
                    if verdict.canOverride {
                        Toggle(L(TweakVerdict.overrideKey), isOn: Binding(get: { row.isForced }, set: setForce))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                    }
                    if row.signedAnyway, case .incompatible? = row.applied {
                        Label(L("tweaks.signedAnyway"), systemImage: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let result = row.result {
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(L("tweaks.enable.a11y", package.name, row.deviceName),
                   isOn: Binding(get: { row.isOn && !row.isBlocked }, set: setOn))
                .labelsHidden()
                .toggleStyle(.xside)
                .controlSize(.small)
                .disabled(row.isBlocked || row.verdict == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    /// « Injecter quand même » on: one line, « Injecté quand même — fait pour une autre app (…) »,
    /// then what XSide changes when the forced tweak is converted. Another problem still stands.
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

    /// The status line (highlighted, with the reason for ❌), then for 🔧 every change, always shown.
    @ViewBuilder private func explanation(_ verdict: TweakVerdict) -> some View {
        switch verdict {
        case .compatible:
            TweakStatusLine(text: L("tweaks.status.compatible"), kind: .compatible)
        case .converted(let list):
            TweakStatusLine(text: L("tweaks.status.converted"), kind: .converted)
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
    enum Kind { case compatible, converted, incompatible, forced }
    let text: String
    let kind: Kind

    private var tint: Color {
        switch kind {
        case .compatible: Color(nsColor: .systemGreen)
        case .converted: Color(nsColor: .systemOrange)
        case .incompatible: Color(nsColor: .systemRed)
        case .forced: Color(nsColor: .systemOrange)
        }
    }

    private var symbol: String {
        switch kind {
        case .compatible: "checkmark.seal.fill"
        case .converted: "wrench.and.screwdriver.fill"
        case .incompatible: "xmark.octagon.fill"
        case .forced: "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Step ②: the window's tweaks, one row per checked device.
struct InstallTweaksSection: View {
    let model: AppModel
    @Bindable var flow: InstallFlow

    var body: some View {
        TweaksSection(beingAdded: flow.tweaksBeingAdded, errors: flow.tweakErrors, isDisabled: flow.isRunning,
                      add: { urls in Task { await model.addTweaks(urls, to: flow) } }) {
            ForEach(flow.tweaks) { draft in
                TweakCard(package: draft.package, rows: rows(draft), removeHelp: L("tweaks.remove.help"),
                          setOn: { id, on in model.setTweak(draft.id, enabled: on, for: id, in: flow) },
                          setForce: { id, on in model.setTweakForce(draft.id, on, for: id, in: flow) },
                          remove: { model.removeTweak(draft.id, from: flow) })
            }
        }
        .disabled(flow.isRunning)
        .onChange(of: flow.deviceIDs, initial: true) { model.syncTweakDevices(flow) }
    }

    private func rows(_ draft: TweakDraft) -> [TweakRow] {
        let several = flow.deviceIDs.count > 1
        return flow.deviceIDs.map { id in
            let name = model.devices.first { $0.id == id }?.name ?? L("popover.unknownDevice")
            return TweakRow(deviceID: id, label: several ? name : nil, deviceName: name,
                            verdict: draft.verdicts[id], forcedVerdict: draft.forcedVerdicts[id],
                            isOn: draft.enabledDevices.contains(id), isForced: draft.force.contains(id),
                            signedAnyway: draft.injectedOn.contains(id))
        }
    }
}

/// Settings > Mes apps: the installation's tweaks (one row: this device), what its last signing
/// did with each, and the pending line while its choice isn't in the app yet.
struct InstalledTweaksSection<Notice: View>: View {
    let model: AppModel
    let entry: AppEntry
    let deviceName: String
    @ViewBuilder let pendingNotice: Notice

    private var listed: [(TweakPackage, TweakUse)] {
        let pool = entry.record.tweaks ?? []
        return (entry.installation.tweaks ?? []).compactMap { use in pool.first { $0.id == use.id }.map { ($0, use) } }
    }

    var body: some View {
        let disabled = !model.canManage(entry)
        TweaksSection(beingAdded: model.tweaksBeingAdded[entry.id] ?? [], errors: model.tweakErrors[entry.id] ?? [],
                      isDisabled: disabled, add: { urls in Task { await model.addTweaks(urls, for: entry) } }) {
            ForEach(listed, id: \.0.id) { package, use in
                let v = model.tweakVerdicts(package, for: entry)
                let signed = entry.installation.signedChoices?.tweaks?.contains(package.id) == true
                TweakCard(package: package,
                          rows: [TweakRow(deviceID: entry.installation.deviceID, label: nil, deviceName: deviceName,
                                          verdict: v.verdict, forcedVerdict: v.forced, isOn: use.enabled,
                                          isForced: use.force == true,
                                          result: TweakText.result(entry.installation.tweakResults?[package.id], package: package,
                                                                   enabled: use.enabled, signed: signed, deviceName: deviceName),
                                          signedAnyway: {
                                              if case .injected? = entry.installation.tweakResults?[package.id] { true } else { false }
                                          }())],
                          removeHelp: L("tweaks.remove.helpOne"),
                          setOn: { _, on in Task { await model.setTweak(package.id, enabled: on, for: entry) } },
                          setForce: { _, on in Task { await model.setTweakForce(package.id, on, for: entry) } },
                          remove: { Task { await model.removeTweak(package.id, for: entry) } })
            }
            pendingNotice
        }
        .disabled(disabled)
    }
}
