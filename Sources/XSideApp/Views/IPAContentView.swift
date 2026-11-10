import SwiftUI
import XSideCore

/// « Ce qu'il y a dans cette IPA »: what someone added to the original app (tweaks, their
/// libraries, anything unknown, with warning signs), the accesses the app can ask for, and the
/// honest footer. At the top of the install window's step ① (and of its summary), and in Mes
/// apps' « Contenu de l'IPA… » sheet. Never blocks anything.
struct IPAContentCards: View {
    let content: IPAContent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AdditionsCard(content: content)
            AccessesCard(accesses: content.accesses)
            HonestFooter()
        }
    }
}

private struct CardHeader: View {
    let title: String
    var count: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).textCase(.uppercase).tracking(0.3)
            if let count { Text("· " + count).fontWeight(.medium) }
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }
}

private struct ContentCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AdditionsCard: View {
    let content: IPAContent

    var body: some View {
        let counted = content.counted
        let libraries = content.additions.filter { $0.kind == .tweakLibrary }
        ContentCard {
            CardHeader(title: L("ipaContent.title"), count: counted.isEmpty ? nil : L("ipaContent.count", counted.count))
            if content.additions.isEmpty {
                Label(L("ipaContent.clean"), systemImage: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemGreen))
            } else {
                ForEach(Array((counted + libraries).enumerated()), id: \.element.id) { index, addition in
                    if index > 0 { Divider().padding(.vertical, 1) }
                    AdditionRow(addition: addition, afterTweaks: !counted.isEmpty)
                }
            }
        }
    }
}

private struct AdditionRow: View {
    let addition: IPAAddition
    let afterTweaks: Bool

    private var isLibrary: Bool { addition.kind == .tweakLibrary }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isLibrary ? "gearshape" : "puzzlepiece.extension")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.violet)
                .frame(width: 26, height: 26)
                .background(Theme.violet.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(addition.name)
                        .font(.system(size: 13, weight: isLibrary ? .regular : .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let tag { Tag(text: tag.text, warns: tag.warns) }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(addition.path)
                ForEach(addition.signs, id: \.self) { SignBox(sign: $0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }

    private var tag: (text: String, warns: Bool)? {
        switch addition.kind {
        case .tweak: (L("ipaContent.kind.tweak"), false)
        case .tweakLibrary: (L("ipaContent.kind.tweakLibrary"), false)
        case .unknown: addition.hasMetadata ? nil : (L("ipaContent.noMetadata"), true)
        }
    }

    private var subtitle: String {
        if isLibrary { return L(afterTweaks ? "ipaContent.library.note" : "ipaContent.library.noteAlone") }
        let size = addition.size.formatted(.byteCount(style: .file).locale(appLocale))
        let load: String = switch addition.load {
        case .launch: L("ipaContent.load.launch")
        case .weak: L("ipaContent.load.weak")
        case .indirect: L("ipaContent.load.indirect", addition.loadedBy ?? "?")
        }
        return [addition.path, size, load].joined(separator: " · ")
    }
}

private struct Tag: View {
    let text: String
    let warns: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(warns ? Color(nsColor: .systemOrange) : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(warns ? Color(nsColor: .systemOrange).opacity(0.14) : Color.primary.opacity(0.08), in: Capsule())
            .fixedSize()
    }
}

private struct SignBox: View {
    let sign: WarningSign

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .systemOrange))
            (Text(L("ipaContent.sign.\(sign.rawValue).title")).bold().foregroundColor(Color(nsColor: .systemOrange))
             + Text(" " + L("ipaContent.sign.\(sign.rawValue).detail")))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .systemOrange).opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.top, 5)
    }
}

private struct AccessesCard: View {
    let accesses: [AppAccess]

    var body: some View {
        ContentCard {
            CardHeader(title: L("ipaContent.accesses.title"), count: accesses.isEmpty ? nil : "\(accesses.count)")
            if accesses.isEmpty {
                Text(L("ipaContent.accesses.none")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ChipFlow(spacing: 6) {
                    ForEach(accesses, id: \.self) { access in
                        Label(L("ipaContent.access.\(access.rawValue)"), systemImage: Self.symbol(access))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.violet)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Theme.violet.opacity(0.12), in: Capsule())
                    }
                }
                Text(L("ipaContent.accesses.note"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
    }

    static func symbol(_ access: AppAccess) -> String {
        switch access {
        case .notifications: "bell.fill"
        case .camera: "camera.fill"
        case .microphone: "mic.fill"
        case .photos: "photo.on.rectangle"
        case .location: "location.fill"
        case .contacts: "person.crop.circle"
        case .calendars: "calendar"
        case .reminders: "checklist"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .localNetwork: "network"
        case .motion: "figure.walk"
        case .health: "heart.fill"
        case .homeKit: "house.fill"
        case .mediaLibrary: "music.note"
        case .speech: "waveform"
        case .faceID: "faceid"
        case .tracking: "eye"
        case .nfc: "wave.3.right"
        case .siri: "waveform.circle"
        }
    }
}

/// Chips laid out in rows, wrapping to the width.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.indexes {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(indexes: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indexes: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].indexes.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

private struct HonestFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("ipaContent.honest"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: L("ipaContent.learnMoreURL")) {
                Button(L("ipaContent.learnMore")) { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .semibold))
                    .help(url.absoluteString)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// Mes apps « ⋯ » > « Contenu de l'IPA… »: the same cards for an installed app, read from the
/// IPA XSide kept (read again when the record has none yet).
struct IPAContentSheet: View {
    let model: AppModel
    let recordID: UUID
    let appName: String
    let onClose: () -> Void
    @State private var content: IPAContent?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("ipaContent.sheet.title", appName)).font(.headline).lineLimit(1)
                Spacer()
                Button(L("ipaContent.sheet.close"), action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let content {
                        IPAContentCards(content: content)
                        Text(L("ipaContent.sheet.note"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 2)
                    } else if failed {
                        Label(L("ipaContent.sheet.failed"), systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("ipaContent.sheet.reading")).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(width: 560, height: 520)
        .task {
            content = await model.ipaContent(for: recordID)
            failed = content == nil
        }
    }
}
