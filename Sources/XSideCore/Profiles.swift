import Foundation

public struct ProvisioningProfile: Equatable, Sendable {
    public let uuid: String
    public let teamID: String
    /// `application-identifier` without the `TEAM.` prefix.
    public let bundleID: String
    public let creationDate: Date
    public let expirationDate: Date
    public let deviceUDIDs: [String]
    /// XML plist of the `Entitlements` dictionary.
    public let entitlements: Data

    public init(uuid: String, teamID: String, bundleID: String, creationDate: Date,
                expirationDate: Date, deviceUDIDs: [String], entitlements: Data) {
        self.uuid = uuid
        self.teamID = teamID
        self.bundleID = bundleID
        self.creationDate = creationDate
        self.expirationDate = expirationDate
        self.deviceUDIDs = deviceUDIDs
        self.entitlements = entitlements
    }

    /// Full `application-identifier` entitlement (`TEAM.bundle`), decoded from `entitlements`.
    public var applicationIdentifier: String? {
        let ents = try? PropertyListSerialization.propertyList(from: entitlements, format: nil) as? [String: Any]
        return ents?["application-identifier"] as? String
    }

    public static func parse(plist: Data) throws -> ProvisioningProfile {
        func fail(_ why: String) -> XSideError { .provisioningFailed(why) }
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else {
            throw fail("invalid provisioning profile plist")
        }
        guard let uuid = root["UUID"] as? String,
              let team = (root["TeamIdentifier"] as? [String])?.first,
              let created = root["CreationDate"] as? Date,
              let expires = root["ExpirationDate"] as? Date,
              let ents = root["Entitlements"] as? [String: Any],
              let appID = ents["application-identifier"] as? String else {
            throw fail("incomplete provisioning profile")
        }
        let prefix = team + "."
        let bundleID = appID.hasPrefix(prefix) ? String(appID.dropFirst(prefix.count)) : appID
        let entData = try PropertyListSerialization.data(fromPropertyList: ents, format: .xml, options: 0)
        return ProvisioningProfile(uuid: uuid, teamID: team, bundleID: bundleID, creationDate: created,
                                   expirationDate: expires,
                                   deviceUDIDs: root["ProvisionedDevices"] as? [String] ?? [],
                                   entitlements: entData)
    }
}

public struct ProfileReader: Sendable {
    private let runner: CommandRunning

    public init(runner: CommandRunning) { self.runner = runner }

    public func read(_ url: URL) async throws -> ProvisioningProfile {
        let r = try await runner.run("/usr/bin/security", ["cms", "-D", "-i", url.path], cwd: nil)
        guard r.status == 0 else { throw XSideError.commandFailed(tool: "security", status: r.status) }
        return try ProvisioningProfile.parse(plist: r.stdout)
    }

    /// Reads every `*.mobileprovision` in the directories; missing directories and unreadable files are skipped.
    public func scan(_ directories: [URL]) async -> [ProvisioningProfile] {
        var result: [ProvisioningProfile] = []
        for dir in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files.filter({ $0.pathExtension == "mobileprovision" })
                .sorted(by: { $0.path < $1.path }) {
                if let p = try? await read(file) { result.append(p) }
            }
        }
        return result
    }
}
