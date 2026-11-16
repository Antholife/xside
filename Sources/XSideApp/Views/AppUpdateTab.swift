import AppKit
import SwiftUI
import XSideCore

/// The fiche's « Mises à jour » tab: the GitHub source the app follows (repo, variant, version, what
/// to do when a release comes out), « Vérifier maintenant » and what the check found as cards
/// (stable: install; beta: only announced; suspect: blocked in auto, to examine). An app without a
/// source can add one here. It is also where an update notification lands.
struct AppUpdateTab: View {
    let model: AppModel
    let entry: AppEntry
    let appName: String

    @State private var reports: [UpdateCheckReport]?
    @State private var checking = false
    @State private var busy: Set<String> = [] // `tweakPackageID ?? "app"` of the report being installed
    /// What the person acknowledged per card; a beta that is also suspect needs both, one card at a time.
    @State private var approvals: [String: Approval] = [:]
    /// Reasons acknowledged for one exact release only.
    private struct Approval { var tag: String; var asset: String; var reasons: Set<NotifyReason> }
    @State private var editing = false
    @State private var urlText = ""
    @State private var saving = false
    @State private var formError: String?

    private var record: AppRecord { model.records.first { $0.id == entry.record.id } ?? entry.record }
    private var source: UpdateSource? { record.updateSource }
    private var tracked: [TweakPackage] { (record.tweaks ?? []).filter { $0.updateSource != nil } }
    private var hasAnySource: Bool { source != nil || !tracked.isEmpty }
    private var parsed: GitHubSource? { GitHubSource.parse(urlText) }
    private var canManage: Bool { model.canManage(entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(L("update.tab.title"))
                VStack(alignment: .leading, spacing: 0) {
                    if let source, !editing {
                        sourceCard(source)
                    } else {
                        addForm(replacing: source != nil)
                    }
                }
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !tracked.isEmpty { tweakCard }
            if hasAnySource { checkArea }
        }
    }

    // MARK: Source

    private func sourceCard(_ source: UpdateSource) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionRow(symbol: "arrow.down.circle.fill", title: "\(source.repo.owner)/\(source.repo.repo)",
                      detail: variantLine(source)) {
                Button(L("update.tab.open")) { NSWorkspace.shared.open(source.repo.page) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            Divider().padding(.leading, 48)
            OptionRow(symbol: "bolt.fill", title: L("update.mode.title"), detail: nil) {
                Picker(L("update.mode.title"), selection: modeBinding(source.mode) { mode in
                    var s = source; s.mode = mode; save(s)
                }) {
                    Text(L("update.mode.notify")).tag(UpdateMode.notify)
                    Text(L("update.mode.auto")).tag(UpdateMode.auto)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            HStack(spacing: 10) {
                Button(L("update.tab.variant")) { Task { await repickVariant(source) } }
                Button(L("update.tab.edit")) { urlText = "https://github.com/\(source.repo.owner)/\(source.repo.repo)"; editing = true }
                Button(L("update.tab.remove"), role: .destructive) { remove() }
            }
            .controlSize(.small)
            .padding(.leading, 48)
            .padding(.trailing, 12)
            .padding(.bottom, 10)
        }
        .disabled(!canManage)
    }

    private func variantLine(_ source: UpdateSource) -> String {
        var parts = [L("update.tab.variant.tracked", source.variant.stableTokens.joined(separator: " "))]
        if let v = record.version { parts.append(L("update.tab.version", v)) }
        return parts.joined(separator: " · ")
    }

    private func modeBinding(_ current: UpdateMode, set: @escaping (UpdateMode) -> Void) -> Binding<UpdateMode> {
        Binding(get: { current }, set: set)
    }

    private func addForm(replacing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(replacing ? "update.tab.edit.note" : "update.tab.add.note"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(L("update.source.link"), text: $urlText, prompt: Text(L("update.source.placeholder")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .onSubmit { Task { await follow() } }
                if !urlText.trimmingCharacters(in: .whitespaces).isEmpty {
                    if parsed != nil {
                        Label(L("update.source.recognized"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color(nsColor: .systemGreen))
                    } else {
                        Label(L("update.source.invalid"), systemImage: "xmark.circle.fill")
                            .foregroundStyle(Color(nsColor: .systemRed))
                    }
                }
            }
            .font(.system(size: 11))
            HStack(spacing: 8) {
                Button(L("update.tab.follow")) { Task { await follow() } }
                    .disabled(parsed == nil || saving || !canManage)
                if replacing { Button(L("install.cancel")) { editing = false; formError = nil } }
                if saving { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            if let formError {
                Label(formError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    // MARK: Tweaks

    private var tweakCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L("update.tab.tweaks"))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tracked.enumerated()), id: \.element.id) { i, tweak in
                    if i > 0 { Divider().padding(.leading, 48) }
                    if let s = tweak.updateSource {
                        OptionRow(symbol: "puzzlepiece.extension.fill", title: tweak.name,
                                  detail: "\(s.repo.owner)/\(s.repo.repo)") {
                            Picker(L("update.mode.title"), selection: modeBinding(s.mode) { mode in
                                var n = s; n.mode = mode; save(n, tweakID: tweak.id)
                            }) {
                                Text(L("update.mode.notify")).tag(UpdateMode.notify)
                                Text(L("update.mode.auto")).tag(UpdateMode.auto)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                    }
                }
            }
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(!canManage)
        }
    }

    // MARK: Check

    private var checkArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reports {
                ForEach(reports, id: \.key) { card(for: $0) }
            }
            HStack(spacing: 10) {
                Button(L("update.tab.check")) { Task { await check() } }
                    .disabled(checking || !canManage)
                if checking { ProgressView().controlSize(.small) }
                Text(L("update.tab.check.note"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private enum Tone { case green, orange, red, plain }

    @ViewBuilder private func card(for report: UpdateCheckReport) -> some View {
        let prefix = reports.map { $0.count > 1 } == true ? "\(report.name): " : ""
        switch report.result {
        case .upToDate:
            stateCard(symbol: "checkmark.circle.fill", tone: .green, title: prefix + L("update.state.upToDate"), detail: nil, report: report, actions: [])
        case .installed(let v):
            stateCard(symbol: "checkmark.circle.fill", tone: .green, title: prefix + L("update.state.installed", v), detail: nil, report: report, actions: [])
        case .available(let v, let reason, _, _):
            switch reason {
            case .prerelease:
                stateCard(symbol: "flask.fill", tone: .orange, title: prefix + L("update.state.beta", v),
                          detail: L("update.state.beta.note"), report: report, actions: [.installAnyway, .view])
            case .suspect:
                stateCard(symbol: "exclamationmark.triangle.fill", tone: .red, title: prefix + L("update.state.suspect", v),
                          detail: L("update.state.suspect.note"), report: report, actions: [.examineSuspect])
            case .notifyMode:
                stateCard(symbol: "arrow.up.circle.fill", tone: .green, title: prefix + L("update.state.available", v),
                          detail: L("update.state.available.note"), report: report, actions: [.install, .view])
            }
        case .needsVariantChoice:
            stateCard(symbol: "exclamationmark.triangle.fill", tone: .red, title: prefix + L("update.state.variant"),
                      detail: L("update.state.variant.note"), report: report,
                      actions: report.tweakPackageID == nil ? [.examineVariant] : [.view])
        case .changed:
            stateCard(symbol: "arrow.triangle.2.circlepath", tone: .orange, title: prefix + L("update.state.changed"),
                      detail: L("update.state.changed.note"), report: report, actions: [])
        case .failed:
            Label(prefix + L("update.state.failed"), systemImage: "wifi.exclamationmark")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private enum CardAction { case install, installAnyway, view, examineVariant, examineSuspect }

    private func stateCard(symbol: String, tone: Tone, title: String, detail: String?, report: UpdateCheckReport,
                           actions: [CardAction]) -> some View {
        let color: Color = switch tone {
        case .green: Color(nsColor: .systemGreen)
        case .orange: Color(nsColor: .systemOrange)
        case .red: Color(nsColor: .systemRed)
        case .plain: .secondary
        }
        return HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if busy.contains(report.tweakPackageID ?? "app") {
                ProgressView().controlSize(.small)
            } else {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                    actionButton(a, report: report, prominent: a == actions.first && tone != .orange)
                }
            }
        }
        .padding(12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder private func actionButton(_ a: CardAction, report: UpdateCheckReport, prominent: Bool) -> some View {
        switch a {
        case .install:
            Button(L("update.action.install")) { Task { await install(report, confirm: false) } }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(!canManage)
        case .installAnyway:
            Button(L("update.action.installAnyway")) { Task { await install(report, confirm: true) } }
                .controlSize(.small).disabled(!canManage)
        case .view:
            Button(L("update.action.view")) { view(report) }.controlSize(.small)
        case .examineSuspect:
            Button(L("update.action.examine")) { view(report); Task { await install(report, confirm: true) } }
                .controlSize(.small).disabled(!canManage)
        case .examineVariant:
            Button(L("update.action.examine")) { if let source { Task { await repickVariant(source) } } }.controlSize(.small)
        }
    }

    // MARK: Actions

    private func check() async {
        checking = true
        defer { checking = false }
        approvals = [:]
        reports = await model.checkUpdatesNow(entry)
    }

    private func install(_ report: UpdateCheckReport, confirm: Bool) async {
        if confirm {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = L("update.confirm.title", report.name)
            alert.informativeText = L("update.confirm.message")
            alert.addButton(withTitle: L("update.action.installAnyway"))
            alert.addButton(withTitle: L("install.cancel")).keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard case .available(_, let reason, let tag, let asset) = report.result else { return }
        // « Installer » acknowledges nothing: a beta or a suspect content comes back as its own card.
        let key = report.tweakPackageID ?? "app"
        // An approval holds only for the release it was given for.
        if approvals[key].map({ $0.tag != tag || $0.asset != asset }) == true { approvals[key] = nil }
        if confirm, reason != .notifyMode {
            var a = approvals[key] ?? Approval(tag: tag, asset: asset, reasons: [])
            a.reasons.insert(reason)
            approvals[key] = a
        }
        let approved = approvals[key]?.reasons ?? []
        busy.insert(key)
        defer { busy.remove(key) }
        let result = await model.installUpdateNow(entry, tweakPackageID: report.tweakPackageID, expectedTag: tag,
                                                  expectedAsset: asset, approved: approved)
        guard var all = reports, let i = all.firstIndex(where: { ($0.tweakPackageID ?? "app") == key }) else { return }
        switch result {
        case .available(_, _, let t, let a):
            if let ap = approvals[key], ap.tag != t || ap.asset != a { approvals[key] = nil }
        default: approvals[key] = nil
        }
        all[i] = UpdateCheckReport(name: report.name, result: result, tweakPackageID: report.tweakPackageID)
        reports = all
    }

    private func view(_ report: UpdateCheckReport) {
        let repo = report.tweakPackageID.flatMap { id in tracked.first { $0.packageID == id }?.updateSource?.repo } ?? source?.repo
        if let repo { NSWorkspace.shared.open(repo.page) }
    }

    private func save(_ new: UpdateSource, tweakID: String? = nil) {
        Task {
            do {
                if let tweakID {
                    try await model.library.setUpdateSource(new, forTweak: tweakID, recordID: record.id)
                } else {
                    try await model.library.setUpdateSource(new, forRecord: record.id)
                }
                await model.reloadRecords()
            } catch {
                Log("updates").error("could not save the update source: \(error)")
            }
        }
    }

    private func remove() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("update.remove.title", appName)
        alert.informativeText = L("update.remove.message")
        alert.addButton(withTitle: L("update.tab.remove"))
        alert.addButton(withTitle: L("install.cancel")).keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await model.library.setUpdateSource(nil, forRecord: record.id)
                await model.reloadRecords()
                reports = nil
            } catch {
                Log("updates").error("could not remove the update source: \(error)")
            }
        }
    }

    /// Reads the repo's newest release and follows the variant the person picks (one file: as is).
    private func follow() async {
        guard let repo = parsed else { return }
        saving = true
        formError = nil
        defer { saving = false }
        do {
            let all = try await model.installableIPAs(of: repo)
            guard let newest = all.first?.tag else { formError = L("update.source.noAsset"); return }
            let names = all.filter { $0.tag == newest }.map(\.asset.name)
            let current = source?.repo == repo ? source : nil
            var chosen = names[0]
            if names.count > 1 {
                guard let picked = UpdateSourceAlerts.chooseVariant(app: appName, names: names, current: nil) else { return }
                chosen = picked
            }
            let variant = VariantSelector.make(chosen: chosen, others: names.filter { $0 != chosen })
            let new = UpdateSource(repo: repo, variant: variant, mode: current?.mode ?? .notify, lastSeenTrigger: nil)
            try await model.library.setUpdateSource(new, forRecord: record.id)
            await model.reloadRecords()
            editing = false
            reports = nil
        } catch {
            formError = L("update.source.failed")
        }
    }

    /// « Changer de variante » / « Examiner » on a variant to choose: the same popup as at install.
    private func repickVariant(_ source: UpdateSource) async {
        do {
            let all = try await model.installableIPAs(of: source.repo)
            guard let newest = all.first?.tag else { return }
            let names = all.filter { $0.tag == newest }.map(\.asset.name)
            guard let picked = UpdateSourceAlerts.chooseVariant(app: appName, names: names, current: nil) else { return }
            var new = source
            new.variant = VariantSelector.make(chosen: picked, others: names.filter { $0 != picked })
            try await model.library.setUpdateSource(new, forRecord: record.id)
            await model.reloadRecords()
        } catch {
            formError = L("update.source.failed")
        }
    }
}

/// The Tweaks tab's light line per tweak that follows a GitHub source: repo and mode (the mode is
/// changed on the « Mises à jour » tab).
struct TweakSourceLines: View {
    let entry: AppEntry

    var body: some View {
        let tracked = (entry.record.tweaks ?? []).filter { $0.updateSource != nil }
        if !tracked.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(tracked, id: \.id) { t in
                    if let s = t.updateSource {
                        Label(L("update.tweak.line", t.name, "\(s.repo.owner)/\(s.repo.repo)",
                                L(s.mode == .auto ? "update.mode.auto" : "update.mode.notify")),
                              systemImage: "arrow.down.circle")
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}
