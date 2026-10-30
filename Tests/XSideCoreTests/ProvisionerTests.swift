import Testing
import Foundation
@testable import XSideCore

private let team = "TEAM123456"
private let udid = "00000000-0000000000000001"

private func profilePlist(bundle: String, devices: [String], uuid: String = "U-1",
                          teamID: String = team, appIDPrefix: String? = nil) -> Data {
    let dict: [String: Any] = [
        "UUID": uuid,
        "TeamIdentifier": [teamID],
        "CreationDate": Date(timeIntervalSince1970: 1_700_000_000),
        "ExpirationDate": Date(timeIntervalSince1970: 1_700_600_000),
        "ProvisionedDevices": devices,
        "Entitlements": ["application-identifier": "\(appIDPrefix ?? teamID).\(bundle)"] as [String: Any],
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

/// `security cms -D -i <file>` returns the file's bytes (test profiles are stored as plain plists);
/// xcodebuild writes `built` as the produced profile. Records every command in order.
private final class CacheRunner: CommandRunning, @unchecked Sendable {
    private let l = NSLock(); private var log: [[String]] = []
    let built: Data
    init(built: Data) { self.built = built }
    var calls: [[String]] { l.lock(); defer { l.unlock() }; return log }
    func run(_ executable: String, _ arguments: [String], cwd: URL?, timeout: Duration) async throws -> CommandResult {
        l.withLock { log.append([executable] + arguments) }
        if executable == "/usr/bin/security", let path = arguments.last {
            guard let data = FileManager.default.contents(atPath: path) else {
                return CommandResult(status: 1, stdout: Data(), stderr: "unreadable")
            }
            return CommandResult(status: 0, stdout: data, stderr: "")
        }
        if arguments.first == "xcodebuild", let i = arguments.firstIndex(of: "-derivedDataPath") {
            let app = URL(fileURLWithPath: arguments[i + 1])
                .appendingPathComponent("Build/Products/Debug-iphoneos/XSideTemplate.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try built.write(to: app.appendingPathComponent("embedded.mobileprovision"))
            return CommandResult(status: 0, stdout: Data(), stderr: "")
        }
        throw FakeRunnerError(command: [executable] + arguments)
    }
}

private final class Box: @unchecked Sendable {
    private let l = NSLock(); private var v: [[String]] = []
    func add(_ a: [String]) { l.lock(); v.append(a); l.unlock() }
    var all: [[String]] { l.lock(); defer { l.unlock() }; return v }
}

@Suite struct ProvisionerTests {
    @Test func certificateArgumentsTargetAnyDeviceWithFixedBundleID() {
        let args = Provisioner.certificateArguments(project: URL(fileURLWithPath: "/w/XSideTemplate.xcodeproj"),
                                                    derivedData: URL(fileURLWithPath: "/w/DD"), teamID: "TEAM123456")
        #expect(args.contains("generic/platform=iOS"))
        #expect(args.contains("PRODUCT_BUNDLE_IDENTIFIER=io.github.xside.certificate.TEAM123456"))
        #expect(args.contains("-allowProvisioningUpdates"))
        #expect(!args.contains("-allowProvisioningDeviceRegistration"))
    }

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
        let p = Provisioner(runner: runner, templateDir: template, workDir: work, cacheDirs: [])
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
        #expect(r.url.deletingLastPathComponent().standardizedFileURL == work.standardizedFileURL)
        #expect(r.url.lastPathComponent.hasPrefix("com.example.app-"))
        #expect(r.url.lastPathComponent.hasSuffix(".mobileprovision"))
    }

    @Test func eachCallWritesItsOwnProfileFile() async throws {
        let template = try makeTemplate(), work = try tempDir("work")
        let runner = FakeRunner()
        runner.stub("/usr/bin/xcrun", firstArg: "xcodebuild", result: CommandResult(status: 0, stdout: Data(), stderr: ""),
                    effect: writeProfile)
        runner.stub("/usr/bin/security", result: CommandResult(
            status: 0, stdout: profilePlist(bundle: "com.example.app", devices: [udid]), stderr: ""))
        let p = Provisioner(runner: runner, templateDir: template, workDir: work, cacheDirs: [])
        let a = try await p.profile(bundleID: "com.example.app", env: env(), deviceUDIDs: [udid])
        let b = try await p.profile(bundleID: "com.example.app", env: env(), deviceUDIDs: [udid])
        #expect(a.url != b.url)
        #expect(FileManager.default.fileExists(atPath: a.url.path))
        #expect(FileManager.default.fileExists(atPath: b.url.path))
        for r in [a, b] {
            #expect(r.url.deletingLastPathComponent().standardizedFileURL == work.standardizedFileURL)
            #expect(r.url.lastPathComponent.hasPrefix("com.example.app-"))
            #expect(r.url.lastPathComponent.hasSuffix(".mobileprovision"))
        }
    }

    @Test func emptyDevicesThrowsBeforeRunning() async throws {
        let runner = FakeRunner()
        let p = Provisioner(runner: runner, templateDir: try makeTemplate(), workDir: try tempDir("work"), cacheDirs: [])
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
        let p = Provisioner(runner: runner, templateDir: try makeTemplate(), workDir: work, cacheDirs: [])
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
        let p = Provisioner(runner: runner, templateDir: try makeTemplate(), workDir: work, cacheDirs: [])
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

    @Test func purgesOnlyMatchingCachedProfilesBeforeBuilding() async throws {
        let bundle = "com.example.app.\(team)"
        let fm = FileManager.default
        let userData = try tempDir("cache-userdata"), legacy = try tempDir("cache-legacy")
        let missing = userData.appendingPathComponent("does-not-exist", isDirectory: true)
        defer { for d in [userData, legacy] { try? fm.removeItem(at: d) } }
        func put(_ dir: URL, _ name: String, _ data: Data) throws -> URL {
            let u = dir.appendingPathComponent(name); try data.write(to: u); return u
        }
        let match1 = try put(userData, "A.mobileprovision", profilePlist(bundle: bundle, devices: [udid], uuid: "A"))
        let match2 = try put(legacy, "B.mobileprovision", profilePlist(bundle: bundle, devices: [udid], uuid: "B"))
        let keep = [
            try put(userData, "other-bundle.mobileprovision", profilePlist(bundle: "com.other", devices: [udid])),
            try put(userData, "prefix.mobileprovision", profilePlist(bundle: "\(bundle).ext", devices: [udid])),
            try put(userData, "wildcard.mobileprovision", profilePlist(bundle: "*", devices: [udid])),
            try put(userData, "other-team.mobileprovision",
                    profilePlist(bundle: bundle, devices: [udid], teamID: "OTHERTEAM1")),
            // Team matches but the application-identifier prefix doesn't: not exactly TEAM.bundle.
            try put(userData, "odd-prefix.mobileprovision",
                    profilePlist(bundle: bundle, devices: [udid], appIDPrefix: "OTHERTEAM1")),
            try put(userData, "garbage.mobileprovision", Data("not a profile".utf8)),
            try put(userData, "same-bundle.txt", profilePlist(bundle: bundle, devices: [udid])),
        ]
        let runner = CacheRunner(built: profilePlist(bundle: bundle, devices: [udid], uuid: "NEW"))
        let p = Provisioner(runner: runner, templateDir: try makeTemplate(), workDir: try tempDir("work"),
                            cacheDirs: [userData, legacy, missing])
        let r = try await p.profile(bundleID: bundle, env: env(), deviceUDIDs: [udid])

        #expect(r.profile.uuid == "NEW")
        #expect(!fm.fileExists(atPath: match1.path))
        #expect(!fm.fileExists(atPath: match2.path))
        for u in keep { #expect(fm.fileExists(atPath: u.path), "\(u.lastPathComponent) must be kept") }
        // Cache inspected before xcodebuild runs.
        let calls = runner.calls
        let build = try #require(calls.firstIndex { $0.count > 1 && $0[1] == "xcodebuild" })
        let cacheNames = Set(([match1, match2] + keep).map(\.lastPathComponent))
        let cacheReads = calls.indices.filter {
            calls[$0].first == "/usr/bin/security"
                && cacheNames.contains(URL(fileURLWithPath: calls[$0].last ?? "").lastPathComponent)
        }
        #expect(!cacheReads.isEmpty)
        #expect(cacheReads.allSatisfy { $0 < build })
    }

    @Test func purgeFailureDoesNotBlockBuild() async throws {
        // A cache directory that can't be listed is skipped.
        let bundle = "com.example.app.\(team)"
        let notADir = try tempDir("cache-file").appendingPathComponent("file")
        try Data("x".utf8).write(to: notADir)
        let runner = CacheRunner(built: profilePlist(bundle: bundle, devices: [udid], uuid: "NEW"))
        let p = Provisioner(runner: runner, templateDir: try makeTemplate(), workDir: try tempDir("work"),
                            cacheDirs: [notADir])
        let r = try await p.profile(bundleID: bundle, env: env(), deviceUDIDs: [udid])
        #expect(r.profile.uuid == "NEW")
        #expect(FileManager.default.fileExists(atPath: notADir.path))
    }
}
