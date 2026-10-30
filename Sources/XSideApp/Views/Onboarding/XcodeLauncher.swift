import AppKit
import os
import XSideCore

enum XcodeLauncher {
    private static let logger = Log("app")
    static let appStoreURL = URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!
    static let betaURL = URL(string: "https://developer.apple.com/download/applications/")!

    /// macOS build ("26B123"), empty if unreadable.
    static let macBuild: String = {
        #if DEBUG
        // Debug-only: XSIDE_FAKE_MAC_BUILD=26C5012e shows the macOS-beta screens.
        if let fake = ProcessInfo.processInfo.environment["XSIDE_FAKE_MAC_BUILD"] { return fake }
        #endif
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()

    /// macOS version ("27.2", or "27.2.1").
    static let macVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)"
                                   : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    /// The Mac runs a macOS beta (build "26A5279m"): a release Xcode may not support it.
    static let macIsBeta = XcodeCompat.isBetaBuild(macBuild)

    /// The Xcode XSide uses (the app enclosing its developer directory), else Xcode by bundle
    /// identifier, else the one `xcode-select` points to.
    @MainActor static func open(developerDir: URL?) {
        // The enclosing app may have been deleted or moved since the probe.
        let url = developerDir.flatMap(enclosingApp).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: XcodeLocator.bundleID)
            ?? selectedDeveloperDir().flatMap(enclosingApp)
        guard let url else {
            logger.error("Xcode not found (bundle id, developer dir, xcode-select)")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens Xcode so that its Settings (⌘,) show the Accounts pane: Xcode reopens its last
    /// viewed pane, read at launch, so it's only set while Xcode isn't running.
    @MainActor static func openAccounts(developerDir: URL?) {
        let xcodeID = "com.apple.dt.Xcode"
        if NSRunningApplication.runningApplications(withBundleIdentifier: xcodeID).isEmpty {
            CFPreferencesSetAppValue("IDELastViewedSettingsPane" as CFString,
                                     "IDEKit.IDESettingsPane.Accounts" as CFString, xcodeID as CFString)
            CFPreferencesAppSynchronize(xcodeID as CFString)
        }
        open(developerDir: developerDir)
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
