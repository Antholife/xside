import SwiftUI
import XSideCore

/// The conditional last step "Données": the app has backups (on any of the account's devices); restore
/// one after the install, restore another version, keep a clean install, or delete them.
struct DataRestoreStep: View {
    @Bindable var flow: InstallFlow
    @State private var listOpen = false

    private var latest: BackupSnapshot? { flow.dataSnapshots.first }
    private var restoringID: String? {
        if case .restore(let id) = flow.dataChoice { id } else { nil }
    }
    private var restoringLatest: Bool { restoringID != nil && restoringID == latest?.id }
    private var restoringOther: Bool { restoringID != nil && restoringID != latest?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("install.data.title", flow.appDisplayName)).font(.system(size: 15, weight: .semibold))
            Text(L("install.data.lead"))
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            if let latest {
                option(selected: restoringLatest, title: L("install.data.restore"), tag: L("install.data.recommended"),
                       note: describe(latest) + " · " + L("install.data.mostRecent")) {
                    flow.dataChoice = .restore(latest.id)
                    listOpen = false
                }
            }
            if flow.dataSnapshots.count > 1 {
                option(selected: restoringOther, title: L("install.data.other"), tag: nil,
                       note: listOpen || restoringOther ? nil : L("install.data.other.note", flow.dataSnapshots.count - 1)) {
                    listOpen = true
                    if !restoringOther, flow.dataSnapshots.count > 1 { flow.dataChoice = .restore(flow.dataSnapshots[1].id) }
                }
                if listOpen || restoringOther { versions }
            }
            if flow.targetHasApp {
                InlineWarning(L("install.data.overwrite"))
            }
            if let warning = versionWarning {
                InlineWarning(warning)
            }
            HStack(alignment: .top, spacing: 8) {
                option(selected: flow.dataChoice == .none, title: L("install.data.none"), tag: nil,
                       note: L("install.data.none.note"), fillHeight: true) {
                    flow.dataChoice = .none
                    listOpen = false
                }
                option(selected: flow.dataChoice == .delete, title: L("install.data.delete"), tag: nil,
                       note: L("install.data.delete.note"), fillHeight: true) {
                    flow.dataChoice = .delete
                    listOpen = false
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Text(L("install.data.note"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    /// Every other backup, newest first: origin device, date and size.
    private var versions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(flow.dataSnapshots, id: \.id) { snap in
                Button { flow.dataChoice = .restore(snap.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: restoringID == snap.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(restoringID == snap.id ? Theme.violet : .secondary)
                        Text(describe(snap)).font(.system(size: 12))
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(restoringID == snap.id ? .isSelected : [])
            }
        }
        .padding(.vertical, 3)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.leading, 20)
    }

    /// Non-blocking note when the backup comes from another app version than the one installed. Shown
    /// for the backup being restored, or — so it's always visible, not only once « Restaurer » is
    /// picked — for the most recent one that would be restored by default.
    private var versionWarning: String? {
        guard let id = restoringID ?? latest?.id, let snap = flow.dataSnapshots.first(where: { $0.id == id }),
              BackupSnapshot.restoreVersionWarning(snapshot: snap.appVersion, installed: flow.info?.version),
              let from = snap.versionLabel, let to = BackupSnapshot.versionLabel(flow.info?.version) else { return nil }
        return L("install.data.versionWarning", from, to)
    }

    private func describe(_ snap: BackupSnapshot) -> String {
        ([snap.deviceName,
          snap.createdAt.formatted(date: .abbreviated, time: .shortened),
          ByteCountFormatter.string(fromByteCount: Int64(snap.byteSize), countStyle: .file)]
         + [snap.versionLabel].compactMap { $0 })
            .joined(separator: " · ")
    }

    private func option(selected: Bool, title: String, tag: String?, note: String?,
                        fillHeight: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Theme.violet : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        if let tag {
                            Text(tag)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(nsColor: .systemGreen))
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .background(Color(nsColor: .systemGreen).opacity(0.14), in: Capsule())
                        }
                    }
                    if let note {
                        Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(selected ? Theme.violet.opacity(0.08) : Theme.cardFill,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? Theme.violet : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
