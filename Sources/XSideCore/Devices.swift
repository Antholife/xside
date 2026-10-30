import Foundation

public enum DeviceKind: String, Codable, Sendable { case iPhone, iPad, other }
public enum Transport: String, Codable, Sendable { case usb, network, none }

public struct Device: Identifiable, Equatable, Codable, Sendable {
    /// CoreDevice identifier (the value `devicectl --device` expects).
    public let id: String
    public let udid: String?
    public let name: String
    public let model: String
    public let kind: DeviceKind
    public let transport: Transport
    public let isPaired: Bool
    public let isAvailable: Bool
    public let developerModeEnabled: Bool?
    /// iOS / iPadOS version ("26.1").
    public let osVersion: String?

    public init(id: String, udid: String?, name: String, model: String, kind: DeviceKind,
                transport: Transport, isPaired: Bool, isAvailable: Bool, developerModeEnabled: Bool?,
                osVersion: String? = nil) {
        self.id = id; self.udid = udid; self.name = name; self.model = model; self.kind = kind
        self.transport = transport; self.isPaired = isPaired; self.isAvailable = isAvailable
        self.developerModeEnabled = developerModeEnabled; self.osVersion = osVersion
    }
}

/// devicectl raw values -> model values. Single place to correct once real
/// captures of connected devices are available (some values are assumed).
enum DevicectlValues {
    static let reachableTransports: [String: Transport] = ["wired": .usb, "localNetwork": .network]
    static let simulatedReality = "simulated"
    static let pairedState = "paired"
    static let unavailableTunnel = "unavailable"
    static let developerModeEnabled = "enabled"

    static func transport(_ raw: String?) -> Transport {
        raw.flatMap { reachableTransports[$0] } ?? .none
    }
}

public struct DeviceService: Sendable {
    let runner: CommandRunning

    public init(runner: CommandRunning) { self.runner = runner }

    private struct Root: Decodable {
        struct Result: Decodable { let devices: [Raw] }
        let result: Result
    }
    private struct Raw: Decodable {
        struct Conn: Decodable { let pairingState: String?; let tunnelState: String?; let transportType: String? }
        struct Props: Decodable { let name: String?; let developerModeStatus: String?; let osVersionNumber: String? }
        struct HW: Decodable { let deviceType: String?; let marketingName: String?; let productType: String?; let udid: String?; let reality: String? }
        let identifier: String
        let connectionProperties: Conn?
        let deviceProperties: Props?
        let hardwareProperties: HW?
    }

    public static func parse(_ json: Data) throws -> [Device] {
        let root = try JSONDecoder().decode(Root.self, from: json)
        return root.result.devices.compactMap { raw in
            let hw = raw.hardwareProperties
            if hw?.reality == DevicectlValues.simulatedReality { return nil }
            let conn = raw.connectionProperties
            let transport = DevicectlValues.transport(conn?.transportType)
            let paired = conn?.pairingState == DevicectlValues.pairedState
            let available = paired && transport != .none && conn?.tunnelState != DevicectlValues.unavailableTunnel
            // Right after a first pairing `deviceType` can be missing; `productType` ("iPhone18,2") still tells.
            let kindHint = hw?.deviceType ?? hw?.productType ?? ""
            let kind: DeviceKind = kindHint.hasPrefix("iPhone") ? .iPhone : kindHint.hasPrefix("iPad") ? .iPad : .other
            return Device(
                id: raw.identifier,
                udid: hw?.udid,
                name: raw.deviceProperties?.name ?? hw?.marketingName ?? raw.identifier,
                model: hw?.marketingName ?? hw?.productType ?? "",
                kind: kind,
                transport: transport,
                isPaired: paired,
                isAvailable: available,
                developerModeEnabled: raw.deviceProperties?.developerModeStatus.map { $0 == DevicectlValues.developerModeEnabled },
                osVersion: raw.deviceProperties?.osVersionNumber)
        }
    }

    public func list() async throws -> [Device] {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("xside-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let r = try await runner.run("/usr/bin/xcrun",
                                     ["devicectl", "list", "devices", "--json-output", file.path], cwd: nil,
                                     timeout: CommandTimeout.deviceQuery)
        guard r.status == 0 else { throw XSideError.commandFailed(tool: "devicectl", status: r.status) }
        return try Self.parse(try Data(contentsOf: file))
    }

    public func pair(_ id: String) async throws {
        let r = try await runner.run("/usr/bin/xcrun", ["devicectl", "manage", "pair", "--device", id], cwd: nil,
                                     timeout: CommandTimeout.deviceQuery)
        guard r.status == 0 else { throw XSideError.deviceUnavailable }
    }
}
