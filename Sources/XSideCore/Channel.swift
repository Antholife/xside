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
// - nonce: 1 to 64 characters from [A-Za-z0-9_-]; anything else is rejected.
// - base64 everywhere (body, mac) is canonical standard base64 with padding and no line breaks.
// - Accepted: valid MAC, |now - timestamp| <= 120 s, nonce not seen within the cache lifetime
//   (per installation).
//
// Reply line = ChannelReplyEnvelope, authenticated with the same secret and bound to the request:
//   {"installationID":"...","nonce":"<the request's nonce>","body":"<base64 of the reply JSON>",
//    "mac":"<base64>"}
//   mac = HMAC-SHA256 over the UTF-8 string  "reply|" + installationID + "|" + nonce + "|" + base64(body)
// The "reply|" prefix keeps a reply MAC from ever being a valid request MAC. The phone must check
// the MAC, the installation id and that the nonce is the one it sent before applying a reply.
//
// JSON conventions inside bodies and replies: objects use a "type" discriminator and flat fields;
// dates are integer epoch milliseconds (1800000000000); nils are omitted.
//   ChannelRequest: {"type":"refresh"} | {"type":"setAutoRefresh","on":true}
//                 | {"type":"checkIn","settings":{...},"lastRefresh":{...},"appVersion":"1.2"}
//   ChannelReply:   {"type":"settings","settings":{...}} | {"type":"accepted"} | {"type":"refreshed"}
//                 | {"type":"failed","reasonKey":"..."} | {"type":"busy"} | {"type":"deviceUnreachable"}
//                 | {"type":"paused","by":"mac"|"device"} | {"type":"rejected"}
//
// Exchanges (XSide's side: ChannelHandler, ChannelServer). One request per connection; XSide
// closes the connection after its last line.
// - checkIn -> settings(merged): the phone's settings merged with the Mac's, field by field (dates
//   more than 120 s ahead of the Mac's clock count as "now"). The phone adopts them.
// - setAutoRefresh(on) -> settings(...): the installation's settings with autoRefresh stamped by
//   the device; the Mac pauses or resumes its refreshes.
// - refresh -> TWO lines when it starts: `accepted` at once, then `refreshed` or
//   `failed(reasonKey)` when the job ends (the connection stays open up to 2 min; after that it is
//   closed without the second line, and the success closes the app anyway). One line when it
//   can't start: `paused(by)` (automatic refresh off for this installation), `busy` (a job is
//   already running on it), `deviceUnreachable` (the Mac can't see the device), or
//   `failed(reasonKey)` (e.g. Xcode isn't usable).
// - A request that doesn't authenticate (unknown installation id, wrong MAC, outside the window,
//   replayed nonce, unreadable body) gets the bare, UNSIGNED line `{"type":"rejected"}` (not an
//   envelope: nothing is ever signed for an unauthenticated request). The phone must not act on it
//   beyond "this Mac doesn't know me" (e.g. try another XSide on the network, or report it).
// - A line that isn't an envelope at all, longer than 64 KB, or not complete within 10 s: the
//   connection is closed without a reply.

public enum ChannelError: Error, Equatable { case invalidNonce, invalidTimestamp }

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

    /// The reply body bytes (what a `ChannelReplyEnvelope` signs).
    public func encodedBody() throws -> Data {
        try JSONEncoder.channel.encode(self)
    }

    public static func decode(body: Data) throws -> ChannelReply {
        try JSONDecoder.channel.decode(ChannelReply.self, from: body)
    }
}

/// Latest accepted date: year 3000 (UTC), in epoch milliseconds.
let channelMaxMillis: Int64 = 32_503_680_000_000

/// Epoch milliseconds of `date`, or nil if it is not finite or outside 1970...3000. Encoding
/// throws (rather than clamps) on nil, and the same range is enforced when decoding, so untrusted
/// values can never reach a trapping Double-to-Int64 conversion.
func channelMillis(_ date: Date) -> Int64? {
    let ms = (date.timeIntervalSince1970 * 1000).rounded()
    guard ms.isFinite, ms >= 0, ms <= Double(channelMaxMillis) else { return nil }
    return Int64(ms)
}

extension JSONEncoder {
    /// Sorted keys and unescaped slashes (stable, compact output); dates as integer epoch
    /// milliseconds (keeps sub-millisecond-free ordering and is trivial in Objective-C). Only the
    /// channel uses this coder; state.json keeps its own date strategy.
    static var channel: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            guard let ms = channelMillis(date) else {
                throw EncodingError.invalidValue(date, .init(codingPath: enc.codingPath, debugDescription: "date outside 1970...3000"))
            }
            try c.encode(ms)
        }
        return e
    }
}

extension JSONDecoder {
    static var channel: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let ms = try c.decode(Int64.self)
            guard (0...channelMaxMillis).contains(ms) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "date outside 1970...3000")
            }
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        return d
    }
}

/// Recently seen (installation, nonce) pairs, so a captured request cannot be replayed. Bounded
/// and fail-closed: an entry is never evicted while it can still matter, so when the cache is full
/// of live entries new requests are refused instead.
public struct NonceCache: Sendable {
    /// A nonce stays valid for replay while its timestamp is within +-120 s of "now", i.e. up to
    /// 240 s after it was first accepted (future-dated request); 300 s leaves a margin.
    static let lifetime: TimeInterval = 300
    private struct Key: Hashable, Sendable { var installationID: String; var nonce: String }
    private var entries: [Key: Date] = [:]
    private let capacity: Int

    public init(capacity: Int = 512) { self.capacity = max(1, capacity) }

    public var count: Int { entries.count }

    /// Records the pair and returns true; false if it was already seen or the cache is full of
    /// live entries. Only called after the MAC verified, so unauthenticated traffic cannot fill it.
    public mutating func insert(_ nonce: String, installationID: String, at now: Date) -> Bool {
        entries = entries.filter { now.timeIntervalSince($0.value) <= Self.lifetime }
        let key = Key(installationID: installationID, nonce: nonce)
        if entries[key] != nil || entries.count >= capacity { return false }
        entries[key] = now
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

    /// 1-64 characters from [A-Za-z0-9_-].
    static func isValidNonce(_ n: String) -> Bool {
        (1...64).contains(n.utf8.count) && n.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }

    static func encodeBody(_ request: ChannelRequest) throws -> Data {
        try JSONEncoder.channel.encode(request)
    }

    public static func seal(_ request: ChannelRequest, installationID: String, secret: Data,
                            now: Date, nonce: String) throws -> ChannelEnvelope {
        guard let ms = channelMillis(now) else { throw ChannelError.invalidTimestamp }
        return try seal(request, installationID: installationID, secret: secret,
                        timestampMillis: ms, nonce: nonce)
    }

    static func seal(_ request: ChannelRequest, installationID: String, secret: Data,
                     timestampMillis: Int64, nonce: String) throws -> ChannelEnvelope {
        guard isValidNonce(nonce) else { throw ChannelError.invalidNonce }
        let body = try encodeBody(request)
        let mac = computeMAC(secret: secret, installationID: installationID, timestamp: timestampMillis,
                             nonce: nonce, body: body)
        return ChannelEnvelope(installationID: installationID, timestamp: timestampMillis, nonce: nonce,
                               body: body, mac: mac)
    }

    /// The request if the MAC is valid, the timestamp is within the window and the nonce is new;
    /// nil otherwise. The nonce is recorded only on success.
    public func open(secret: Data, now: Date, seen: inout NonceCache) -> ChannelRequest? {
        guard Self.isValidNonce(nonce) else { return nil }
        let expected = Self.computeMAC(secret: secret, installationID: installationID, timestamp: timestamp,
                                       nonce: nonce, body: body)
        guard Self.constantTimeEqual(expected, mac) else { return nil }
        guard let nowMillis = channelMillis(now) else { return nil }
        let (diff, overflow) = nowMillis.subtractingReportingOverflow(timestamp)
        guard !overflow, diff != .min, abs(diff) <= Int64(Self.window * 1000) else { return nil }
        guard let request = try? JSONDecoder.channel.decode(ChannelRequest.self, from: body) else { return nil }
        guard seen.insert(nonce, installationID: installationID, at: now) else { return nil }
        return request
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
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

/// XSide's authenticated reply frame, bound to the request it answers (see the wire format).
public struct ChannelReplyEnvelope: Codable, Equatable, Sendable {
    public var installationID: String
    /// The nonce of the request being answered.
    public var nonce: String
    public var body: Data
    public var mac: Data

    public init(installationID: String, nonce: String, body: Data, mac: Data) {
        self.installationID = installationID
        self.nonce = nonce
        self.body = body
        self.mac = mac
    }

    /// The exact bytes signed: `reply|installationID|requestNonce|base64(body)`.
    static func signedString(installationID: String, nonce: String, body: Data) -> Data {
        Data("reply|\(installationID)|\(nonce)|\(body.base64EncodedString())".utf8)
    }

    static func computeMAC(secret: Data, installationID: String, nonce: String, body: Data) -> Data {
        let msg = signedString(installationID: installationID, nonce: nonce, body: body)
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: secret)))
    }

    public static func seal(_ reply: ChannelReply, installationID: String, requestNonce: String,
                            secret: Data) throws -> ChannelReplyEnvelope {
        guard ChannelEnvelope.isValidNonce(requestNonce) else { throw ChannelError.invalidNonce }
        let body = try reply.encodedBody()
        return ChannelReplyEnvelope(installationID: installationID, nonce: requestNonce, body: body,
                                    mac: computeMAC(secret: secret, installationID: installationID,
                                                    nonce: requestNonce, body: body))
    }

    /// The reply if the MAC is valid and the envelope answers `expectedNonce` for
    /// `expectedInstallationID`; nil otherwise.
    public func open(secret: Data, expectedInstallationID: String, expectedNonce: String) -> ChannelReply? {
        guard installationID == expectedInstallationID, nonce == expectedNonce else { return nil }
        let expected = Self.computeMAC(secret: secret, installationID: installationID, nonce: nonce, body: body)
        guard ChannelEnvelope.constantTimeEqual(expected, mac) else { return nil }
        return try? ChannelReply.decode(body: body)
    }

    public func encodedLine() throws -> Data {
        try JSONEncoder.channel.encode(self) + Data([0x0A])
    }

    public static func decode(line: Data) throws -> ChannelReplyEnvelope {
        try JSONDecoder.channel.decode(ChannelReplyEnvelope.self, from: line)
    }
}
