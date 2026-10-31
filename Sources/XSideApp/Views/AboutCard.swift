import AppKit
import SwiftUI

extension Bundle {
    /// "1.0.2" (`CFBundleShortVersionString`), nil outside an app bundle.
    var shortVersion: String? { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
}

/// Settings > About: icon, version and build stamp, author, repository and licence.
struct AboutCard: View {
    @Environment(\.openWindow) private var openWindow
    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    /// "Version 0.1.0 (46)".
    private var version: String {
        L("about.version", Bundle.main.shortVersion ?? "–", Self.info("CFBundleVersion") ?? "–")
    }

    /// "Build f9b997a · 30 Oct 2026, 14:02", from the stamp written by `scripts/bundle.sh`.
    private var build: String? {
        let commit = Self.info("XSideGitCommit")
        let date = Self.info("XSideBuildDate").flatMap { try? Date($0, strategy: .iso8601) }?
            .formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(appLocale))
        let parts = [commit, date].compactMap { $0 }
        return parts.isEmpty ? nil : L("about.build", parts.joined(separator: " · "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("XSide").font(.system(size: 17, weight: .bold))
                    Text(version).font(.callout).foregroundStyle(.secondary)
                    if let build {
                        Text(build).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
                Spacer()
            }
            HStack(spacing: 4) {
                Text(L("about.by"))
                Link("Antholife", destination: AppLinks.author).fontWeight(.semibold)
                Text("·").foregroundStyle(.tertiary)
                Text(L("about.license")).foregroundStyle(.secondary)
            }
            .font(.callout)
            .lineLimit(1)
            HStack(spacing: 18) {
                Link(destination: AppLinks.repository) {
                    Label { Text(L("settings.github")) } icon: { Image.githubMark }
                }
                Button {
                    openWindow(id: WhatsNewWindow.id)
                    NSApp.activate()
                } label: {
                    Label(L("whatsNew.open"), systemImage: "sparkles")
                }
                .buttonStyle(.link)
            }
            .font(.callout)
            .lineLimit(1)
            .fixedSize()
            Text(L("about.tagline"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
