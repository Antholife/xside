import AppKit
import SwiftUI

/// Settings > About: icon, version and build stamp, author, repository and licence.
struct AboutCard: View {
    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    /// "Version 0.1.0 (46)".
    private var version: String {
        L("about.version", Self.info("CFBundleShortVersionString") ?? "–", Self.info("CFBundleVersion") ?? "–")
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
            }
            .font(.callout)
            HStack(spacing: 14) {
                Link(destination: AppLinks.repository) {
                    Label(L("settings.github"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Text(L("about.license")).foregroundStyle(.secondary)
            }
            .font(.callout)
            Text(L("about.tagline"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
