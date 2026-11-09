import AppKit
import SwiftUI
import XSideCore

enum DependencyNames {
    /// The library's usual name (« Cephei ») when XSide knows it, else its package id.
    static func display(_ packageID: String) -> String {
        switch KnownDependency.role(of: packageID) {
        case .library(let n)?, .jailbreakOnly(let n)?, .builtIntoTweak(let n)?: n
        default: packageID
        }
    }
}

/// What a tweak card needs to show and settle its dependencies in place (no other window): the
/// rows (one status per device when they disagree), the lines of the last action on each (by
/// package id) and what the buttons do.
struct TweakDependencyState {
    var rows: [DependencyRow]
    var deviceNames: [String: String] = [:]
    var errors: [String: String] = [:]
    var notices: [String: String] = [:]
    var progress: [String: String] = [:]
    var beingAdded: Set<String> = []
    /// Package ids whose progress and result another card shows (by its tweak's name): this card
    /// says « voir … » instead.
    var elsewhere: [String: String] = [:]
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var addDeb: (DebDependency, [URL]) -> Void = { _, _ in }
    var download: (DebDependency) -> Void = { _ in }

    var missingCount: Int { rows.filter(\.isMissingAnywhere).count }
    /// Worth a block: anything but « Pas nécessaire ».
    var isWorthShowing: Bool {
        rows.contains { $0.statuses.contains { if case .notNeeded = $0.status { false } else { true } } }
    }
}

/// « Dépendances » inside an expanded card: one status line per `Depends` group (per device when
/// they disagree), and for a missing one « Télécharger » (a trusted repo has it), « Où la
/// trouver » or « Chercher », « Ajouter son .deb… », then « Téléchargement depuis … » and the
/// line that says how it went. The links only open the browser.
struct TweakDependencyBlock: View {
    let state: TweakDependencyState
    var isDisabled = false
    /// « Dépendances » above the rows (the « À régler » card has its own red line instead).
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle { Text(L("deps.section")).font(.system(size: 12, weight: .semibold)) }
            ForEach(state.rows) { row in
                DependencyRowLines(row: row, state: state, isDisabled: isDisabled)
            }
            if state.missingCount > 0 {
                Text(L("deps.missingNote"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DependencyRowLines: View {
    let row: DependencyRow
    let state: TweakDependencyState
    let isDisabled: Bool
    @State private var isTargeted = false

    private var missing: DebDependency? { row.missingDependency }
    private var packageID: String { (missing ?? row.dependency).package }
    private var isAdding: Bool { state.beingAdded.contains(packageID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(row.statuses.enumerated()), id: \.offset) { _, s in
                DependencyStatusLine(status: s, deviceName: s.deviceID.map { state.deviceNames[$0] ?? $0 })
            }
            if missing != nil, !isAdding { actions }
            if let other = state.elsewhere[packageID] {
                // Two tweaks need it: its lines are on the first one's card.
                if isAdding || state.notices[packageID] != nil || state.errors[packageID] != nil {
                    Label(L("deps.seeOther", other), systemImage: "arrow.up.forward")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                lines
            }
        }
        .padding(isTargeted ? 4 : 0)
        .background(isTargeted ? Theme.violet.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard let missing, !isDisabled, !isAdding, !files.isEmpty else { return false }
            state.addDeb(missing, files)
            return true
        } isTargeted: { isTargeted = $0 && missing != nil && !isDisabled }
    }

    /// The add's progress, then how it went.
    @ViewBuilder private var lines: some View {
        if isAdding {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(state.progress[packageID] ?? L("deps.checking"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let notice = state.notices[packageID] {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .systemGreen))
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = state.errors[packageID] {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var actions: some View {
        actionButtons
    }

    @ViewBuilder private var actionButtons: some View {
        let page = DependencyDirectory.page(for: packageID)
        let searches = DependencyDirectory.searchURLs(for: packageID)
        HStack(spacing: 8) {
            if let missing, DependencySources.canDownload(packageID) {
                Button(L("deps.download")) { state.download(missing) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.violet)
                    .help(DependencySources.places(for: packageID).joined(separator: ", "))
            }
            if let page {
                Button(L("deps.where")) { state.open(page) }.help(page.absoluteString)
            } else if !searches.isEmpty {
                Button(L("deps.search")) { state.open(searches[0]) }.help(searches[0].absoluteString)
            }
            Button(L("deps.addDeb")) {
                if let missing, let urls = Self.chooseDeb() { state.addDeb(missing, urls) }
            }
            .help(L("deps.drop"))
        }
        .controlSize(.small)
        .disabled(isDisabled)
        // XSide can't fetch it (device round 2, item 7): where else to look, and a web search.
        if !DependencySources.canDownload(packageID),
           let web = DependencyDirectory.webSearchURL(packageID: packageID, name: DependencyNames.display(packageID)) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L("deps.web.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(L("deps.web.search")) { state.open(web) }
                    .controlSize(.small)
                    .help(web.absoluteString)
                    .fixedSize()
            }
        }
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

/// One status, tinted: « ✓ Cephei — fournie par XSide », « ✕ AltList ≥ 1.0 — manquante »,
/// « … sur <appareil> » when the devices disagree.
struct DependencyStatusLine: View {
    let status: DependencyDeviceStatus
    let deviceName: String?

    private var name: String {
        switch status.status {
        case .providedByXSide(let n), .jailbreakOnly(let n), .builtIntoTweak(let n): n
        case .addedByYou(let n): n + (status.addedVersion.map { " " + $0 } ?? "")
        case .missing(let dep):
            DependencyNames.display(dep.package) + (DependencyDirectory.constraint(dep).map { " " + $0 } ?? "")
        case .notNeeded: DependencyNames.display(status.dependency.package)
        }
    }

    private var label: String {
        switch status.status {
        case .providedByXSide: L("deps.status.xside")
        case .addedByYou: L("deps.status.yours")
        case .missing: L("deps.status.missing")
        case .jailbreakOnly: L("deps.status.jailbreak")
        case .builtIntoTweak: L("deps.status.builtIn")
        case .notNeeded: L("deps.status.notNeeded")
        }
    }

    private var text: String {
        let lowered = (label.first.map { $0.lowercased() } ?? "") + label.dropFirst()
        let line = name + " — " + lowered
        return deviceName.map { L("deps.onDevice", line, $0) } ?? line
    }

    private var tint: Color {
        switch status.status {
        case .providedByXSide, .addedByYou, .builtIntoTweak: Color(nsColor: .systemGreen)
        case .missing, .jailbreakOnly: Color(nsColor: .systemRed)
        case .notNeeded: Color.secondary
        }
    }

    private var symbol: String {
        switch status.status {
        case .providedByXSide, .addedByYou, .builtIntoTweak: "checkmark"
        case .missing, .jailbreakOnly: "xmark"
        case .notNeeded: "minus"
        }
    }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).font(.system(size: 10, weight: .heavy))
        }
        .foregroundStyle(tint)
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
