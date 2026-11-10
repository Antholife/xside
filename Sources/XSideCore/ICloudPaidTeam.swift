import Foundation

/// The iCloud an app signed with a paid developer team asks for: its declared identifiers moved to
/// the team, as its bundle id is (`<original>.<TEAM>`). Asked of Xcode at provisioning (the
/// template's entitlements, `Provisioner`), then signed only as far as the profile grants it
/// (`ICloudPaidTeam.granted`). Set per job by the pipeline (`InstallOptions.paidTeamICloud`).
public struct ICloudRequest: Codable, Equatable, Sendable {
    /// `com.apple.developer.icloud-container-identifiers`, remapped.
    public var containers: [String]
    /// `com.apple.developer.icloud-services` (`ICloudSignedOut.knownServices`).
    public var services: [String]
    /// `com.apple.developer.ubiquity-container-identifiers` (iCloud Drive), remapped.
    public var ubiquityContainers: [String]
    /// `com.apple.developer.ubiquity-kvstore-identifier`: `<TEAM>.<signed id>`, nil without one.
    public var keyValueStore: String?

    public init(containers: [String], services: [String], ubiquityContainers: [String], keyValueStore: String?) {
        self.containers = containers
        self.services = services
        self.ubiquityContainers = ubiquityContainers
        self.keyValueStore = keyValueStore
    }

    /// The template target's entitlements: Xcode adds the iCloud capability and these containers
    /// to the App ID when it builds it with automatic signing.
    public var templateEntitlements: [String: Any] {
        var e: [String: Any] = [:]
        if !containers.isEmpty { e[ICloudPaidTeam.containersKey] = containers }
        if !services.isEmpty { e[ICloudPaidTeam.servicesKey] = services }
        if !ubiquityContainers.isEmpty { e[ICloudPaidTeam.ubiquityKey] = ubiquityContainers }
        if let keyValueStore { e[ICloudPaidTeam.kvstoreKey] = keyValueStore }
        return e
    }

    /// One line for the log (no identifier: they carry the team).
    public var summary: String {
        "\(containers.count) container(s), services [\(services.joined(separator: ", "))], "
            + "\(ubiquityContainers.count) iCloud Drive container(s), key-value store \(keyValueStore == nil ? "no" : "yes")"
    }
}

/// A paid developer team keeps the app's iCloud instead of dropping it (a free team can't have
/// it; there the signed-out iCloud option is the only fix). Free team: nothing here is used.
public enum ICloudPaidTeam {
    static let containersKey = "com.apple.developer.icloud-container-identifiers"
    static let servicesKey = "com.apple.developer.icloud-services"
    static let ubiquityKey = "com.apple.developer.ubiquity-container-identifiers"
    static let kvstoreKey = "com.apple.developer.ubiquity-kvstore-identifier"
    static let environmentKey = "com.apple.developer.icloud-container-environment"
    /// Every iCloud key of a profile or a signature: none passes through from the profile as is.
    public static let allKeys = ICloudSignedOut.entitlementKeys + [
        environmentKey, "com.apple.developer.icloud-container-development-container-identifiers",
    ]

    /// What `app` (its declared iCloud, read at import) asks for when signed as `bundleID` with
    /// `teamID`. Containers move to the app's own namespace: `iCloud.<original>[.rest]` becomes
    /// `iCloud.<bundleID>[.rest]`, any other `iCloud.<x>` becomes `iCloud.<bundleID>.<x>`. Never one
    /// of another XSide app (`otherBundleIDs`, their signed ids, and anything under theirs) nor one
    /// shaped like an app signed later (the team as a component past the app's own id). Services
    /// without what they need are dropped (CloudKit needs a container, Documents an iCloud Drive
    /// container). Nil when nothing is left: the app is signed without iCloud, as before.
    public static func request(app: ICloudAppInfo?, originalBundleID: String, bundleID: String, teamID: String,
                               otherBundleIDs: Set<String> = []) -> ICloudRequest? {
        guard let app, app.declaresICloud, !bundleID.isEmpty, !teamID.isEmpty else { return nil }
        func remap(_ ids: [String]) -> [String] {
            var result: [String] = []
            for id in ids {
                guard let mapped = remapContainer(id, originalBundleID: originalBundleID, bundleID: bundleID,
                                                  teamID: teamID, otherBundleIDs: otherBundleIDs),
                      !result.contains(mapped) else { continue }
                result.append(mapped)
            }
            return result
        }
        let containers = remap(app.containers)
        let ubiquity = remap(app.ubiquityContainers ?? [])
        // A record from before the services were read: CloudKit when it declared containers.
        let declared = app.services ?? (app.containers.isEmpty ? [] : ["CloudKit"])
        let services = ICloudSignedOut.knownServices.filter { service in
            declared.contains(service) && (service == "CloudKit" ? !containers.isEmpty : !ubiquity.isEmpty)
        }
        let kvstore = app.keyValueStore == true ? "\(teamID).\(bundleID)" : nil
        guard !containers.isEmpty || !ubiquity.isEmpty || kvstore != nil else { return nil }
        return ICloudRequest(containers: containers, services: services, ubiquityContainers: ubiquity, keyValueStore: kvstore)
    }

    static func remapContainer(_ id: String, originalBundleID: String, bundleID: String, teamID: String,
                               otherBundleIDs: Set<String>) -> String? {
        guard ICloudSignedOut.isValidContainer(id) else { return nil }
        let rest = String(id.dropFirst("iCloud.".count))
        let suffix: String
        if rest == originalBundleID {
            suffix = ""
        } else if !originalBundleID.isEmpty, rest.hasPrefix(originalBundleID + ".") {
            suffix = String(rest.dropFirst(originalBundleID.count))
        } else {
            suffix = "." + rest
        }
        // Past the app's own id, the team as a component is the shape of another XSide-signed id.
        if suffix.split(separator: ".").contains(where: { $0 == teamID[...] }) { return nil }
        let mapped = "iCloud.\(bundleID)\(suffix)"
        guard ICloudSignedOut.isValidContainer(mapped) else { return nil }
        for other in otherBundleIDs where mapped == "iCloud.\(other)" || mapped.hasPrefix("iCloud.\(other).") {
            return nil
        }
        return mapped
    }

    /// The iCloud entitlements to sign with: what `request` asks that the profile grants, each value
    /// matched exactly or by a trailing `*` (a profile grants `TEAM.*` for the key-value store and
    /// `*` for the services). Values of the wrong type grant nothing. With a container kept, the
    /// development CloudKit environment when the profile allows it.
    public static func granted(_ request: ICloudRequest, profile: [String: Any]) -> [String: Any] {
        func patterns(_ key: String) -> [String] {
            switch profile[key] {
            case let text as String: return [text]
            case let list as [Any]: return list.compactMap { $0 as? String }
            default: return []
            }
        }
        func allows(_ key: String, _ value: String) -> Bool {
            patterns(key).contains { p in p == value || (p.hasSuffix("*") && value.hasPrefix(p.dropLast())) }
        }
        func lists(_ key: String) -> Bool { profile[key] is [Any] }
        var result: [String: Any] = [:]
        let containers = lists(containersKey) ? request.containers.filter { allows(containersKey, $0) } : []
        let ubiquity = lists(ubiquityKey) ? request.ubiquityContainers.filter { allows(ubiquityKey, $0) } : []
        let services = request.services.filter { service in
            allows(servicesKey, service) && (service == "CloudKit" ? !containers.isEmpty : !ubiquity.isEmpty)
        }
        if !containers.isEmpty { result[containersKey] = containers }
        if !services.isEmpty { result[servicesKey] = services }
        if !ubiquity.isEmpty { result[ubiquityKey] = ubiquity }
        if let kvs = request.keyValueStore, profile[kvstoreKey] is String, allows(kvstoreKey, kvs) { result[kvstoreKey] = kvs }
        if !containers.isEmpty, allows(environmentKey, "Development") { result[environmentKey] = "Development" }
        return result
    }
}
