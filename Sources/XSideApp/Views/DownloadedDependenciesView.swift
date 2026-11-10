import SwiftUI
import XSideCore

/// Settings > Tweaks (device round 2, item 8: its own page, for every app, no longer reached
/// from one app): every `.deb` XSide kept from a trusted repo, its size and who uses it (« 3 tweaks
/// dans 2 apps », unfolded per app, tweak and device), and « Désinstaller… » for one an app uses
/// (device round 3, R3-3: chosen device by device, app by app). Those no installation uses any
/// more go by themselves (an app, an installation or a tweak removed), so there is no « Supprimer »
/// or « Tout nettoyer » any more.
struct TweaksSettingsPage: View {
    let model: AppModel
    @State private var uninstalling: DownloadUsage?

    var body: some View {
        ScrollView(.vertical) {
            DownloadedDependenciesTable(usage: model.downloadUsage, deviceName: { DeviceShortName.short(model.deviceName($0)) },
                                        uninstall: { uninstalling = $0 }, done: nil)
                .reportsPaneHeight()
        }
        .scrollBounceBehavior(.basedOnSize)
        .task {
            #if DEBUG
            if SnapshotRenderer.folder != nil { return } // the harness's sample stays
            #endif
            await model.loadDownloadUsage()
        }
        .sheet(item: $uninstalling) { usage in
            UninstallDependencySheet(usage: usage, device: { id in
                let name = model.deviceName(id)
                return (name, model.devices.first { $0.id == id }?.kind == .iPad || name.lowercased().contains("ipad"))
            }, confirm: { keys in
                uninstalling = nil
                Task { await model.uninstallDownload(usage, from: keys) }
            }, cancel: { uninstalling = nil })
        }
    }
}

struct DownloadedDependenciesTable: View {
    let usage: [DownloadUsage]?
    let deviceName: (String) -> String
    /// « Désinstaller… » on a used one: the sheet.
    let uninstall: (DownloadUsage) -> Void
    /// A sheet's « OK »; nil on the Settings page.
    let done: (() -> Void)?

    private static func size(_ bytes: Int64) -> String { fileSize(bytes) }
    @State private var unfolded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("downloads.title")).font(.system(size: 15, weight: .semibold))
                Text(L("downloads.caption"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let usage {
                if usage.isEmpty {
                    Text(L("downloads.none")).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    table(usage)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let done {
                HStack {
                    Spacer()
                    Button(L("install.done"), action: done)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: done == nil ? .infinity : 620, alignment: .leading)
        .frame(width: done == nil ? nil : 620)
    }

    /// Column widths: package, version, repo, size; « Utilisée par » takes the rest, then the button.
    private static let widths: [CGFloat] = [130, 58, 64, 58]
    private static let buttonWidth: CGFloat = 104

    private func cells(_ texts: [AnyView], usedBy: AnyView, button: AnyView) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ForEach(Array(texts.enumerated()), id: \.offset) { i, t in
                t.frame(width: Self.widths[i], alignment: .leading)
            }
            usedBy.frame(maxWidth: .infinity, alignment: .leading)
            button.frame(width: Self.buttonWidth, alignment: .trailing)
        }
    }

    private func table(_ usage: [DownloadUsage]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cells(["downloads.package", "downloads.version", "downloads.repo", "downloads.size"].map {
                AnyView(Text(L($0)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary))
            }, usedBy: AnyView(Text(L("downloads.usedBy")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)),
                  button: AnyView(EmptyView()))
            ForEach(usage) { u in
                Divider()
                cells([
                    AnyView(Text(DependencyNames.display(u.packageID)).font(.system(size: 12, weight: .medium))
                        .lineLimit(2).help(u.packageID)),
                    AnyView(Text(u.version).font(.system(size: 12)).lineLimit(1)),
                    AnyView(Text(u.repoName).font(.system(size: 12)).lineLimit(1)),
                    AnyView(Text(Self.size(u.size)).font(.system(size: 12)).monospacedDigit().lineLimit(1)),
                ], usedBy: AnyView(usedBy(u)), button: AnyView(Group {
                    // Listed by no installation (only what an app was last signed with): it goes
                    // by itself at that app's next signing.
                    if !u.installations.isEmpty {
                        Button(L("downloads.uninstall")) { uninstall(u) }
                    }
                }.controlSize(.small)))
            }
        }
    }

    private func tweakText(_ t: DownloadUser.Tweak) -> String {
        t.deviceIDs.isEmpty ? t.name : t.name + " (" + t.deviceIDs.map(deviceName).joined(separator: ", ") + ")"
    }

    private func userText(_ user: DownloadUser) -> String {
        user.tweaks.isEmpty ? user.app : user.app + " — " + user.tweaks.map(tweakText).joined(separator: ", ")
    }

    @ViewBuilder private func usedBy(_ u: DownloadUsage) -> some View {
        if !u.isUsed {
            Text("—").font(.system(size: 12)).foregroundStyle(.secondary)
        } else if u.users.count <= 1, u.tweakCount <= 1 {
            Text(u.users.first.map(userText) ?? u.apps.joined(separator: ", "))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    if unfolded.contains(u.sha256) { unfolded.remove(u.sha256) } else { unfolded.insert(u.sha256) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(unfolded.contains(u.sha256) ? 90 : 0))
                        Text(L("downloads.usedByCount", u.tweakCount, u.users.count)).font(.system(size: 12))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if unfolded.contains(u.sha256) {
                    ForEach(u.users, id: \.app) { user in
                        Text(userText(user)).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
