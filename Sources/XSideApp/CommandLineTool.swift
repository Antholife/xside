import AppKit
import XSideCore

/// Puts the `xside` tool (Contents/Helpers/xside) in the Terminal's PATH: a link in the first
/// writable usual folder (Homebrew's, then /usr/local/bin). Without one, the command to run
/// with admin rights is given instead.
enum CommandLineTool {
    private static let log = Log("app")

    /// The tool inside this XSide.app.
    static var bundled: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/xside") }

    private static let folders = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Where a link to `bundled` already is, if any.
    static var installedLink: URL? {
        folders.map { URL(fileURLWithPath: $0).appendingPathComponent("xside") }.first { link in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == bundled.path
        }
    }

    /// The command to install it by hand (admin rights), when no usual folder is writable.
    static var manualCommand: String { "sudo ln -sf '\(bundled.path)' /usr/local/bin/xside" }

    /// Links the tool into the first writable folder. False when none is (then `manualCommand`).
    static func install() -> Bool {
        let fm = FileManager.default
        for folder in folders where fm.isWritableFile(atPath: folder) {
            let link = URL(fileURLWithPath: folder).appendingPathComponent("xside")
            // Never replace a different program that happens to be called xside.
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path), !existing.hasSuffix("/Contents/Helpers/xside") {
                continue
            }
            if fm.fileExists(atPath: link.path) || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try? fm.removeItem(at: link)
            }
            do {
                try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
                log.notice("command line tool linked in \(folder)")
                return true
            } catch {
                log.error("linking the command line tool in \(folder) failed: \(error)")
            }
        }
        return false
    }

    static func uninstall() {
        guard let link = installedLink else { return }
        try? FileManager.default.removeItem(at: link)
        log.notice("command line tool unlinked")
    }
}
