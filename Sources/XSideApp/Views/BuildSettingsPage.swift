import AppKit
import SwiftUI

/// Settings > Créer & contribuer: XSide is open source, so make it yours (your own changes with
/// an AI agent, scripts with the `xside` command) and, if you like, share it back. Contributing is
/// one option among others. Each card is a `BuildCard`, so a new one is a single entry in `body`.
struct BuildSettingsPage: View {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                hero
                BuildCard(symbol: "wand.and.stars", title: L("build.agent.title"), text: L("build.agent.text")) {
                    AgentButtons()
                }
                BuildCard(symbol: "terminal.fill", title: L("build.cli.title"), text: L("build.cli.text")) {
                    CommandLineStatus()
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Self.commands, id: \.self) { command in
                            Text(command)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                BuildCard(symbol: "bubble.left.and.exclamationmark.bubble.right.fill",
                          title: L("build.share.title"), text: L("build.share.text")) {
                    HStack(spacing: 18) {
                        Link(destination: AppLinks.issues) { Label(L("build.share.issues"), systemImage: "exclamationmark.bubble") }
                        Link(destination: AppLinks.pullRequests) { Label(L("build.share.pulls"), systemImage: "arrow.triangle.pull") }
                    }
                    .font(.callout)
                }
                // "Request a fix" without an app (the crash window sends one with its diagnosis).
                BuildCard(symbol: "lightbulb.fill", title: L("fixes.section"), text: L("fixes.request.text")) {
                    FixRequestButton(appName: nil).controlSize(.regular)
                }
                footer
            }
            .padding(24)
            .reportsPaneHeight()
        }
    }

    /// The real commands of `xside` (Sources/XSideCLI), as its own help prints them.
    private static let commands = [
        "xside status [--json]",
        "xside apps | devices [--json]",
        "xside settings <app> [field=value…]",
        "xside refresh <app> | --all",
        "xside pause [<app>] [2h]",
        "xside resume [<app>]",
        "xside uninstall <app> [--yes]",
        "xside install <file.ipa>",
        "xside logs [-f] | report",
        "xside open",
    ]

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "hammer.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.brand)
            Text(L("build.hero.title")).font(.system(size: 20, weight: .bold))
            Text(L("build.hero.text"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.brandWash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(L("about.license")).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Link(L("build.contributing"), destination: AppLinks.contributing)
        }
        .font(.caption)
    }
}

/// A rounded card: gradient icon tile, title, explanation, then its own controls.
private struct BuildCard<Content: View>: View {
    let symbol: String
    let title: String
    let text: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// "Open AGENTS.md" and "Copy a starter prompt" (which says Copied for a moment).
private struct AgentButtons: View {
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Button { NSWorkspace.shared.open(AppLinks.agentsGuide) } label: {
                Label(L("build.agent.open"), systemImage: "doc.text")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(L("build.agent.prompt"), forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? L("build.agent.copied") : L("build.agent.copy"),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .controlSize(.regular)
    }
}

/// The terminal card: whether `xside` is installed, else the same Install button as Settings >
/// General (the same action and state: `CommandLineInstall`), device feedback round 2, M3.
private struct CommandLineStatus: View {
    @State private var cli = CommandLineInstall.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let link = cli.link {
                Label(L("build.cli.installed", link.deletingLastPathComponent().path), systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button(action: cli.install) {
                    Label(L("build.cli.install"), systemImage: "terminal")
                }
                .controlSize(.regular)
                if cli.needsManual {
                    Text(L("cli.manual"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    CommandLineManual()
                }
            }
        }
        .onAppear(perform: cli.refresh)
    }
}
