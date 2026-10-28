import Foundation
import os

/// Obtains a development provisioning profile by letting Xcode (already signed in) build
/// a tiny template project with automatic signing. XSide never talks to Apple itself.
public struct Provisioner: Sendable {
    private static let logger = Logger(subsystem: "io.github.xside.XSide", category: "provisioning")

    private let runner: CommandRunning
    private let templateDir: URL
    private let workDir: URL
    private let cacheDirs: [URL]

    /// `cacheDirs`: Xcode's provisioning profile cache directories. Before each build, the cached
    /// profiles for exactly `<TEAM>.<bundleID>` are removed there, otherwise Xcode keeps reusing a
    /// still-valid profile and the expiry never moves forward. Nothing else in them is touched.
    public init(runner: CommandRunning, templateDir: URL, workDir: URL, cacheDirs: [URL]) {
        self.runner = runner
        self.templateDir = templateDir
        self.workDir = workDir
        self.cacheDirs = cacheDirs
    }

    /// Builds the template for `bundleID` targeting `deviceUDIDs[0]`. Returns a uniquely named copy of the
    /// profile inside `workDir` (the per-build directory is removed).
    public func profile(bundleID: String, env: SigningEnvironment,
                        deviceUDIDs: [String]) async throws -> (url: URL, profile: ProvisioningProfile) {
        guard let target = deviceUDIDs.first else { throw XSideError.provisioningFailed("no target device") }
        let fm = FileManager.default
        let buildDir = workDir.appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try fm.copyItem(at: templateDir, to: buildDir)
        defer { try? fm.removeItem(at: buildDir) }

        await purgeCachedProfiles(applicationIdentifier: "\(env.teamID).\(bundleID)", teamID: env.teamID)

        let derivedData = buildDir.appendingPathComponent("DerivedData", isDirectory: true)
        let args = Self.arguments(
            project: buildDir.appendingPathComponent("XSideTemplate.xcodeproj"),
            derivedData: derivedData, bundleID: bundleID, teamID: env.teamID, deviceUDIDs: deviceUDIDs)
        let result = try await runner.run("/usr/bin/xcrun", args, cwd: buildDir)
        guard result.status == 0 else {
            let combined = String(decoding: result.stdout, as: UTF8.self) + "\n" + result.stderr
            let mapped = Self.mapError(combined)
            if case .commandFailed = mapped { throw XSideError.commandFailed(tool: "xcodebuild", status: result.status) }
            throw mapped
        }

        let built = derivedData.appendingPathComponent(
            "Build/Products/Debug-iphoneos/XSideTemplate.app/embedded.mobileprovision")
        guard fm.fileExists(atPath: built.path) else {
            throw XSideError.provisioningFailed("embedded.mobileprovision not produced")
        }
        // Unique per call: concurrent jobs for the same app on different devices must not share it.
        let stable = workDir.appendingPathComponent("\(bundleID)-\(UUID().uuidString).mobileprovision")
        try fm.copyItem(at: built, to: stable)

        let profile: ProvisioningProfile
        do {
            profile = try await ProfileReader(runner: runner).read(stable)
        } catch {
            try? fm.removeItem(at: stable)
            throw error
        }
        guard profile.deviceUDIDs.contains(target) else {
            try? fm.removeItem(at: stable)
            throw XSideError.provisioningFailed("target device not in provisioning profile")
        }
        return (stable, profile)
    }

    /// Removes the cached `*.mobileprovision` files whose team is `teamID` and whose decoded
    /// `application-identifier` is exactly `applicationIdentifier`. Unreadable files and missing
    /// directories are skipped; a failed removal is logged and doesn't stop the build.
    private func purgeCachedProfiles(applicationIdentifier: String, teamID: String) async {
        let fm = FileManager.default
        let reader = ProfileReader(runner: runner)
        for dir in cacheDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "mobileprovision" {
                guard let cached = try? await reader.read(file), cached.teamID == teamID,
                      cached.applicationIdentifier == applicationIdentifier else { continue }
                do {
                    try fm.removeItem(at: file)
                    Self.logger.notice("removed cached profile \(cached.uuid, privacy: .public)")
                } catch {
                    Self.logger.error("could not remove cached profile \(cached.uuid, privacy: .public)")
                }
            }
        }
    }

    public static func arguments(project: URL, derivedData: URL, bundleID: String, teamID: String,
                                 deviceUDIDs: [String]) -> [String] {
        var args = ["xcodebuild", "-project", project.path, "-scheme", "XSideTemplate",
                    "-configuration", "Debug"]
        if let first = deviceUDIDs.first { args += ["-destination", "id=\(first)"] }
        args += ["-derivedDataPath", derivedData.path,
                 "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
                 "DEVELOPMENT_TEAM=\(teamID)", "PRODUCT_BUNDLE_IDENTIFIER=\(bundleID)",
                 "CODE_SIGN_STYLE=Automatic", "build"]
        return args
    }

    /// Maps combined xcodebuild output to an error. With no error line at all it returns
    /// `.commandFailed(tool: "xcodebuild", status: -1)`; the caller substitutes the real status.
    public static func mapError(_ output: String) -> XSideError {
        let lower = output.lowercased()
        if lower.contains("no accounts:") || lower.contains("no account for team") {
            return .xcodeNotSignedIn
        }
        let errors = errorLines(output)
        for line in errors {
            let l = line.lowercased()
            if l.contains("app id"), l.contains("maximum") || l.contains("limit") { return .appIDLimitReached }
        }
        if let first = errors.first { return .provisioningFailed(first) }
        return .commandFailed(tool: "xcodebuild", status: -1)
    }

    private static func errorLines(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            guard let r = raw.range(of: "error: ") else { return nil }
            var msg = String(raw[r.upperBound...])
            if let suffix = msg.range(of: " (in target") { msg = String(msg[..<suffix.lowerBound]) }
            msg = msg.trimmingCharacters(in: .whitespaces)
            return msg.isEmpty ? nil : msg
        }
    }
}
