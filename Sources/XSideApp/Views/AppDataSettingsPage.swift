import AppKit
import SwiftUI
import XSideCore

/// Settings > Données des apps: the defaults for new installations, the disk the backups use, the
/// backups of installed apps (one row per version) and those of apps no longer installed.
/// The per-app switches and "Sauvegarder maintenant" live in the app's own page (Mes apps).
struct AppDataSettingsPage: View {
    let model: AppModel
    @AppStorage(AppModel.backupDefaultKey) private var backupNew = true
    @AppStorage(AppModel.backupCachesDefaultKey) private var backupCaches = true
    @AppStorage(AppModel.backupRetentionKey) private var retention = 3

    @State private var diskBytes = 0
    @State private var perRecord: [UUID: [BackupSnapshot]] = [:]
    @State private var orphans: [BackupSnapshot] = []
    @State private var expanded: Set<UUID> = []
    @State private var busy = false

    /// Installed apps, one per record, in the panel's order.
    private var records: [AppRecord] {
        var seen = Set<UUID>()
        return model.deviceGroups.flatMap(\.apps).compactMap { seen.insert($0.record.id).inserted ? $0.record : nil }
    }

    /// Changes when the installed apps do, so the list fills in when they load after the pane opens.
    private var reloadID: [String] {
        model.deviceGroups.flatMap(\.apps).map { "\($0.record.id)/\($0.installation.deviceID)" }
    }

    private var listed: [(record: AppRecord, snaps: [BackupSnapshot])] {
        records.compactMap { r in perRecord[r.id].flatMap { $0.isEmpty ? nil : (r, $0) } }
    }

    var body: some View {
        Form {
            Section {
                Text(L("settings.appData.lead")).font(.callout).foregroundStyle(.secondary)
            }
            Section(L("settings.appData.defaults")) {
                Toggle(isOn: $backupNew) { labeled(L("settings.appData.backupNew"), L("settings.appData.backupNew.note")) }
                Toggle(isOn: $backupCaches) { labeled(L("settings.appData.caches"), L("settings.appData.caches.note")) }
                Picker(selection: $retention) {
                    ForEach([1, 2, 3, 5, 10, 20], id: \.self) { n in
                        Text(L(n == 1 ? "settings.appData.retention.one" : "settings.appData.retention.many", n)).tag(n)
                    }
                } label: {
                    Text(L("settings.appData.retention"))
                    Text(L("settings.appData.retention.note"))
                }
            }
            Section(L("settings.appData.disk")) {
                LabeledContent {
                    Button(L("settings.appData.reveal")) {
                        let dir = model.libraryRoot.appendingPathComponent(AppDataBackup.folderName, isDirectory: true)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                } label: {
                    Label {
                        Text(L("settings.appData.diskUsed", Self.size(diskBytes)))
                    } icon: { Image(systemName: "internaldrive.fill").foregroundStyle(.secondary) }
                }
            }
            Section(L("settings.appData.backups", listed.count)) {
                if listed.isEmpty {
                    Text(L("settings.appData.empty")).foregroundStyle(.secondary)
                }
                ForEach(listed, id: \.record.id) { item in appGroup(item.record, item.snaps) }
            }
            if !orphans.isEmpty {
                Section {
                    ForEach(orphans, id: \.id) { snap in orphanRow(snap) }
                } header: {
                    Text(L("settings.appData.orphans", orphans.count))
                } footer: {
                    Text(L("settings.appData.orphans.note"))
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.xside)
        .modifier(ReportsFormHeight())
        .disabled(busy)
        .task(id: reloadID) { await reload() }
    }

    // MARK: Rows

    private func labeled(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func appGroup(_ record: AppRecord, _ snaps: [BackupSnapshot]) -> some View {
        let open = expanded.contains(record.id)
        Button {
            if open { expanded.remove(record.id) } else { expanded.insert(record.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                AppIconView(icon: model.icons.image(for: record), size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.options.displayName ?? record.displayName).font(.system(size: 13, weight: .medium))
                    Text(summary(snaps)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open {
            ForEach(Array(BackupSession.group(snaps).enumerated()), id: \.offset) { _, session in
                HStack(spacing: 6) {
                    Text(session.installedAt.map { L("fiche.data.cycle", $0.formatted(date: .abbreviated, time: .shortened)) }
                         ?? L("fiche.data.cycle.none"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if session.isCurrent { Text(L("fiche.data.cycle.current")).font(.caption).foregroundStyle(.tint) }
                }
                .padding(.leading, 28)
                ForEach(session.snapshots, id: \.id) { snap in
                let index = snap.id == snaps.first?.id ? 0 : 1
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(Self.date(snap.createdAt))
                            if index == 0 {
                                Text(L("settings.appData.latest")).font(.caption.weight(.semibold))
                                    .padding(.horizontal, 7).padding(.vertical, 1)
                                    .background(Capsule().fill(.tint.opacity(0.15))).foregroundStyle(.tint)
                            }
                        }
                        Text(detail(snap)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("settings.appData.restore")) { restore(snap, in: record) }
                    Button(L("settings.appData.export")) { export(snap) }
                    Button(L("settings.appData.delete"), role: .destructive) { delete(snap) }
                }
                .padding(.leading, 28)
                }
            }
        }
    }

    private func orphanRow(_ snap: BackupSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.app.dashed").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(snap.signedBundleID).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(L("settings.appData.uninstalled")).font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary)).foregroundStyle(.secondary)
                }
                Text("\(snap.deviceName) · \(Self.size(snap.byteSize)) · " + L("settings.appData.savedOn", Self.date(snap.createdAt)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("settings.appData.export")) { export(snap) }
            Button(L("settings.appData.delete"), role: .destructive) { delete(snap) }
        }
    }

    private func summary(_ snaps: [BackupSnapshot]) -> String {
        let device = Set(snaps.map(\.deviceName)).sorted().joined(separator: ", ")
        return "\(device) · " + (snaps.count == 1 ? L("settings.appData.versions.one") : L("settings.appData.versions", snaps.count)) + " · " + Self.size(snaps.reduce(0) { $0 + $1.byteSize })
    }

    private func detail(_ snap: BackupSnapshot) -> String {
        [Self.size(snap.byteSize), snap.appVersion.map { "v\($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Actions

    private func reload() async {
        diskBytes = await model.backupDiskBytes()
        var map: [UUID: [BackupSnapshot]] = [:]
        for r in records { map[r.id] = await model.backups(forRecord: r.id) }
        perRecord = map
        orphans = await model.orphanBackups()
    }

    private func restore(_ snap: BackupSnapshot, in record: AppRecord) {
        guard let entry = model.deviceGroups.flatMap(\.apps).first(where: {
            $0.record.id == record.id && $0.installation.deviceID == snap.deviceID
        }) else { return alert(L("settings.appData.restore.noDevice"), nil) }
        let name = record.options.displayName ?? record.displayName
        guard confirm(L("settings.appData.restore.title", name), L("settings.appData.restore.note", Self.date(snap.createdAt)),
                      L("settings.appData.restore")) else { return }
        run {
            let ok = await model.restore(snap.id, entry)
            if ok { model.showToast(L("toast.restored")) } else { alert(L("settings.appData.restore.failed"), nil) }
        }
    }

    private func export(_ snap: BackupSnapshot) {
        run {
            guard let zip = await model.exportBackup(snap.id) else { return alert(L("settings.appData.export.failed"), nil) }
            defer { Self.cleanUp(zip) }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = zip.lastPathComponent
            panel.allowedContentTypes = [.zip]
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) { _ = try FileManager.default.replaceItemAt(dest, withItemAt: zip, backupItemName: nil, options: []) }
                else { try FileManager.default.copyItem(at: zip, to: dest) }
            } catch { return alert(L("settings.appData.export.failed"), nil) }
            model.showToast(L("toast.exported"))
        }
    }

    private func delete(_ snap: BackupSnapshot) {
        guard confirm(L("settings.appData.delete.title"), L("settings.appData.delete.note", Self.date(snap.createdAt)),
                      L("settings.appData.delete")) else { return }
        run { if await model.deleteBackup(snap.id) { model.showToast(L("toast.deleted")) } }
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            await reload()
            busy = false
        }
    }

    private func confirm(_ title: String, _ text: String, _ action: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: action)
        a.addButton(withTitle: L("install.cancel"))
        return a.runModal() == .alertFirstButtonReturn
    }

    private func alert(_ title: String, _ text: String?) {
        let a = NSAlert()
        a.messageText = title
        if let text { a.informativeText = text }
        a.runModal()
    }

    /// Removes the temporary zip, and its folder only when that folder is a direct child of the
    /// temporary directory (the one `exportBackup` created); never any other directory.
    private static func cleanUp(_ zip: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: zip)
        let parent = zip.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let temp = fm.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        if parent.deletingLastPathComponent() == temp, parent.lastPathComponent.hasPrefix("xside-export-") {
            try? fm.removeItem(at: parent)
        }
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func date(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }
}
