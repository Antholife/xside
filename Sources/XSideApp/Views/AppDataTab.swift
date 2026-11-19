import AppKit
import SwiftUI
import XSideCore

/// The fiche's data actions, shared by the « Données » tab and the header's « ⋯ » menu.
@MainActor enum AppDataActions {
    /// Starts a cancellable backup held by the model (cancel with `model.cancelBackup`), toasts its
    /// outcome, then runs `then`.
    @discardableResult
    static func startBackUp(_ entry: AppEntry, model: AppModel, then: @escaping () async -> Void = {}) -> Bool {
        model.startBackup(entry) { outcome in
            report(outcome, model: model)
            await then()
        }
    }

    @discardableResult
    private static func report(_ outcome: AppModel.BackupOutcome, model: AppModel) -> Bool {
        switch outcome {
        case .saved(let version):
            model.showToast(BackupSnapshot.versionLabel(version).map { L("toast.backedUp.version", $0) } ?? L("toast.backedUp"))
            return true
        case .unchanged: model.showToast(L("toast.backedUp.unchanged")); return true
        case .cancelled: model.showToast(L("toast.backupCancelled")); return false
        case .failed: alert(L("fiche.data.backUpNow.failed")); return false
        }
    }

    /// Exports the newest snapshot of this installation through a save panel.
    @discardableResult
    static func exportLatest(_ entry: AppEntry, model: AppModel) async -> Bool {
        let snaps = await model.backups(forRecord: entry.record.id).filter { $0.deviceID == entry.installation.deviceID }
        guard let latest = snaps.first else { alert(L("fiche.data.empty")); return false }
        return await export(latest, model: model)
    }

    /// True when the zip was saved (false: failed or cancelled).
    @discardableResult
    static func export(_ snap: BackupSnapshot, model: AppModel) async -> Bool {
        guard let zip = await model.exportBackup(snap.id) else { alert(L("settings.appData.export.failed")); return false }
        defer { cleanUp(zip) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = zip.lastPathComponent
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let dest = panel.url else { return false }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: zip, backupItemName: nil, options: [])
            } else {
                try FileManager.default.copyItem(at: zip, to: dest)
            }
        } catch { alert(L("settings.appData.export.failed")); return false }
        model.showToast(L("toast.exported"))
        return true
    }

    /// Picks a .zip, confirms the explicit target (this app, this device), then imports.
    @discardableResult
    static func importData(_ entry: AppEntry, appName: String, deviceName: String, model: AppModel) async -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = L("fiche.data.import.choose")
        guard panel.runModal() == .OK, let zip = panel.url else { return false }
        let a = NSAlert()
        a.messageText = L("fiche.data.import.title", appName)
        a.informativeText = L("fiche.data.import.note", appName, deviceName)
        a.addButton(withTitle: L("fiche.data.import"))
        a.addButton(withTitle: L("install.cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        let ok = await model.importBackup(zip: zip, intoRecordID: entry.record.id, deviceID: entry.installation.deviceID)
        if ok { model.showToast(L("toast.imported")) } else { alert(L("fiche.data.import.mismatch")) }
        return ok
    }

    static func alert(_ title: String) {
        let a = NSAlert()
        a.messageText = title
        a.runModal()
    }

    /// Removes the temporary zip, and its folder only when it is the `xside-export-*` child of the
    /// temporary directory that `exportBackup` created.
    private static func cleanUp(_ zip: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: zip)
        let parent = zip.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let temp = fm.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        if parent.deletingLastPathComponent() == temp, parent.lastPathComponent.hasPrefix("xside-export-") {
            try? fm.removeItem(at: parent)
        }
    }
}

/// « Données »: the app's two backup switches, the actions and the versions of this installation.
struct AppDataTab: View {
    let model: AppModel
    let entry: AppEntry
    let appName: String
    let deviceName: String
    @State private var snaps: [BackupSnapshot] = []
    private enum Action { case backup, export, importData, restore }
    @State private var busy = false
    @State private var action: Action = .backup

    private var options: InstallOptions {
        model.records.first { $0.id == entry.record.id }?.options ?? entry.record.options
    }
    private var backupOn: Bool { options.backupData != false }
    /// The action buttons are off while busy; the Cancel button, beside them, stays live.
    private var actionsOff: Bool { working || !model.canManage(entry) }
    /// Back up and import reach the device now, so they also need it present (like « Rafraîchir »);
    /// export only reads a snapshot from disk, so it stays on `actionsOff`.
    private var actionsOffDevice: Bool { working || !model.canActOnDevice(entry) }
    private var working: Bool { busy || model.dataBusy.contains(entry.id) }
    private var workingText: String {
        switch action {
        case .backup: L("fiche.data.working")
        case .export: L("fiche.data.working.export")
        case .importData: L("fiche.data.working.import")
        case .restore: L("fiche.data.working.restore")
        }
    }
    private var reloadID: String { "\(entry.id)/\(model.jobs[entry.id] == nil)/\(model.dataBusy.contains(entry.id))/\(options.backupData.map(String.init(describing:)) ?? "")/\(options.backupBeforeUpdate.map(String.init(describing:)) ?? "")" }

    /// A boxed row: title + explanation on the left, switch on the right (like the Correctifs tab).
    @ViewBuilder private func toggleBox(_ title: String, _ note: String, isOn: Binding<Bool>, enabled: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.xside).controlSize(.small).disabled(!enabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(enabled ? 1 : 0.6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(L("fiche.data.section"))
            toggleBox(L("fiche.data.backup"), L("fiche.data.backup.note"),
                      isOn: Binding(get: { backupOn }, set: { v in Task { await model.setBackupData(v, for: entry) } }))
            toggleBox(L("fiche.data.caches"), L("fiche.data.caches.note"),
                      isOn: Binding(get: { options.backupCaches != false }, set: { v in Task { await model.setBackupCaches(v, for: entry) } }),
                      enabled: backupOn)
            toggleBox(L("settings.appData.beforeUpdate"), L("fiche.data.beforeUpdate.note"),
                      isOn: Binding(get: { options.backupBeforeUpdate ?? AppModel.setting(AppModel.backupBeforeUpdateDefaultKey) },
                                    set: { v in Task { await model.setBackupBeforeUpdate(v, for: entry) } }),
                      enabled: backupOn)
            HStack(spacing: 8) {
                Button(L("fiche.data.backUpNow")) {
                    action = .backup
                    if AppDataActions.startBackUp(entry, model: model, then: { await reload(); busy = false }) { busy = true }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(actionsOffDevice)
                Button(L("fiche.data.export")) { run(.export) { await AppDataActions.exportLatest(entry, model: model) } }
                    .disabled(snaps.isEmpty || actionsOff)
                    .help(L("fiche.data.export.help"))
                Button(L("fiche.data.import")) {
                    run(.importData) { await AppDataActions.importData(entry, appName: appName, deviceName: deviceName, model: model) }
                }
                .disabled(actionsOffDevice)
                if working {
                    // A backup of known size shows a real bar; otherwise the spinner.
                    if action == .backup, let fraction = model.backupFraction[entry.id] {
                        ProgressView(value: fraction, total: 1)
                            .progressViewStyle(.linear)
                            .tint(Theme.violet)
                            .controlSize(.small)
                            .frame(width: 110)
                            .animation(.smooth(duration: 0.4), value: fraction)
                        Text("\(workingText) \(percentText(Int((fraction * 100).rounded(.down))))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        cancelButton
                    } else {
                        ProgressView().controlSize(.small)
                        Text(workingText).font(.caption).foregroundStyle(.secondary)
                        if action == .backup { cancelButton }
                    }
                }
                Spacer(minLength: 0)
            }
            .help(model.manageBlockedReason(entry) ?? "")
            Text(L("fiche.data.onlineNote")).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            sectionTitle(snaps.isEmpty ? L("fiche.data.section.versions")
                         : L("fiche.data.versions", snaps.count, Self.size(snaps.reduce(0) { $0 + $1.byteSize })))
                .padding(.top, 6)
            if snaps.isEmpty {
                Text(backupOn ? L("fiche.data.empty") : L("fiche.data.emptyOff"))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            ForEach(Array(BackupSession.group(snaps).enumerated()), id: \.offset) { _, session in
                HStack(spacing: 6) {
                    Text(session.cycleStartedAt.map { L("fiche.data.cycle", $0.formatted(date: .abbreviated, time: .shortened)) }
                         ?? L("fiche.data.cycle.none"))
                        .font(.system(size: 12, weight: .semibold))
                    if session.isCurrent { tag(L("fiche.data.cycle.current")) }
                }
                .padding(.top, 4)
                ForEach(session.snapshots, id: \.id) { snap in
                    Divider()
                    versionRow(snap, latest: snap.id == snaps.first?.id)
                }
            }
        }
        .toggleStyle(.xside)
        .task(id: reloadID) { await reload() }
    }

    private func versionRow(_ snap: BackupSnapshot, latest: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snap.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if latest { tag(L("settings.appData.latest")) }
                }
                Text(detail(snap)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(L("settings.appData.restore")) { restore(snap) }
                .disabled(!model.canActOnDevice(entry)) // pushes to the device: needs it present
            Button(L("settings.appData.export")) { run(.export) { await AppDataActions.export(snap, model: model) } }
            Button(L("fiche.data.delete"), role: .destructive) { deleteSnap(snap) }
        }
        .disabled(working)
    }

    private func deleteSnap(_ snap: BackupSnapshot) {
        let a = NSAlert()
        a.messageText = L("fiche.data.delete.title")
        a.informativeText = L("fiche.data.delete.note", snap.createdAt.formatted(date: .abbreviated, time: .shortened))
        a.addButton(withTitle: L("fiche.data.delete"))
        a.addButton(withTitle: L("install.cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Task {
            if await model.deleteBackup(snap.id) { model.showToast(L("toast.deleted")) }
            await reload()
        }
    }

    private func detail(_ snap: BackupSnapshot) -> String {
        var parts = [Self.size(snap.byteSize)]
        if let v = snap.versionLabel { parts.append("\(appName) \(v)") }
        if snap.includedCaches { parts.append(L("fiche.data.withCaches")) }
        return parts.joined(separator: " · ")
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(Capsule().fill(.tint.opacity(0.15))).foregroundStyle(.tint)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
    }

    private func restore(_ snap: BackupSnapshot) {
        let a = NSAlert()
        a.messageText = L("settings.appData.restore.title", appName)
        let when = snap.createdAt.formatted(date: .abbreviated, time: .shortened)
        a.informativeText = snap.versionLabel.map { L("settings.appData.restore.noteVersion", when, $0) }
            ?? L("settings.appData.restore.note", when)
        if BackupSnapshot.restoreVersionWarning(snapshot: snap.appVersion, installed: entry.record.version),
           let from = snap.versionLabel, let to = BackupSnapshot.versionLabel(entry.record.version) {
            a.informativeText += "\n\n" + L("settings.appData.restore.versionWarning", from, to)
        }
        a.addButton(withTitle: L("settings.appData.restore"))
        a.addButton(withTitle: L("install.cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run(.restore) {
            let ok = await model.restore(snap, entry)
            if ok { model.showToast(L("toast.restored")) } else { AppDataActions.alert(L("settings.appData.restore.failed")) }
            return ok
        }
    }

    /// Stops the running backup: the task's cancellation ends devicectl and the pull loop, and the
    /// backup throws before the archive step, so no snapshot is made and the temp folder goes.
    private var cancelButton: some View {
        Button(L("fiche.data.backUpNow.cancel")) { model.cancelBackup(entry) }
            .controlSize(.small)
    }

    private func run(_ kind: Action, _ work: @escaping () async -> Bool) {
        action = kind
        busy = true
        Task {
            _ = await work()
            await reload()
            busy = false
        }
    }

    private func reload() async {
        snaps = await model.backups(forRecord: entry.record.id).filter { $0.deviceID == entry.installation.deviceID }
    }

    private static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}
