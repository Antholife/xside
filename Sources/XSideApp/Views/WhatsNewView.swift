import AppKit
import SwiftUI
import XSideCore

enum WhatsNewWindow {
    static let id = "whatsNew"
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
        .frame(width: 460)
        .navigationTitle(L("whatsNew.window"))
    }
}

private struct WhatsNewView: View {
    let notes: ReleaseNotes
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(notes.items.enumerated()), id: \.element.id) { index, item in
                    ItemCard(item: item)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(.smooth(duration: 0.45).delay(0.12 + Double(index) * 0.07), value: appeared)
                }
                ForEach(notes.thanks, id: \.handle) { thanks in
                    ThanksCard(thanks: thanks)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)
                        .animation(.smooth(duration: 0.45).delay(0.12 + Double(notes.items.count) * 0.07),
                                   value: appeared)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            Button(L("whatsNew.done")) { dismissWindow(id: WhatsNewWindow.id) }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(24)
        }
        .onAppear { appeared = true }
    }

    /// Brand gradient with soft light blobs, the icon, the title and the version pill.
    private var hero: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 76, height: 76)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .scaleEffect(appeared ? 1 : 0.8)
                .animation(.spring(duration: 0.6, bounce: 0.4), value: appeared)
                .accessibilityHidden(true)
            Text(L("whatsNew.title"))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text([L("whatsNew.version", notes.version), notes.label].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.white.opacity(0.2), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .background {
            // The gradient alone goes under the hidden title bar; the content stays below it.
            ZStack {
                Theme.brand
                Circle().fill(.white.opacity(0.18)).frame(width: 220).blur(radius: 40).offset(x: -150, y: -70)
                Circle().fill(Color(red: 1, green: 0.85, blue: 0.3).opacity(0.35)).frame(width: 180)
                    .blur(radius: 50).offset(x: 170, y: 60)
            }
            .clipped()
            .ignoresSafeArea(edges: .top)
        }
    }
}

private struct ItemCard: View {
    let item: ReleaseNotes.Item

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: Theme.violet.opacity(0.25), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .semibold))
                Text(item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
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
