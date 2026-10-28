import Foundation

/// Obtains a development provisioning profile by letting Xcode (already signed in) build
/// a tiny template project with automatic signing. XSide never talks to Apple itself.
public struct Provisioner: Sendable {
    private let runner: CommandRunning
    private let templateDir: URL
    private let workDir: URL

    public init(runner: CommandRunning, templateDir: URL, workDir: URL) {
        self.runner = runner
        self.templateDir = templateDir
        self.workDir = workDir
    }

    /// Builds the template for `bundleID` targeting `deviceUDIDs[0]`. Returns a stable copy of the
    /// profile inside `workDir` (the per-build directory is removed).
    public func profile(bundleID: String, env: SigningEnvironment,
                        deviceUDIDs: [String]) async throws -> (url: URL, profile: ProvisioningProfile) {
        guard let target = deviceUDIDs.first else { throw XSideError.provisioningFailed("no target device") }
        let fm = FileManager.default
        let buildDir = workDir.appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try fm.copyItem(at: templateDir, to: buildDir)
        defer { try? fm.removeItem(at: buildDir) }

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
        let stable = workDir.appendingPathComponent("\(bundleID).mobileprovision")
        try? fm.removeItem(at: stable)
        try fm.copyItem(at: built, to: stable)

        let profile = try await ProfileReader(runner: runner).read(stable)
        guard profile.deviceUDIDs.contains(target) else {
            try? fm.removeItem(at: stable)
            throw XSideError.provisioningFailed("target device not in provisioning profile")
        }
        return (stable, profile)
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
