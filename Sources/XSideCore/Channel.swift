import Foundation
import CryptoKit

// MARK: - Wire format (the iOS dylib implements the same, byte for byte)
//
// Transport: TCP to the Bonjour service `_xside._tcp`. One request line, one reply line; each line
// is one JSON object terminated by "\n" (0x0A). JSON never contains a raw newline.
//
// Request line = ChannelEnvelope:
//   {"installationID":"<recordUUID>|<deviceID>","timestamp":1800000000000,"nonce":"n1",
//    "body":"<base64 of the body bytes>","mac":"<base64 of 32 bytes>"}
// - timestamp: integer milliseconds since 1970 (an integer, not a Date, to avoid float drift).
// - body: base64 of the UTF-8 JSON of a ChannelRequest. The MAC covers these exact bytes; the
//   receiver never re-encodes them.
// - mac: HMAC-SHA256, key = the installation's 32-byte secret, over the UTF-8 string
//       installationID + "|" + timestampMillis + "|" + nonce + "|" + base64(body)
//   with timestampMillis in plain decimal digits and base64 in the standard alphabet with padding.
//   (installationID itself contains a "|", which is fine: the string is only ever built by the
//   sender and rebuilt from the same four fields by the receiver.)
// - Accepted: valid MAC, |now - timestamp| <= 120 s, nonce not seen within the cache lifetime.
//
// JSON conventions inside bodies and replies: objects use a "type" discriminator and flat fields;
// dates are ISO 8601 UTC with whole seconds ("2026-11-08T10:00:00Z"); nils are omitted.
//   ChannelRequest: {"type":"refresh"} | {"type":"setAutoRefresh","on":true}
//                 | {"type":"checkIn","settings":{...},"lastRefresh":{...},"appVersion":"1.2"}
//   ChannelReply:   {"type":"settings","settings":{...}} | {"type":"accepted"} | {"type":"refreshed"}
//                 | {"type":"failed","reasonKey":"..."} | {"type":"busy"} | {"type":"deviceUnreachable"}
//                 | {"type":"paused","by":"mac"|"device"} | {"type":"rejected"}
// A reply is not authenticated; it carries nothing a network observer could use to act on the
// installation, and the phone only trusts it to display state.

/// A request from the app to XSide.
public enum ChannelRequest: Codable, Equatable, Sendable {
    /// Sent at each launch: the phone's settings and last refresh result; the Mac answers with
    /// the merged settings.
    case checkIn(settings: InAppSettings, lastRefresh: RefreshOutcome?, appVersion: String?)
    /// "Refresh now" from the phone.
    case refresh
    /// Pause (`false`) or resume (`true`) automatic refresh for this installation.
    case setAutoRefresh(Bool)

    private enum CodingKeys: String, CodingKey { case type, settings, lastRefresh, appVersion, on }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "checkIn":
            self = .checkIn(settings: try c.decode(InAppSettings.self, forKey: .settings),
                            lastRefresh: try c.decodeIfPresent(RefreshOutcome.self, forKey: .lastRefresh),
                            appVersion: try c.decodeIfPresent(String.self, forKey: .appVersion))
        case "refresh": self = .refresh
        case "setAutoRefresh": self = .setAutoRefresh(try c.decode(Bool.self, forKey: .on))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown request \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .checkIn(settings, lastRefresh, appVersion):
            try c.encode("checkIn", forKey: .type)
            try c.encode(settings, forKey: .settings)
            try c.encodeIfPresent(lastRefresh, forKey: .lastRefresh)
            try c.encodeIfPresent(appVersion, forKey: .appVersion)
        case .refresh: try c.encode("refresh", forKey: .type)
        case let .setAutoRefresh(on):
            try c.encode("setAutoRefresh", forKey: .type)
            try c.encode(on, forKey: .on)
        }
    }
}

/// XSide's answer to a request.
public enum ChannelReply: Codable, Equatable, Sendable {
    case settings(InAppSettings)
    /// Refresh queued; the app will be replaced, so it closes.
    case accepted
    case refreshed
    case failed(reasonKey: String)
    case busy
    case deviceUnreachable
    /// Automatic refresh is paused, by the Mac or by the device.
    case paused(by: ChangeOrigin)
    case rejected

    private enum CodingKeys: String, CodingKey { case type, settings, reasonKey, by }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "settings": self = .settings(try c.decode(InAppSettings.self, forKey: .settings))
        case "accepted": self = .accepted
        case "refreshed": self = .refreshed
        case "failed": self = .failed(reasonKey: try c.decode(String.self, forKey: .reasonKey))
        case "busy": self = .busy
        case "deviceUnreachable": self = .deviceUnreachable
        case "paused": self = .paused(by: try c.decode(ChangeOrigin.self, forKey: .by))
        case "rejected": self = .rejected
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown reply \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .settings(s):
            try c.encode("settings", forKey: .type)
            try c.encode(s, forKey: .settings)
        case .accepted: try c.encode("accepted", forKey: .type)
        case .refreshed: try c.encode("refreshed", forKey: .type)
        case let .failed(key):
            try c.encode("failed", forKey: .type)
            try c.encode(key, forKey: .reasonKey)
        case .busy: try c.encode("busy", forKey: .type)
        case .deviceUnreachable: try c.encode("deviceUnreachable", forKey: .type)
        case let .paused(by):
            try c.encode("paused", forKey: .type)
            try c.encode(by, forKey: .by)
        case .rejected: try c.encode("rejected", forKey: .type)
        }
    }

    /// One reply as a newline-terminated JSON line.
    public func encodedLine() throws -> Data {
        try JSONEncoder.channel.encode(self) + Data([0x0A])
    }

    public static func decode(line: Data) throws -> ChannelReply {
        try JSONDecoder.channel.decode(ChannelReply.self, from: line)
    }
}

extension JSONEncoder {
    /// Sorted keys and unescaped slashes (stable, compact output); ISO 8601 dates.
    static var channel: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var channel: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Recently seen nonces, so a captured request cannot be replayed. Bounded; entries expire after
/// `lifetime`.
public struct NonceCache: Sendable {
    /// A nonce stays valid for replay while its timestamp is within +-120 s of "now", i.e. up to
    /// 240 s after it was first accepted (future-dated request); 300 s leaves a margin.
    static let lifetime: TimeInterval = 300
    private var entries: [(nonce: String, at: Date)] = []
    private let capacity: Int

    public init(capacity: Int = 512) { self.capacity = max(1, capacity) }

    public var count: Int { entries.count }

    /// Records `nonce` and returns true, or returns false if it was already seen. Only called
    /// after the MAC verified, so unauthenticated traffic cannot evict real nonces.
    public mutating func insert(_ nonce: String, at now: Date) -> Bool {
        entries.removeAll { now.timeIntervalSince($0.at) > Self.lifetime }
        if entries.contains(where: { $0.nonce == nonce }) { return false }
        entries.append((nonce, now))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        return true
    }
}

/// The authenticated request frame (see the wire format above).
public struct ChannelEnvelope: Codable, Equatable, Sendable {
    public var installationID: String
    /// Milliseconds since 1970.
    public var timestamp: Int64
    public var nonce: String
    /// UTF-8 JSON of a `ChannelRequest` (base64 on the wire, signed as received).
    public var body: Data
    /// HMAC-SHA256 (base64 on the wire).
    public var mac: Data

    /// Accepted clock difference between the phone and the Mac, in either direction.
    public static let window: TimeInterval = 120

    public init(installationID: String, timestamp: Int64, nonce: String, body: Data, mac: Data) {
        self.installationID = installationID
        self.timestamp = timestamp
        self.nonce = nonce
        self.body = body
        self.mac = mac
    }

    /// The exact bytes that are signed: `installationID|timestampMillis|nonce|base64(body)`.
    static func signedString(installationID: String, timestamp: Int64, nonce: String, body: Data) -> Data {
        Data("\(installationID)|\(timestamp)|\(nonce)|\(body.base64EncodedString())".utf8)
    }

    static func computeMAC(secret: Data, installationID: String, timestamp: Int64, nonce: String, body: Data) -> Data {
        let msg = signedString(installationID: installationID, timestamp: timestamp, nonce: nonce, body: body)
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: secret)))
    }

    static func encodeBody(_ request: ChannelRequest) throws -> Data {
        try JSONEncoder.channel.encode(request)
    }

    public static func seal(_ request: ChannelRequest, installationID: String, secret: Data,
                            now: Date, nonce: String) throws -> ChannelEnvelope {
        try seal(request, installationID: installationID, secret: secret,
                 timestampMillis: Int64((now.timeIntervalSince1970 * 1000).rounded()), nonce: nonce)
    }

    static func seal(_ request: ChannelRequest, installationID: String, secret: Data,
                     timestampMillis: Int64, nonce: String) throws -> ChannelEnvelope {
        let body = try encodeBody(request)
        let mac = computeMAC(secret: secret, installationID: installationID, timestamp: timestampMillis,
                             nonce: nonce, body: body)
        return ChannelEnvelope(installationID: installationID, timestamp: timestampMillis, nonce: nonce,
                               body: body, mac: mac)
    }

    /// The request if the MAC is valid, the timestamp is within the window and the nonce is new;
    /// nil otherwise. The nonce is recorded only on success.
    public func open(secret: Data, now: Date, seen: inout NonceCache) -> ChannelRequest? {
        let expected = Self.computeMAC(secret: secret, installationID: installationID, timestamp: timestamp,
                                       nonce: nonce, body: body)
        guard Self.constantTimeEqual(expected, mac) else { return nil }
        let nowMillis = Int64((now.timeIntervalSince1970 * 1000).rounded())
        guard abs(nowMillis - timestamp) <= Int64(Self.window * 1000) else { return nil }
        guard let request = try? JSONDecoder.channel.decode(ChannelRequest.self, from: body) else { return nil }
        guard seen.insert(nonce, at: now) else { return nil }
        return request
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// 32 random bytes: the per-installation secret.
    public static func newSecret() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
    }

    /// `<record UUID>|<device id>`.
    public static func installationID(recordID: UUID, deviceID: String) -> String {
        "\(recordID.uuidString)|\(deviceID)"
    }

    /// The envelope as a newline-terminated JSON line.
    public func encodedLine() throws -> Data {
        try JSONEncoder.channel.encode(self) + Data([0x0A])
    }

    public static func decode(line: Data) throws -> ChannelEnvelope {
        try JSONDecoder.channel.decode(ChannelEnvelope.self, from: line)
    }
}
