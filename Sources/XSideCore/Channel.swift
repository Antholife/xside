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
//                 | {"type":"checkIn","settings":{...},"lastRefresh":{...},"appVersion":"1.2","pollEvery":45}
//                 | {"type":"watch","settings":{...},"lastRefresh":{...},"appVersion":"1.2"}
//   ChannelReply:   {"type":"settings","settings":{...},"lastRefresh":{...},"pausedUntil":1800000000000} | {"type":"accepted"} | {"type":"refreshed"}
//                 | {"type":"failed","reasonKey":"..."} | {"type":"busy"} | {"type":"deviceUnreachable"}
//                 | {"type":"paused","by":"mac"|"device"} | {"type":"rejected"}
//                 | {"type":"live","seq":1,"settings":{...},"lastRefresh":{...},"pausedUntil":...} | {"type":"alive","seq":2}
//
// Exchanges (XSide's side: ChannelHandler, ChannelServer). One request per connection; XSide
// closes the connection after its last line.
// - checkIn -> settings(merged, lastRefresh): the phone's settings merged with the Mac's, field by
//   field (dates more than 120 s ahead of the Mac's clock count as "now"). The phone adopts them.
//   lastRefresh (optional, omitted when unknown; same shape as in checkIn) is the newest refresh
//   outcome XSide knows for the installation, so a phone that was suspended while a refresh it
//   asked for ended still learns how it went.
//   pausedUntil (optional, a date like the others, on `settings` and `live`): when the Mac paused
//   the app's refreshes for a while (Pause > 2 h, `xside pause <app> 1d`), when that pause ends by
//   itself; omitted for a pause until resumed and when not paused. The phone only says it in its
//   pill (review D–G, minor 7); older dylibs ignore it.
//   pollEvery (optional, whole seconds, inside the signed body like every field): the phone's
//   foreground poll interval (15, 45 in Low Power Mode), sent while it is in front. The Mac only
//   uses it to keep "open, live" until the next poll (counted 15 to 120 s, plus a 10 s margin;
//   ReachabilityStatus.openWindow); it grants nothing, and a missing one counts as 15 s.
// - setAutoRefresh(on) -> settings(...): the installation's settings with autoRefresh stamped by
//   the device; the Mac pauses or resumes its refreshes.
// - refresh -> TWO lines when it starts: `accepted` at once, then `refreshed` or
//   `failed(reasonKey)` when the job ends (the connection stays open up to 2 min; after that it is
//   closed without the second line, and the success closes the app anyway). One line when it
//   can't start: `paused(by)` (automatic refresh off for this installation), `busy` (a job is
//   already running on it, or the phone's own previous refresh request started less than 10
//   minutes ago, a date XSide keeps and nothing the phone sends resets; XSide's own attempts
//   don't count), `deviceUnreachable` (the Mac can't see the device), or
//   `failed(reasonKey)` (e.g. Xcode isn't usable). reasonKey is an XSideError key, "cancelled"
//   when the person stopped the job on the Mac, or "unknown".
// - watch -> the check-in's `settings` reply at once (the request is a check-in: same fields, same
//   merge, same storage), then the connection stays open while the app is in front, and XSide
//   writes on it, without being asked again (device feedback 4: live, not every 15 s):
//     `live(seq, settings, lastRefresh)` as soon as the installation's stored settings (pause
//       included: it is the automatic-refresh setting) or refresh outcome change on the Mac;
//     `alive(seq)` when nothing was written for 25 s, so the phone can tell a dead connection.
//   Every line is a ChannelReplyEnvelope signed like any reply, with the watch request's nonce;
//   `seq` counts 1, 2, 3… on the connection and the phone takes only the next one, so a line can't
//   be replayed, dropped or reordered on the connection unseen, nor carried to another one (other
//   nonce). The phone checks every line (MAC, installation, nonce, next seq) and closes the watch
//   at the first one that fails. Only an authenticated `watch` is ever kept open (anything else is
//   answered and closed as below); one watch per installation (a newer one replaces it), at most
//   2 per address and 8 in all (beyond that it is answered like a check-in and closed: the phone
//   polls instead); XSide closes it after 5 min and the phone opens another; the phone closes it
//   when the app leaves the foreground. A phone writing anything more on a watch is closed.
// - A request that doesn't authenticate (unknown installation id, wrong MAC, outside the window,
//   replayed nonce, unreadable body) gets the bare, UNSIGNED line `{"type":"rejected"}` (not an
//   envelope: nothing is ever signed for an unauthenticated request). The phone must not act on it
//   beyond "this Mac doesn't know me" (e.g. try another XSide on the network, or report it).
// - A line that isn't an envelope at all, longer than 64 KB, or not complete within 10 s: the
//   connection is closed without a reply. Connections beyond 4 at once or 20 a minute from one
//   address (16 in all) are dropped without a reply too.

public enum ChannelError: Error, Equatable { case invalidNonce, invalidTimestamp }

/// A request from the app to XSide.
public enum ChannelRequest: Codable, Equatable, Sendable {
    /// Sent at each launch and, while the app is in front without a watch, every `pollEvery`
    /// seconds: the phone's settings and last refresh result; the Mac answers with the merged
    /// settings. `pollEvery` (optional, whole seconds; older dylibs omit it): how long until the
    /// phone's next poll (15 s, 45 s in Low Power Mode), so the Mac keeps saying "open, live"
    /// until then (device feedback 5, G3). Only the status line reads it.
    case checkIn(settings: InAppSettings, lastRefresh: RefreshOutcome?, appVersion: String?, pollEvery: Int? = nil)
    /// "Refresh now" from the phone.
    case refresh
    /// Pause (`false`) or resume (`true`) automatic refresh for this installation.
    case setAutoRefresh(Bool)
    /// A check-in that keeps the connection open while the app is in front: the Mac's changes are
    /// written on it as they happen (`ChannelReply.live`).
    case watch(settings: InAppSettings, lastRefresh: RefreshOutcome?, appVersion: String?)

    private enum CodingKeys: String, CodingKey { case type, settings, lastRefresh, appVersion, pollEvery, on }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "checkIn":
            self = .checkIn(settings: try c.decode(InAppSettings.self, forKey: .settings),
                            lastRefresh: try c.decodeIfPresent(RefreshOutcome.self, forKey: .lastRefresh),
                            appVersion: try c.decodeIfPresent(String.self, forKey: .appVersion),
                            pollEvery: try c.decodeIfPresent(Int.self, forKey: .pollEvery))
        case "watch":
            self = .watch(settings: try c.decode(InAppSettings.self, forKey: .settings),
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
        case let .checkIn(settings, lastRefresh, appVersion, pollEvery):
            try c.encode("checkIn", forKey: .type)
            try c.encode(settings, forKey: .settings)
            try c.encodeIfPresent(lastRefresh, forKey: .lastRefresh)
            try c.encodeIfPresent(appVersion, forKey: .appVersion)
            try c.encodeIfPresent(pollEvery, forKey: .pollEvery)
        case let .watch(settings, lastRefresh, appVersion):
            try c.encode("watch", forKey: .type)
            try c.encode(settings, forKey: .settings)
            try c.encodeIfPresent(lastRefresh, forKey: .lastRefresh)
            try c.encodeIfPresent(appVersion, forKey: .appVersion)
        case .refresh: try c.encode("refresh", forKey: .type)
        case let .setAutoRefresh(on):
            try c.encode("setAutoRefresh", forKey: .type)
            try c.encode(on, forKey: .on)
        }
    }

    /// What a check-in or a watch reports (both are check-ins), nil for the other requests.
    public var checkInReport: (settings: InAppSettings, lastRefresh: RefreshOutcome?)? {
        switch self {
        case let .checkIn(settings, lastRefresh, _, _), let .watch(settings, lastRefresh, _): (settings, lastRefresh)
        case .refresh, .setAutoRefresh: nil
        }
    }

    /// The phone's poll interval a check-in states (device feedback 5, G3), nil for the other
    /// requests and for dylibs that don't say it.
    public var pollEvery: Int? {
        if case let .checkIn(_, _, _, pollEvery) = self { return pollEvery }
        return nil
    }
}

/// XSide's answer to a request.
public enum ChannelReply: Codable, Equatable, Sendable {
    /// The installation's settings and, when known, its newest refresh outcome.
    /// `pausedUntil`: the end of a pause of a while made on the Mac (see the header).
    case settings(InAppSettings, lastRefresh: RefreshOutcome? = nil, pausedUntil: Date? = nil)
    /// Refresh queued; the app will be replaced, so it closes.
    case accepted
    case refreshed
    case failed(reasonKey: String)
    case busy
    case deviceUnreachable
    /// Automatic refresh is paused, by the Mac or by the device.
    case paused(by: ChangeOrigin)
    case rejected
    /// On a watch: the installation's settings and newest refresh outcome changed on the Mac.
    /// `seq`: this line's number on the connection (1, 2, 3…, shared with `alive`).
    case live(seq: Int, InAppSettings, lastRefresh: RefreshOutcome? = nil, pausedUntil: Date? = nil)
    /// On a watch: nothing to say for a while, the connection is alive.
    case alive(seq: Int)

    private enum CodingKeys: String, CodingKey { case type, settings, lastRefresh, reasonKey, by, seq, pausedUntil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "settings":
            self = .settings(try c.decode(InAppSettings.self, forKey: .settings),
                             lastRefresh: try c.decodeIfPresent(RefreshOutcome.self, forKey: .lastRefresh),
                             pausedUntil: try c.decodeIfPresent(Date.self, forKey: .pausedUntil))
        case "accepted": self = .accepted
        case "refreshed": self = .refreshed
        case "failed": self = .failed(reasonKey: try c.decode(String.self, forKey: .reasonKey))
        case "busy": self = .busy
        case "deviceUnreachable": self = .deviceUnreachable
        case "paused": self = .paused(by: try c.decode(ChangeOrigin.self, forKey: .by))
        case "rejected": self = .rejected
        case "live":
            self = .live(seq: try c.decode(Int.self, forKey: .seq), try c.decode(InAppSettings.self, forKey: .settings),
                         lastRefresh: try c.decodeIfPresent(RefreshOutcome.self, forKey: .lastRefresh),
                         pausedUntil: try c.decodeIfPresent(Date.self, forKey: .pausedUntil))
        case "alive": self = .alive(seq: try c.decode(Int.self, forKey: .seq))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown reply \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .settings(s, lastRefresh, pausedUntil):
            try c.encode("settings", forKey: .type)
            try c.encode(s, forKey: .settings)
            try c.encodeIfPresent(lastRefresh, forKey: .lastRefresh)
            try c.encodeIfPresent(pausedUntil, forKey: .pausedUntil)
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
        case let .live(seq, s, lastRefresh, pausedUntil):
            try c.encode("live", forKey: .type)
            try c.encode(seq, forKey: .seq)
            try c.encode(s, forKey: .settings)
            try c.encodeIfPresent(lastRefresh, forKey: .lastRefresh)
            try c.encodeIfPresent(pausedUntil, forKey: .pausedUntil)
        case let .alive(seq):
            try c.encode("alive", forKey: .type)
            try c.encode(seq, forKey: .seq)
        }
    }

    /// The line number of a watch line (`live`, `alive`), nil for the other replies.
    public var watchSeq: Int? {
        switch self {
        case let .live(seq, _, _, _), let .alive(seq): seq
        default: nil
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

/// The phone's side of a watch, in Swift (the dylib's is `XSOpenWatchLine` in XSChannelCore.m, held
/// to the same fixture): after the first line (the check-in's `settings`, opened as any reply), it
/// takes only lines signed for this installation and this watch's nonce that are `live` or `alive`
/// with the next `seq`. Anything else (forged, from another connection, replayed, skipped, unsigned)
/// is refused, and the phone then closes the watch.
public struct ChannelWatchReader: Sendable {
    public let installationID: String
    public let nonce: String
    private let secret: Data
    /// The last line number taken (0 before the first `live`/`alive`).
    public private(set) var lastSeq = 0

    public init(installationID: String, nonce: String, secret: Data) {
        self.installationID = installationID
        self.nonce = nonce
        self.secret = secret
    }

    /// The reply carried by `line` (without its "\n") if it is the watch's next line, else nil
    /// (and nothing changes: the phone closes the watch).
    public mutating func open(line: Data) -> ChannelReply? {
        guard let envelope = try? ChannelReplyEnvelope.decode(line: line),
              let reply = envelope.open(secret: secret, expectedInstallationID: installationID, expectedNonce: nonce),
              let seq = reply.watchSeq, seq == lastSeq + 1 else { return nil }
        lastSeq = seq
        return reply
    }
}
