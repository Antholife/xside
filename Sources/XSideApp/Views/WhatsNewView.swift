import AppKit
import SwiftUI
import XSideCore

enum WhatsNewWindow {
    static let id = "whatsNew"
}

extension OpenWindowAction {
    /// Opens What's New in front: opened from the closing popover, XSide (a menu-bar agent) isn't
    /// active yet and the window would stay behind the others.
    @MainActor func presentWhatsNew() {
        // Active first, while the click still counts (as Settings does), then the window.
        NSApp.activate(ignoringOtherApps: true)
        self(id: WhatsNewWindow.id)
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(WhatsNewWindow.id) == true })
            else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

/// What a version brings, shown once after the update (see `WhatsNew.decide`) and from Settings.
struct ReleaseNotes {
    struct Item: Identifiable {
        let symbol: String
        let title: String
        let text: String
        var id: String { title }
    }

    /// Someone thanked in the notes: GitHub handle and what they did.
    struct Thanks {
        let handle: String
        let text: String
        let link: URL
        var profile: URL { URL(string: "https://github.com/\(handle)")! }
    }

    let version: String
    let label: String?
    let items: [Item]
    let thanks: [Thanks]

    /// Notes of the running version, if it has any. Add an entry here (and in CHANGELOG.md) for
    /// each release worth announcing.
    static var current: ReleaseNotes? {
        let version = Bundle.main.shortVersion ?? ""
        return all.first { $0.version == version }
    }

    static var all: [ReleaseNotes] {
        [
            ReleaseNotes(version: "1.0.3", label: "beta", items: [
                Item(symbol: "arrow.down.circle.fill",
                     title: L("whatsNew.103.updates.title"), text: L("whatsNew.103.updates.text")),
                Item(symbol: "rectangle.on.rectangle",
                     title: L("whatsNew.103.design.title"), text: L("whatsNew.103.design.text")),
                Item(symbol: "checklist",
                     title: L("whatsNew.103.preflight.title"), text: L("whatsNew.103.preflight.text")),
                Item(symbol: "bell.badge.fill",
                     title: L("whatsNew.103.notifications.title"), text: L("whatsNew.103.notifications.text")),
                Item(symbol: "gauge.with.dots.needle.67percent",
                     title: L("whatsNew.103.progress.title"), text: L("whatsNew.103.progress.text")),
                Item(symbol: "number",
                     title: L("whatsNew.103.appIDs.title"), text: L("whatsNew.103.appIDs.text")),
                Item(symbol: "dock.rectangle",
                     title: L("whatsNew.103.dock.title"), text: L("whatsNew.103.dock.text")),
                Item(symbol: "plus.square.on.square",
                     title: L("whatsNew.103.more.title"), text: L("whatsNew.103.more.text")),
            ], thanks: []),
            ReleaseNotes(version: "1.0.2", label: "beta", items: [
                Item(symbol: "doc.zipper",
                     title: L("whatsNew.102.ipa.title"), text: L("whatsNew.102.ipa.text")),
                Item(symbol: "doc.text.magnifyingglass",
                     title: L("whatsNew.102.logs.title"), text: L("whatsNew.102.logs.text")),
                Item(symbol: "ladybug.fill",
                     title: L("whatsNew.102.report.title"), text: L("whatsNew.102.report.text")),
            ], thanks: [
                Thanks(handle: "parmagit", text: L("whatsNew.102.thanks"),
                       link: URL(string: "https://github.com/Antholife/xside/issues/1")!),
            ]),
            ReleaseNotes(version: "1.0.1", label: "beta", items: [
                Item(symbol: "shippingbox.and.arrow.backward.fill",
                     title: L("whatsNew.101.ipa.title"), text: L("whatsNew.101.ipa.text")),
                Item(symbol: "text.magnifyingglass",
                     title: L("whatsNew.101.reason.title"), text: L("whatsNew.101.reason.text")),
                Item(symbol: "sparkles",
                     title: L("whatsNew.101.window.title"), text: L("whatsNew.101.window.text")),
            ], thanks: [
                Thanks(handle: "parmagit", text: L("whatsNew.101.thanks"),
                       link: URL(string: "https://github.com/Antholife/xside/issues/1")!),
            ]),
        ]
    }
}

struct WhatsNewWindowRoot: View {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        Group {
            if let notes = ReleaseNotes.current ?? ReleaseNotes.all.first {
                WhatsNewView(notes: notes)
            }
        }
        .id(language)
        .frame(width: 580)
        .navigationTitle(L("whatsNew.window"))
    }
}

/// A compact header, the first item as a featured card, the others as a two-column grid of
/// tiles, the thanks, then the full changelog link and "Let's go". Scrolls only past the screen.
private struct WhatsNewView: View {
    let notes: ReleaseNotes
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var appeared = false
    /// Natural height of the content, to size the window to it.
    @State private var contentHeight: CGFloat = 400

    private static var maxContentHeight: CGFloat {
        max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 220)
    }

    private var featured: ReleaseNotes.Item? { notes.items.first }
    private var others: [ReleaseNotes.Item] { Array(notes.items.dropFirst()) }
    private var paired: [ReleaseNotes.Item] { others.count.isMultiple(of: 2) ? others : Array(others.dropLast()) }
    private var lastAlone: ReleaseNotes.Item? { others.count.isMultiple(of: 2) ? nil : others.last }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if let featured {
                        FeaturedCard(item: featured).appearing(appeared, index: 0)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              alignment: .leading, spacing: 12) {
                        ForEach(Array(paired.enumerated()), id: \.element.id) { index, item in
                            ItemTile(item: item).appearing(appeared, index: index + 1)
                        }
                    }
                    // An odd one out takes the whole width rather than half a row.
                    if let last = lastAlone {
                        ItemTile(item: last).appearing(appeared, index: others.count)
                    }
                    ForEach(notes.thanks, id: \.handle) { thanks in
                        ThanksCard(thanks: thanks).appearing(appeared, index: notes.items.count)
                    }
                }
                .padding(20)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, Self.maxContentHeight))
            Divider()
            HStack {
                Link(destination: URL(string: "https://github.com/Antholife/xside/blob/main/CHANGELOG.md")!) {
                    Label(L("whatsNew.changelog"), systemImage: "list.bullet.rectangle")
                }
                .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(L("whatsNew.done")) { dismissWindow(id: WhatsNewWindow.id) }
                    .buttonStyle(GradientButtonStyle())
                    .frame(width: 160)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .onAppear { appeared = true }
    }

    /// Icon, title and version on one line, on the brand gradient under the hidden title bar.
    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 58, height: 58)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .scaleEffect(appeared ? 1 : 0.85)
                .animation(.spring(duration: 0.6, bounce: 0.4), value: appeared)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("whatsNew.title"))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text([L("whatsNew.version", notes.version), notes.label].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10.5, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.2), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 18)
        .background {
            ZStack {
                Theme.brand
                Circle().fill(.white.opacity(0.16)).frame(width: 260).blur(radius: 45).offset(x: -200, y: -50)
            }
            .clipped()
            .ignoresSafeArea(edges: .top)
        }
    }
}

extension View {
    /// Fades and slides in, one after the other.
    fileprivate func appearing(_ appeared: Bool, index: Int) -> some View {
        opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(.smooth(duration: 0.45).delay(0.1 + Double(index) * 0.06), value: appeared)
    }
}

/// The main novelty: a wide card with a large gradient icon on a soft brand wash.
private struct FeaturedCard: View {
    let item: ReleaseNotes.Item

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: item.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(color: Theme.violet.opacity(0.35), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 15, weight: .bold))
                Text(item.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(LinearGradient(colors: [Theme.violet.opacity(0.14), Theme.pink.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.violet.opacity(0.25), lineWidth: 0.5))
    }
}

/// One novelty in the grid: icon tile, title, a few lines.
private struct ItemTile: View {
    let item: ReleaseNotes.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(item.text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The thank-you note: a pink heart, the GitHub handle (to their profile) and a link to the report.
private struct ThanksCard: View {
    let thanks: ReleaseNotes.Thanks
    @State private var beat = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "heart.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.pink)
                .frame(width: 34, height: 34)
                .background(Theme.pink.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .scaleEffect(beat ? 1.12 : 1)
                .animation(.easeInOut(duration: 0.7).repeatCount(3, autoreverses: true).delay(0.6), value: beat)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(L("whatsNew.thanks.title"))
                    Link("@\(thanks.handle)", destination: thanks.profile)
                        .foregroundStyle(Theme.violet)
                }
                .font(.system(size: 13, weight: .semibold))
                Text(thanks.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(L("whatsNew.thanks.link"), destination: thanks.link)
                    .font(.system(size: 12, weight: .medium))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            LinearGradient(colors: [Theme.violet.opacity(0.10), Theme.pink.opacity(0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.pink.opacity(0.25), lineWidth: 0.5))
        .onAppear { beat = true }
    }
}
