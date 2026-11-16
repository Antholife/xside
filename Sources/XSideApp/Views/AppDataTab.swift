import AppKit
import SwiftUI
import XSideCore

/// The fiche's data actions, shared by the « Données » tab and the header's « ⋯ » menu.
@MainActor enum AppDataActions {
    static func backUpNow(_ entry: AppEntry, model: AppModel) async {
        if !(await model.backUpNow(entry)) { alert(L("fiche.data.backUpNow.failed")) }
    }

    /// Exports the newest snapshot of this installation through a save panel.
    static func exportLatest(_ entry: AppEntry, model: AppModel) async {
        let snaps = await model.backups(forRecord: entry.record.id).filter { $0.deviceID == entry.installation.deviceID }
        guard let latest = snaps.first else { return alert(L("fiche.data.empty")) }
        await export(latest, model: model)
    }

    static func export(_ snap: BackupSnapshot, model: AppModel) async {
        guard let zip = await model.exportBackup(snap.id) else { return alert(L("settings.appData.export.failed")) }
        defer { cleanUp(zip) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = zip.lastPathComponent
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: zip, backupItemName: nil, options: [])
            } else {
                try FileManager.default.copyItem(at: zip, to: dest)
            }
        } catch { alert(L("settings.appData.export.failed")) }
    }

    /// Picks a .zip, confirms the explicit target (this app, this device), then imports.
    static func importData(_ entry: AppEntry, appName: String, deviceName: String, model: AppModel) async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = L("fiche.data.import.choose")
        guard panel.runModal() == .OK, let zip = panel.url else { return }
        let a = NSAlert()
        a.messageText = L("fiche.data.import.title", appName)
        a.informativeText = L("fiche.data.import.note", appName, deviceName)
        a.addButton(withTitle: L("fiche.data.import"))
        a.addButton(withTitle: L("install.cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if !(await model.importBackup(zip: zip, intoRecordID: entry.record.id, deviceID: entry.installation.deviceID)) {
            alert(L("fiche.data.import.mismatch"))
        }
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
    @State private var busy = false

    private var options: InstallOptions {
        model.records.first { $0.id == entry.record.id }?.options ?? entry.record.options
    }
    private var backupOn: Bool { options.backupData != false }
    private var reloadID: String { "\(entry.id)/\(model.jobs[entry.id] == nil)/\(options.backupData.map(String.init(describing:)) ?? "")" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(L("fiche.data.section"))
            Toggle(isOn: Binding(get: { backupOn }, set: { v in Task { await model.setBackupData(v, for: entry) } })) {
                labeled(L("fiche.data.backup"), L("fiche.data.backup.note"))
            }
            Toggle(isOn: Binding(get: { options.backupCaches != false }, set: { v in Task { await model.setBackupCaches(v, for: entry) } })) {
                labeled(L("fiche.data.caches"), L("fiche.data.caches.note"))
            }
            .disabled(!backupOn)
            HStack(spacing: 8) {
                Button(L("fiche.data.backUpNow")) { run { await AppDataActions.backUpNow(entry, model: model) } }
                    .buttonStyle(.borderedProminent)
                Button(L("fiche.data.export")) { run { await AppDataActions.exportLatest(entry, model: model) } }
                    .disabled(snaps.isEmpty)
                Button(L("fiche.data.import")) {
                    run { await AppDataActions.importData(entry, appName: appName, deviceName: deviceName, model: model) }
                }
                Spacer(minLength: 0)
            }
            .disabled(busy || !model.canManage(entry))
            .help(model.manageBlockedReason(entry) ?? "")

            sectionTitle(snaps.isEmpty ? L("fiche.data.section.versions")
                         : L("fiche.data.versions", snaps.count, Self.size(snaps.reduce(0) { $0 + $1.byteSize })))
                .padding(.top, 6)
            if snaps.isEmpty {
                Text(backupOn ? L("fiche.data.empty") : L("fiche.data.emptyOff"))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            ForEach(Array(snaps.enumerated()), id: \.element.id) { index, snap in
                Divider()
                versionRow(snap, latest: index == 0)
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
            Button(L("settings.appData.export")) { run { await AppDataActions.export(snap, model: model) } }
        }
        .disabled(busy)
    }

    private func detail(_ snap: BackupSnapshot) -> String {
        var parts = [Self.size(snap.byteSize)]
        if let v = snap.appVersion { parts.append("\(appName) \(v)") }
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

    private func labeled(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func restore(_ snap: BackupSnapshot) {
        let a = NSAlert()
        a.messageText = L("settings.appData.restore.title", appName)
        a.informativeText = L("settings.appData.restore.note", snap.createdAt.formatted(date: .abbreviated, time: .shortened))
        a.addButton(withTitle: L("settings.appData.restore"))
        a.addButton(withTitle: L("install.cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run {
            if !(await model.restore(snap.id, entry)) { AppDataActions.alert(L("settings.appData.restore.failed")) }
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            await reload()
            busy = false
        }
    }

    private func reload() async {
        snaps = await model.backups(forRecord: entry.record.id).filter { $0.deviceID == entry.installation.deviceID }
    }

    private static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}
