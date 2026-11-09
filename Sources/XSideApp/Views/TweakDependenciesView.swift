import AppKit
import SwiftUI
import XSideCore

/// One `Depends` group of a tweak, as the « Dépendances » sheet shows it.
struct DependencyLine: Identifiable {
    let id: Int
    let dependency: DebDependency
    let status: DependencyStatus
    /// « Ajoutée par toi »: the version of the package that satisfies it.
    var addedVersion: String?

    var isMissing: Bool { if case .missing = status { true } else { false } }

    /// The library's usual name (« Cephei ») when XSide knows it, else its package id.
    static func displayName(_ packageID: String) -> String {
        switch KnownDependency.role(of: packageID) {
        case .library(let n)?, .jailbreakOnly(let n)?, .builtIntoTweak(let n)?: n
        default: packageID
        }
    }
}

/// « Dépendances de … » (« Dépendances manquantes » while one is missing): one row per `Depends`
/// group with its status. A missing one offers « Où la trouver » (a page XSide knows) or two
/// searches, « Ajouter son .deb… » (drop zone and open panel) and, for a package a trusted repo
/// offers, « Télécharger ». The links only open the browser.
struct TweakDependenciesView: View {
    let tweakName: String
    let lines: [DependencyLine]
    var errors: [String: String] = [:]
    var beingAdded: Set<String> = []
    var isDisabled = false
    let open: (URL) -> Void
    let addDeb: (DebDependency, [URL]) -> Void
    let download: (DebDependency) -> Void
    let done: () -> Void

    private var anyMissing: Bool { lines.contains(where: \.isMissing) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(anyMissing ? L("deps.missingTitle") : L("deps.title", tweakName))
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(anyMissing ? L("deps.title", tweakName) : L("deps.caption"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if lines.isEmpty {
                Text(L("deps.none")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        if line.id != lines.first?.id { Divider().padding(.leading, 48) }
                        DependencyRowView(line: line, error: errors[line.dependency.package],
                                          isAdding: beingAdded.contains(line.dependency.package), isDisabled: isDisabled,
                                          open: open, addDeb: { addDeb(line.dependency, $0) },
                                          download: { download(line.dependency) })
                    }
                }
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            HStack {
                Spacer()
                Button(L("install.done"), action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct DependencyRowView: View {
    let line: DependencyLine
    let error: String?
    let isAdding: Bool
    let isDisabled: Bool
    let open: (URL) -> Void
    let addDeb: ([URL]) -> Void
    let download: () -> Void
    @State private var isTargeted = false

    private var packageID: String { line.dependency.package }

    private var title: String {
        if case .providedByXSide(let name) = line.status { return name }
        return DependencyLine.displayName(packageID)
    }

    /// The package id (when the title is a name) and the version it asks for (a missing one says
    /// it on its status line).
    private var detail: String? {
        var parts: [String] = []
        if title != packageID { parts.append(packageID) }
        if !line.isMissing, let c = DependencyDirectory.constraint(line.dependency) { parts.append(c) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var statusText: String {
        switch line.status {
        case .providedByXSide: L("deps.status.xside")
        case .addedByYou(let name): L("deps.status.yours") + " — " + name + (line.addedVersion.map { " " + $0 } ?? "")
        case .missing(let dep): L("deps.status.missing") + (DependencyDirectory.constraint(dep).map { " (\($0))" } ?? "")
        case .jailbreakOnly: L("deps.status.jailbreak")
        case .builtIntoTweak: L("deps.status.builtIn")
        case .notNeeded: L("deps.status.notNeeded")
        }
    }

    private var tint: Color {
        switch line.status {
        case .providedByXSide, .addedByYou, .builtIntoTweak: Color(nsColor: .systemGreen)
        case .missing: Color(nsColor: .systemOrange)
        case .jailbreakOnly: Color(nsColor: .systemRed)
        case .notNeeded: Color.secondary
        }
    }

    private var symbol: String {
        switch line.status {
        case .providedByXSide, .builtIntoTweak: "checkmark.seal.fill"
        case .addedByYou: "person.crop.circle.badge.checkmark"
        case .missing: "questionmark.circle.fill"
        case .jailbreakOnly: "xmark.octagon.fill"
        case .notNeeded: "minus.circle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(line.isMissing ? AnyShapeStyle(Color(nsColor: .systemOrange)) : AnyShapeStyle(Theme.brand),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Label {
                    Text(statusText).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                if line.isMissing { actions }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isTargeted ? Theme.violet.opacity(0.10) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard line.isMissing, !isDisabled, !isAdding, !files.isEmpty else { return false }
            addDeb(files)
            return true
        } isTargeted: { isTargeted = $0 && line.isMissing && !isDisabled }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var actions: some View {
        let page = DependencyDirectory.page(for: packageID)
        let searches = DependencyDirectory.searchURLs(for: packageID)
        if page == nil, !searches.isEmpty {
            Text(L("deps.unknown"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            if let page {
                Button(L("deps.where")) { open(page) }.help(page.absoluteString)
            } else if !searches.isEmpty {
                Button(L("deps.search")) { open(searches[0]) }.help(searches[0].absoluteString)
                if searches.count > 1 {
                    Button(L("deps.otherSearch")) { open(searches[1]) }.help(searches[1].absoluteString)
                }
            }
            Button(L("deps.addDeb")) { if let urls = Self.chooseDeb() { addDeb(urls) } }
                .help(L("deps.drop"))
            if !TrustedRepos.offering(packageID).isEmpty {
                Button(L("deps.download"), action: download)
                    .help(TrustedRepos.offering(packageID).map { $0.base.absoluteString }.joined(separator: ", "))
            }
            if isAdding {
                ProgressView().controlSize(.mini)
                Text(L("deps.checking")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .disabled(isDisabled || isAdding)
    }

    @MainActor static func chooseDeb() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("deps.addDeb").replacingOccurrences(of: "…", with: "")
        return panel.runModal() == .OK && !panel.urls.isEmpty ? panel.urls : nil
    }
}

/// The sheet for `target`, from the model.
struct TweakDependenciesSheet: View {
    let model: AppModel
    let target: DependencyTarget
    var isDisabled = false

    var body: some View {
        if let (package, lines) = model.dependencyLines(target) {
            TweakDependenciesView(tweakName: package.name, lines: lines, errors: model.dependencyErrors,
                                  beingAdded: model.dependenciesBeingAdded, isDisabled: isDisabled,
                                  open: { NSWorkspace.shared.open($0) },
                                  addDeb: { dep, urls in Task { await model.addDependencyDeb(urls, for: dep, target: target) } },
                                  download: { dep in Task { await model.downloadDependency(dep, for: package, target: target) } },
                                  done: { model.closeDependencies() })
        } else {
            // The tweak went away meanwhile.
            TweakDependenciesView(tweakName: "", lines: [], open: { _ in }, addDeb: { _, _ in }, download: { _ in },
                                  done: { model.closeDependencies() })
        }
    }
}

extension View {
    /// Shows the « Dépendances » sheet when the model's target is one `matches` accepts.
    func dependenciesSheet(_ model: AppModel, isDisabled: Bool = false,
                           matches: @escaping (DependencyTarget) -> Bool) -> some View {
        sheet(item: Binding(get: { model.dependencySheet.flatMap { matches($0.target) ? $0 : nil } },
                            set: { if $0 == nil { model.closeDependencies() } })) { sheet in
            TweakDependenciesSheet(model: model, target: sheet.target, isDisabled: isDisabled)
        }
    }
}
