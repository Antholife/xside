import AppKit
import SwiftUI
import XSideCore

/// "Restaurer depuis l'archive" (Time Machine style): lists the apps an `.xsbak` holds and, per app,
/// what to bring back (App, Compatibilité, In-app, Tweaks, Données), onto a chosen target device.
struct FullRestoreSheet: View {
    let model: AppModel
    let archive: URL
    let manifest: FullBackupManifest
    let dismiss: () -> Void

    @State private var targetDeviceID: String = ""
    @State private var choices: [String: BackupAspects] = [:]
    @State private var running: Double?
    @State private var status = "" // the app being restored now

    private var entries: [BackupAppEntry] { manifest.apps }
    private func key(_ e: BackupAppEntry) -> String { "\(e.recordID)-\(e.installation.sourceDeviceID)" }
    private var targets: [Device] { model.devices.filter { $0.isAvailable } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("backup.restore.title")).font(.system(size: 15, weight: .bold))
                Text(L("backup.restore.subtitle", archive.lastPathComponent, entries.count))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 11)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    legend
                    HStack {
                        Text(L("backup.restore.target")).font(.system(size: 12.5))
                        Picker("", selection: $targetDeviceID) {
                            ForEach(targets, id: \.id) { d in Text(d.name).tag(d.id) }
                        }.labelsHidden().fixedSize()
                        Spacer()
                        Button(L("backup.full.all")) { selectAll() }.buttonStyle(.link)
                    }
                    header
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, e in row(e) }
                    }
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text(L("backup.restore.note")).font(.system(size: 11.5)).foregroundStyle(.secondary)
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
            GridRow { legendItem("backup.aspect.app.desc"); legendItem("backup.aspect.compat.desc") }
            GridRow { legendItem("backup.aspect.inApp.desc"); legendItem("backup.aspect.tweaks.desc") }
            GridRow { legendItem("backup.aspect.data.desc") }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
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
                Text(L(c.title)).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).frame(width: 86)
            }
        }
        .padding(.trailing, 12)
    }

    private func row(_ e: BackupAppEntry) -> some View {
        let chosen = choices[key(e)] ?? BackupAspects()
        let avail = e.availableAspects
        return HStack(spacing: 2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(e.displayName).font(.system(size: 13, weight: .medium))
                Text(subtitle(e)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            ForEach(columns, id: \.title) { c in cell(e, path: c.path, chosen: chosen, avail: avail) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .overlay(alignment: .top) { Divider().opacity(e.recordID == entries.first?.recordID ? 0 : 1) }
    }

    private func cell(_ e: BackupAppEntry, path: WritableKeyPath<BackupAspects, Bool>,
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

    private func subtitle(_ e: BackupAppEntry) -> String {
        var parts: [String] = []
        if e.hasIPA { parts.append("IPA \(size(e.ipaBytes))") }
        if !e.installation.tweaks.isEmpty { parts.append(L("backup.restore.tweakCount", e.installation.tweaks.count)) }
        if e.hasData { parts.append(L("backup.restore.dataSize", size(e.dataBytes))) }
        return parts.joined(separator: " · ")
    }

    private func size(_ b: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }

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
            Text(L("backup.restore.count", restoreCount)).font(.system(size: 12)).foregroundStyle(.secondary)
            Button(L("backup.restore.go")) { restore() }
                .buttonStyle(GradientButtonStyle()).controlSize(.large).frame(minWidth: 130)
                .keyboardShortcut(.defaultAction)
                .disabled(restoreCount == 0 || targetDeviceID.isEmpty || running != nil)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var restoreCount: Int {
        entries.reduce(0) { $0 + (FullBackup.restoreAction(available: $1.availableAspects, chosen: choices[key($1)] ?? BackupAspects()) == .skip ? 0 : 1) }
    }

    private func prepare() {
        for e in entries { choices[key(e)] = e.availableAspects }
        // Default target: the source device if it is available, else the first available device.
        let sources = Set(entries.map { $0.installation.sourceDeviceID })
        targetDeviceID = targets.first { sources.contains($0.id) }?.id ?? targets.first?.id ?? ""
    }

    private func selectAll() {
        let anyOff = entries.contains { (choices[key($0)] ?? BackupAspects()) != $0.availableAspects }
        for e in entries { choices[key(e)] = anyOff ? e.availableAspects : BackupAspects() }
    }

    private func toggle(_ e: BackupAppEntry, _ path: WritableKeyPath<BackupAspects, Bool>) {
        let k = key(e)
        var c = choices[k] ?? BackupAspects()
        c[keyPath: path].toggle()
        if path == \BackupAspects.app && !c.app { c.compat = false; c.inApp = false; c.tweaks = false }
        choices[k] = c
    }

    private func restore() {
        let selections: [(entry: BackupAppEntry, chosen: BackupAspects)] = entries.compactMap { e in
            let c = choices[key(e)] ?? BackupAspects()
            return FullBackup.restoreAction(available: e.availableAspects, chosen: c) == .skip ? nil : (e, c)
        }
        running = 0
        Task {
            let result = await model.restoreFullBackup(archive: archive, selections: selections, targetDeviceID: targetDeviceID) { f, name in
                Task { @MainActor in running = f; status = name }
            }
            running = nil; status = ""
            if result.restored > 0 {
                model.showToast(L("backup.restore.done", result.restored))
                dismiss()
            } else {
                AppDataActions.alert(L("backup.restore.failed"))
            }
        }
    }
}
