import AppKit
import SwiftUI
import XSideCore

/// "Sauvegarde complète": pick, per app, what to archive (App, Compatibilité, In-app, Tweaks,
/// Données), then write one `.xsbak`. Compatibility / in-app / tweaks ride with App; Données is
/// independent. A column is greyed when the app does not have that aspect (or App is unchecked).
struct FullBackupSheet: View {
    let model: AppModel
    let dismiss: () -> Void

    @State private var includeCaches = true
    @State private var choices: [String: BackupAspects] = [:]
    @State private var available: [String: BackupAspects] = [:]
    @State private var ipaBytes: [String: Int] = [:]
    @State private var running: Double?
    @State private var status = "" // the app being backed up now

    private var entries: [AppEntry] { model.deviceGroups.flatMap(\.apps) }
    private func key(_ e: AppEntry) -> String { "\(e.record.id)-\(e.installation.deviceID)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("backup.full.title")).font(.system(size: 15, weight: .bold))
                Text(L("backup.full.subtitle")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 11)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    legend
                    HStack {
                        Toggle(isOn: $includeCaches) { Text(L("backup.full.caches")) }.toggleStyle(.switch)
                        Spacer()
                        Button(L("backup.full.all")) { selectAll() }.buttonStyle(.link)
                    }
                    header
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, e in row(e) }
                    }
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text(L("backup.full.note")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
            .frame(maxHeight: 420)
            Divider()
            footer
        }
        .frame(width: 720)
        .onAppear(perform: prepare)
    }

    private var legend: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                legendItem("backup.aspect.app.desc"); legendItem("backup.aspect.compat.desc")
            }
            GridRow {
                legendItem("backup.aspect.inApp.desc"); legendItem("backup.aspect.tweaks.desc")
            }
            GridRow { legendItem("backup.aspect.data.desc") }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func legendItem(_ k: String) -> some View {
        Text(L(k)).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var columns: [(title: String, path: WritableKeyPath<BackupAspects, Bool>)] {
        [("backup.col.app", \.app), ("backup.col.compat", \.compat), ("backup.col.inApp", \.inApp),
         ("backup.col.tweaks", \.tweaks), ("backup.col.data", \.data)]
    }

    private var header: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)
            ForEach(columns, id: \.title) { c in
                Text(L(c.title)).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 86)
            }
        }
        .padding(.trailing, 12)
    }

    private func row(_ e: AppEntry) -> some View {
        let k = key(e)
        let chosen = choices[k] ?? BackupAspects()
        let avail = available[k] ?? BackupAspects()
        return HStack(spacing: 2) {
            AppIconView(icon: model.icons.image(for: e.record), size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.record.options.displayName ?? e.record.displayName).font(.system(size: 13, weight: .medium))
                Text(subtitle(e)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            ForEach(columns, id: \.title) { c in
                cell(e, path: c.path, chosen: chosen, avail: avail)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .overlay(alignment: .top) { Divider().opacity(e.id == entries.first?.id ? 0 : 1) }
    }

    private func cell(_ e: AppEntry, path: WritableKeyPath<BackupAspects, Bool>,
                      chosen: BackupAspects, avail: BackupAspects) -> some View {
        let needsApp = path != \BackupAspects.app && path != \BackupAspects.data
        let enabled = avail[keyPath: path] && (!needsApp || chosen.app)
        let on = chosen[keyPath: path] && enabled
        return Button { toggle(e, path) } label: {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .font(.system(size: 16))
                .foregroundStyle(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.secondary.opacity(enabled ? 0.6 : 0.2)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || running != nil)
        .frame(width: 86)
    }

    private func subtitle(_ e: AppEntry) -> String {
        let dev = model.deviceDisplayName(e.installation.deviceID)
        let size = ipaBytes[key(e)].map { " · \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? ""
        let ver = e.record.version.map { " · \($0)" } ?? ""
        return dev + ver + size
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let running {
                ProgressView(value: running).frame(width: 140)
                Text("\(Int((running * 100).rounded())) %" + (status.isEmpty ? "" : " · \(status)"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Button(L("install.cancel"), action: dismiss).controlSize(.large).keyboardShortcut(.cancelAction)
                .disabled(running != nil)
            Spacer()
            Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
            Button(L("backup.full.save")) { save() }
                .buttonStyle(GradientButtonStyle()).controlSize(.large).frame(minWidth: 130)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCount == 0 || running != nil)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    // MARK: State

    private var selectedCount: Int {
        entries.reduce(0) { $0 + (FullBackup.isIncluded(resolved($1)) ? 1 : 0) }
    }

    private var summary: String {
        let bytes = entries.reduce(0) { sum, e in
            sum + FullBackup.entryBytes(resolved(e), ipaBytes: ipaBytes[key(e)] ?? 0, dataBytes: 0)
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return L("backup.full.count", selectedCount, size)
    }

    private func resolved(_ e: AppEntry) -> BackupAspects {
        FullBackup.backupInclusion(available: available[key(e)] ?? BackupAspects(), chosen: choices[key(e)] ?? BackupAspects())
    }

    private func prepare() {
        let fm = FileManager.default
        for e in entries {
            let k = key(e)
            let avail = model.fullBackupAvailability(record: e.record, installation: e.installation,
                                                     dataReachable: model.isReachable(e))
            available[k] = avail
            choices[k] = avail // everything available ticked by default
            if let n = try? fm.attributesOfItem(atPath: model.libraryRoot.appendingPathComponent(e.record.ipaPath).path)[.size] as? Int {
                ipaBytes[k] = n
            }
        }
    }

    private func selectAll() {
        let anyOff = entries.contains { (choices[key($0)] ?? BackupAspects()) != (available[key($0)] ?? BackupAspects()) }
        for e in entries { choices[key(e)] = anyOff ? (available[key(e)] ?? BackupAspects()) : BackupAspects() }
    }

    private func toggle(_ e: AppEntry, _ path: WritableKeyPath<BackupAspects, Bool>) {
        let k = key(e)
        var c = choices[k] ?? BackupAspects()
        c[keyPath: path].toggle()
        if path == \BackupAspects.app && !c.app { c.compat = false; c.inApp = false; c.tweaks = false }
        choices[k] = c
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "XSide-complet-\(Self.stamp()).xsbak"
        panel.prompt = L("backup.full.save")
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let selections: [(entry: AppEntry, chosen: BackupAspects)] = entries.compactMap { e in
            let c = choices[key(e)] ?? BackupAspects()
            return FullBackup.isIncluded(FullBackup.backupInclusion(available: available[key(e)] ?? BackupAspects(), chosen: c)) ? (e, c) : nil
        }
        running = 0
        Task {
            let result = await model.makeFullBackup(selections: selections, includeCaches: includeCaches, to: dest) { f, name in
                Task { @MainActor in running = f; status = name }
            }
            running = nil; status = ""
            if result.saved > 0 {
                model.showToast(L("backup.full.done", result.saved))
                dismiss()
            } else {
                AppDataActions.alert(L("backup.full.failed"))
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }
}
