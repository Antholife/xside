import AppKit
import os

enum XcodeLauncher {
    private static let logger = Logger(subsystem: "io.github.xside.XSide", category: "app")
    static let appStoreURL = URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!

    /// Xcode by bundle identifier, else the app enclosing the detected developer directory.
    @MainActor static func open(developerDir: URL?) {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")
            ?? (developerDir ?? selectedDeveloperDir()).flatMap(enclosingApp)
        guard let url else {
            logger.error("Xcode not found (bundle id, developer dir, xcode-select)")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// `xcode-select -p`: can succeed even when the signing probe fails (not signed in).
    private static func selectedDeveloperDir() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// `/Applications/Xcode-beta.app/Contents/Developer` becomes `/Applications/Xcode-beta.app`.
    static func enclosingApp(_ dir: URL) -> URL? {
        var url = dir.standardizedFileURL
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
