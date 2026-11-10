import SwiftUI
import XSideCore

/// « Désinstaller Cephei 1.17.1 ? » (Settings > Tweaks, device round 3, R3-3): where to remove a
/// kept download from, grouped by device. One checkbox per device (« tout l'appareil », mixed
/// while only some of its apps are checked), under it one per app on that device with the tweaks
/// that use it there. Everything checked at first. When something stays, a note says where it
/// stays and that the file stays on the Mac. The button says where it removes it from.
struct UninstallDependencySheet: View {
    let usage: DownloadUsage
    /// A device's full name, and whether it is an iPad (its icon).
    let device: (String) -> (name: String, isPad: Bool)
    let confirm: (Set<DownloadInstallation.Key>) -> Void
    let cancel: () -> Void
    @State private var checked: Set<DownloadInstallation.Key>

    /// `checked`: what starts checked (nil: everything; the snapshot harness shows other choices).
    init(usage: DownloadUsage, device: @escaping (String) -> (name: String, isPad: Bool),
         checked: Set<DownloadInstallation.Key>? = nil,
         confirm: @escaping (Set<DownloadInstallation.Key>) -> Void, cancel: @escaping () -> Void) {
        self.usage = usage
        self.device = device
        self.confirm = confirm
        self.cancel = cancel
        _checked = State(initialValue: checked ?? Set(usage.installations.map(\.key)))
    }

    /// The installations by device, in the usage's order (by device, then app).
    private var groups: [(deviceID: String, apps: [DownloadInstallation])] {
        var out: [(deviceID: String, apps: [DownloadInstallation])] = []
        for i in usage.installations {
            if let k = out.firstIndex(where: { $0.deviceID == i.deviceID }) { out[k].apps.append(i) } else { out.append((i.deviceID, [i])) }
        }
        return out
    }

    private var name: String { DependencyNames.display(usage.packageID) }
    private func short(_ id: String) -> String { deviceWithArticle(DeviceShortName.short(device(id).name)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("uninstall.title", name, usage.version))
                    .font(.system(size: 15, weight: .semibold))
                Text(L("uninstall.caption"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups, id: \.deviceID) { group in deviceCard(group) }
                }
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            if let note {
                Label {
                    Text(note).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle.fill")
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.violet.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack {
                Spacer()
                Button(L("install.cancel"), action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(buttonTitle) { confirm(checked) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500, alignment: .leading)
    }

    private func binding(_ key: DownloadInstallation.Key) -> Binding<Bool> {
        Binding(get: { checked.contains(key) }, set: { on in
            if on { checked.insert(key) } else { checked.remove(key) }
        })
    }

    private func deviceCard(_ group: (deviceID: String, apps: [DownloadInstallation])) -> some View {
        let info = device(group.deviceID)
        return VStack(alignment: .leading, spacing: 6) {
            // Mixed while only some of its apps are checked.
            Toggle(sources: group.apps.map { binding($0.key) }, isOn: \.self) {
                HStack(spacing: 6) {
                    Image(systemName: info.isPad ? "ipad" : "iphone")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.violet)
                    Text(info.name).font(.system(size: 13, weight: .semibold))
                    Text(L("uninstall.wholeDevice")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel(L("uninstall.wholeDevice") + " — " + info.name)
            ForEach(group.apps, id: \.key) { app in
                Toggle(isOn: binding(app.key)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.app).font(.system(size: 12.5, weight: .medium))
                        Text(app.tweaks.isEmpty ? L("uninstall.noTweak") : app.tweaks.joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.leading, 22)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var devicesChecked: [String] { groups.filter { g in g.apps.contains { checked.contains($0.key) } }.map(\.deviceID) }
    private var everything: Bool { checked.count == usage.installations.count }

    private var buttonTitle: String {
        if everything { return L("uninstall.button.all") }
        let devices = devicesChecked
        if devices.count == 1 { return L("uninstall.button.one", short(devices[0])) }
        return L("uninstall.button.many", max(devices.count, 1))
    }

    /// What stays, when not everything is checked: « Retirée de l'iPad seulement : l'iPhone Duo la
    /// garde dans ses 2 apps, donc XSide garde le fichier sur le Mac. … »
    private var note: String? {
        guard !everything, !checked.isEmpty else { return nil }
        var removed: [String] = [], kept: [String] = []
        for g in groups {
            let on = g.apps.filter { checked.contains($0.key) }, off = g.apps.filter { !checked.contains($0.key) }
            if on.count == g.apps.count {
                removed.append(short(g.deviceID))
            } else if !on.isEmpty {
                removed.append(L("uninstall.appsOn", on.map(\.app).joined(separator: ", "), short(g.deviceID)))
            }
            if off.count == g.apps.count, off.count > 1 {
                kept.append(L("uninstall.keeps.apps", short(g.deviceID), off.count))
            } else if !off.isEmpty {
                kept.append(L("uninstall.keeps.app", short(g.deviceID), off.map(\.app).joined(separator: ", ")))
            }
        }
        return L("uninstall.note", L("uninstall.note.removed", removed.joined(separator: ", "), kept.joined(separator: ", ")))
    }
}
