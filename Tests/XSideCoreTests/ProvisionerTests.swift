import Testing
import Foundation
@testable import XSideCore

private let team = "TEAM123456"
private let udid = "00000000-0000000000000001"

private func profilePlist(bundle: String, devices: [String]) -> Data {
    let dict: [String: Any] = [
        "UUID": "U-1",
        "TeamIdentifier": [team],
        "CreationDate": Date(timeIntervalSince1970: 1_700_000_000),
        "ExpirationDate": Date(timeIntervalSince1970: 1_700_600_000),
        "ProvisionedDevices": devices,
        "Entitlements": ["application-identifier": "\(team).\(bundle)"] as [String: Any],
    ]
    return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
}

private func env() -> SigningEnvironment {
    SigningEnvironment(developerDir: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
                       identitySHA1: "AAAA", identityName: "Apple Development: Test", teamID: team)
}

private func tempDir(_ name: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("xside-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func makeTemplate() throws -> URL {
    let t = try tempDir("template")
    try FileManager.default.createDirectory(at: t.appendingPathComponent("XSideTemplate.xcodeproj"),
                                            withIntermediateDirectories: true)
    try Data("x".utf8).write(to: t.appendingPathComponent("XSideTemplate.xcodeproj/project.pbxproj"))
    return t
}

/// Simulates xcodebuild writing the profile under the derivedData path.
@Sendable private func writeProfile(_ args: [String]) {
    guard let i = args.firstIndex(of: "-derivedDataPath") else { return }
    let app = URL(fileURLWithPath: args[i + 1])
        .appendingPathComponent("Build/Products/Debug-iphoneos/XSideTemplate.app")
    try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try? Data("p".utf8).write(to: app.appendingPathComponent("embedded.mobileprovision"))
}

private final class Box: @unchecked Sendable {
    private let l = NSLock(); private var v: [[String]] = []
    func add(_ a: [String]) { l.lock(); v.append(a); l.unlock() }
    var all: [[String]] { l.lock(); defer { l.unlock() }; return v }
}

@Suite struct ProvisionerTests {
    @Test func argumentsMatchSpike() {
        let args = Provisioner.arguments(
            project: URL(fileURLWithPath: "/w/copy/XSideTemplate.xcodeproj"),
            derivedData: URL(fileURLWithPath: "/w/copy/dd"),
            bundleID: "com.example.app", teamID: team, deviceUDIDs: [udid, "ignored"])
        #expect(args == [
            "xcodebuild", "-project", "/w/copy/XSideTemplate.xcodeproj", "-scheme", "XSideTemplate",
            "-configuration", "Debug", "-destination", "id=\(udid)", "-derivedDataPath", "/w/copy/dd",
            "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
            "DEVELOPMENT_TEAM=\(team)", "PRODUCT_BUNDLE_IDENTIFIER=com.example.app",
            "CODE_SIGN_STYLE=Automatic", "build",
        ])
    }

    @Test func copiesTemplatePerBuild() async throws {
        let template = try makeTemplate(), work = try tempDir("work")
        let runner = FakeRunner()
        let seen = Box()
        runner.stub("/usr/bin/xcrun", firstArg: "xcodebuild", result: CommandResult(status: 0, stdout: Data(), stderr: "")) {
            seen.add($0); writeProfile($0)
        }
        runner.stub("/usr/bin/security", result: CommandResult(
            status: 0, stdout: profilePlist(bundle: "com.example.app", devices: [udid]), stderr: ""))
        let p = Provisioner(runner: runner, templateDir: template, workDir: work)
        let r = try await p.profile(bundleID: "com.example.app", env: env(), deviceUDIDs: [udid])
        let args = try #require(seen.all.first)
        let project = args[args.firstIndex(of: "-project")! + 1]
        #expect(project.hasPrefix(work.path))
        #expect(!project.hasPrefix(template.path))
        #expect(r.profile.bundleID == "com.example.app")
        #expect(r.url.path.hasPrefix(work.path))
        #expect(FileManager.default.fileExists(atPath: r.url.path))
        // Per-build copy cleaned up.
        let left = try FileManager.default.contentsOfDirectory(atPath: work.path)
        #expect(left == [r.url.lastPathComponent])
    }

    @Test func emptyDevicesThrowsBeforeRunning() async throws {
        let runner = FakeRunner()
        let p = Provisioner(runner: runner, templateDir: try makeTemplate(), workDir: try tempDir("work"))
        await #expect(throws: XSideError.provisioningFailed("no target device")) {
            _ = try await p.profile(bundleID: "a.b", env: env(), deviceUDIDs: [])
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func rejectsProfileWithoutTargetDevice() async throws {
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", firstArg: "xcodebuild", result: CommandResult(status: 0, stdout: Data(), stderr: ""),
                    effect: writeProfile)
        runner.stub("/usr/bin/security", result: CommandResult(
            status: 0, stdout: profilePlist(bundle: "a.b", devices: ["OTHER"]), stderr: ""))
        let work = try tempDir("work")
        let p = Provisioner(runner: runner, templateDir: try makeTemplate(), workDir: work)
        await #expect(throws: XSideError.self) {
            _ = try await p.profile(bundleID: "a.b", env: env(), deviceUDIDs: [udid])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
    }

    @Test func failureMapsAndCleansUp() async throws {
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", firstArg: "xcodebuild", result: CommandResult(
            status: 65, stdout: Data("error: No Accounts: Add a new account in Accounts settings.\n".utf8), stderr: ""))
        let work = try tempDir("work")
        let p = Provisioner(runner: runner, templateDir: try makeTemplate(), workDir: work)
        await #expect(throws: XSideError.xcodeNotSignedIn) {
            _ = try await p.profile(bundleID: "a.b", env: env(), deviceUDIDs: [udid])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
    }

    @Test func mapsKnownErrors() {
        #expect(Provisioner.mapError("error: No Accounts: Add a new account in Accounts settings.") == .xcodeNotSignedIn)
        #expect(Provisioner.mapError("""
            /p/X.xcodeproj: error: No Account for Team "TEAM123456". Add a new account in Accounts settings or verify that your accounts have valid credentials. (in target 'XSideTemplate' from project 'XSideTemplate')
            /p/X.xcodeproj: error: No profiles for 'a.b' were found: Xcode couldn't find any. (in target 'XSideTemplate' from project 'XSideTemplate')
            """) == .xcodeNotSignedIn)
        #expect(Provisioner.mapError("""
            /p/X.xcodeproj: error: No profiles for 'a.b' were found: Xcode couldn't find any iOS App Development provisioning profiles matching 'a.b'. (in target 'XSideTemplate' from project 'XSideTemplate')
            """) == .provisioningFailed("No profiles for 'a.b' were found: Xcode couldn't find any iOS App Development provisioning profiles matching 'a.b'."))
        #expect(Provisioner.mapError("error: Cannot create App ID: you have reached the maximum number of App IDs") == .appIDLimitReached)
        #expect(Provisioner.mapError("noise\nx.swift:3: error: weird thing happened (in target 'T')\nerror: second") == .provisioningFailed("weird thing happened"))
        #expect(Provisioner.mapError("nothing useful") == .commandFailed(tool: "xcodebuild", status: -1))
    }
}
