import Foundation
import CryptoKit
import CommonCrypto

// Channel v2 (mega review C2): the wire format's encrypted version, described at the top of
// Channel.swift. The dylib's side is XSChannelCore.m (CommonCrypto only), held to the same fixture.

/// Which wire format a line came in; XSide answers in the same one.
public enum ChannelVersion: Int, Sendable, Equatable {
    /// Plain-text bodies and the installation id: dylibs from XSide 1.1 and 1.2.
    case v1 = 1
    /// Encrypted bodies and an opaque token.
    case v2 = 2
}

/// The v2 keys of one installation, all derived from its 32-byte secret with HKDF-SHA256 (salt
/// "XSide channel v2", one info per key). A new signing rotates the secret, so all of them.
public struct ChannelKeys: Sendable, Equatable {
    /// AES-256-CTR key of the bodies (both directions; each line has its own random IV).
    public let encryption: Data
    /// HMAC-SHA256 key of the lines.
    public let authentication: Data
    /// 16 bytes standing for the installation on the wire (instead of record UUID | device id).
    public let token: Data

    static let salt = Data("XSide channel v2".utf8)

    public init(secret: Data) {
        func derive(_ info: String, _ count: Int) -> Data {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Self.salt, info: Data(info.utf8),
                                   outputByteCount: count).withUnsafeBytes { Data($0) }
        }
        encryption = derive("enc", 32)
        authentication = derive("mac", 32)
        token = derive("token", 16)
    }

    /// Only the 16-byte token, one HKDF (no enc/mac keys): for the opaque installation lookup,
    /// which compares tokens and derives the full schedule just for the match.
    public static func token(secret: Data) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Self.salt, info: Data("token".utf8),
                               outputByteCount: 16).withUnsafeBytes { Data($0) }
    }
}

enum ChannelCrypto {
    static let ivLength = 16
    static let tokenLength = 16
    static let macLength = 32

    struct Failure: Error {}

    /// AES-256-CTR (128-bit big-endian counter starting at `iv`); the same call decrypts.
    static func aesCTR(key: Data, iv: Data, _ input: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == ivLength else { throw Failure() }
        if input.isEmpty { return Data() }
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, k.count, nil, 0, 0,
                                        CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else { throw Failure() }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: input.count)
        var moved = 0
        let status = input.withUnsafeBytes { i in
            output.withUnsafeMutableBytes { o in
                CCCryptorUpdate(cryptor, i.baseAddress, i.count, o.baseAddress, o.count, &moved)
            }
        }
        guard status == kCCSuccess, moved == input.count else { throw Failure() }
        return output
    }

    static func randomIV() -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: ivLength * 8)).withUnsafeBytes { Data($0) }
    }

    static func hmac(_ key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// The lengths every v2 line must have (checked before anything else).
    static func wellFormed(token: Data, iv: Data, body: Data, mac: Data) -> Bool {
        token.count == tokenLength && iv.count == ivLength && mac.count == macLength
            && (1...ChannelHandler.maxLineLength).contains(body.count)
    }
}

/// Exact field sets: a v2 line has these keys and no other (no v1 field rides along).
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private func checkV2Keys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let all = try decoder.container(keyedBy: AnyKey.self)
    let keys = Set(all.allKeys.map(\.stringValue))
    guard keys == expected, try all.decode(Int.self, forKey: AnyKey(stringValue: "v")) == ChannelVersion.v2.rawValue else {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a v2 line"))
    }
}

/// A v2 request line: `{"v":2,"token","timestamp","nonce","iv","body","mac"}` (see Channel.swift).
public struct ChannelEnvelopeV2: Codable, Equatable, Sendable {
    public var token: Data
    /// Milliseconds since 1970 (in clear: the MAC covers it).
    public var timestamp: Int64
    public var nonce: String
    public var iv: Data
    /// AES-256-CTR of the request's JSON (what a v1 body carries in clear).
    public var body: Data
    public var mac: Data

    public init(token: Data, timestamp: Int64, nonce: String, iv: Data, body: Data, mac: Data) {
        self.token = token
        self.timestamp = timestamp
        self.nonce = nonce
        self.iv = iv
        self.body = body
        self.mac = mac
    }

    private enum CodingKeys: String, CodingKey { case v, token, timestamp, nonce, iv, body, mac }

    public init(from decoder: Decoder) throws {
        try checkV2Keys(decoder, ["v", "token", "timestamp", "nonce", "iv", "body", "mac"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(Data.self, forKey: .token)
        timestamp = try c.decode(Int64.self, forKey: .timestamp)
        nonce = try c.decode(String.self, forKey: .nonce)
        iv = try c.decode(Data.self, forKey: .iv)
        body = try c.decode(Data.self, forKey: .body)
        mac = try c.decode(Data.self, forKey: .mac)
        guard ChannelCrypto.wellFormed(token: token, iv: iv, body: body, mac: mac), ChannelEnvelope.isValidNonce(nonce) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "v2 field lengths"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ChannelVersion.v2.rawValue, forKey: .v)
        try c.encode(token, forKey: .token)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(nonce, forKey: .nonce)
        try c.encode(iv, forKey: .iv)
        try c.encode(body, forKey: .body)
        try c.encode(mac, forKey: .mac)
    }

    /// `xside2|request|b64(token)|timestampMillis|nonce|b64(iv)|b64(body)`: no field can hold "|".
    static func signedString(token: Data, timestamp: Int64, nonce: String, iv: Data, body: Data) -> Data {
        Data("xside2|request|\(token.base64EncodedString())|\(timestamp)|\(nonce)|\(iv.base64EncodedString())|\(body.base64EncodedString())".utf8)
    }

    static func computeMAC(keys: ChannelKeys, timestamp: Int64, nonce: String, iv: Data, body: Data) -> Data {
        ChannelCrypto.hmac(keys.authentication, signedString(token: keys.token, timestamp: timestamp, nonce: nonce, iv: iv, body: body))
    }

    public static func seal(_ request: ChannelRequest, secret: Data, now: Date, nonce: String) throws -> ChannelEnvelopeV2 {
        guard let ms = channelMillis(now) else { throw ChannelError.invalidTimestamp }
        return try seal(request, secret: secret, timestampMillis: ms, nonce: nonce)
    }

    /// `iv`: fixed only for the fixture; otherwise 16 random bytes.
    static func seal(_ request: ChannelRequest, secret: Data, timestampMillis: Int64, nonce: String,
                     iv: Data? = nil) throws -> ChannelEnvelopeV2 {
        guard ChannelEnvelope.isValidNonce(nonce) else { throw ChannelError.invalidNonce }
        let keys = ChannelKeys(secret: secret)
        let iv = iv ?? ChannelCrypto.randomIV()
        let body = try ChannelCrypto.aesCTR(key: keys.encryption, iv: iv, try ChannelEnvelope.encodeBody(request))
        return ChannelEnvelopeV2(token: keys.token, timestamp: timestampMillis, nonce: nonce, iv: iv, body: body,
                                 mac: computeMAC(keys: keys, timestamp: timestampMillis, nonce: nonce, iv: iv, body: body))
    }

    /// The request if every length is right, the token is this installation's, the MAC verifies
    /// (constant time, before anything is decrypted), the timestamp is inside the window, the
    /// plaintext is a request and the nonce is new for `installationID`; nil otherwise. The nonce is
    /// recorded only on success.
    public func open(keys: ChannelKeys, installationID: String, now: Date, seen: inout NonceCache) -> ChannelRequest? {
        guard ChannelCrypto.wellFormed(token: token, iv: iv, body: body, mac: mac), ChannelEnvelope.isValidNonce(nonce),
              ChannelEnvelope.constantTimeEqual(token, keys.token) else { return nil }
        let expected = Self.computeMAC(keys: keys, timestamp: timestamp, nonce: nonce, iv: iv, body: body)
        guard ChannelEnvelope.constantTimeEqual(expected, mac) else { return nil }
        guard let nowMillis = channelMillis(now) else { return nil }
        let (diff, overflow) = nowMillis.subtractingReportingOverflow(timestamp)
        guard !overflow, diff != .min, abs(diff) <= Int64(ChannelEnvelope.window * 1000) else { return nil }
        guard let plain = try? ChannelCrypto.aesCTR(key: keys.encryption, iv: iv, body),
              let request = try? JSONDecoder.channel.decode(ChannelRequest.self, from: plain) else { return nil }
        guard seen.insert(nonce, installationID: installationID, at: now) else { return nil }
        return request
    }

    public func encodedLine() throws -> Data {
        try JSONEncoder.channel.encode(self) + Data([0x0A])
    }

    public static func decode(line: Data) throws -> ChannelEnvelopeV2 {
        try JSONDecoder.channel.decode(ChannelEnvelopeV2.self, from: line)
    }
}

/// A v2 reply or watch line: `{"v":2,"token","nonce","iv","body","mac"}`, bound to the request's
/// nonce (a watch's lines: the watch request's nonce, `seq` inside the encrypted body).
public struct ChannelReplyEnvelopeV2: Codable, Equatable, Sendable {
    public var token: Data
    public var nonce: String
    public var iv: Data
    public var body: Data
    public var mac: Data

    public init(token: Data, nonce: String, iv: Data, body: Data, mac: Data) {
        self.token = token
        self.nonce = nonce
        self.iv = iv
        self.body = body
        self.mac = mac
    }

    private enum CodingKeys: String, CodingKey { case v, token, nonce, iv, body, mac }

    public init(from decoder: Decoder) throws {
        try checkV2Keys(decoder, ["v", "token", "nonce", "iv", "body", "mac"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(Data.self, forKey: .token)
        nonce = try c.decode(String.self, forKey: .nonce)
        iv = try c.decode(Data.self, forKey: .iv)
        body = try c.decode(Data.self, forKey: .body)
        mac = try c.decode(Data.self, forKey: .mac)
        guard ChannelCrypto.wellFormed(token: token, iv: iv, body: body, mac: mac), ChannelEnvelope.isValidNonce(nonce) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "v2 field lengths"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ChannelVersion.v2.rawValue, forKey: .v)
        try c.encode(token, forKey: .token)
        try c.encode(nonce, forKey: .nonce)
        try c.encode(iv, forKey: .iv)
        try c.encode(body, forKey: .body)
        try c.encode(mac, forKey: .mac)
    }

    /// `xside2|reply|b64(token)|requestNonce|b64(iv)|b64(body)`.
    static func signedString(token: Data, nonce: String, iv: Data, body: Data) -> Data {
        Data("xside2|reply|\(token.base64EncodedString())|\(nonce)|\(iv.base64EncodedString())|\(body.base64EncodedString())".utf8)
    }

    static func computeMAC(keys: ChannelKeys, nonce: String, iv: Data, body: Data) -> Data {
        ChannelCrypto.hmac(keys.authentication, signedString(token: keys.token, nonce: nonce, iv: iv, body: body))
    }

    public static func seal(_ reply: ChannelReply, requestNonce: String, secret: Data) throws -> ChannelReplyEnvelopeV2 {
        try seal(reply, requestNonce: requestNonce, secret: secret, iv: nil)
    }

    static func seal(_ reply: ChannelReply, requestNonce: String, secret: Data, iv: Data?) throws -> ChannelReplyEnvelopeV2 {
        guard ChannelEnvelope.isValidNonce(requestNonce) else { throw ChannelError.invalidNonce }
        let keys = ChannelKeys(secret: secret)
        let iv = iv ?? ChannelCrypto.randomIV()
        let body = try ChannelCrypto.aesCTR(key: keys.encryption, iv: iv, try reply.encodedBody())
        return ChannelReplyEnvelopeV2(token: keys.token, nonce: requestNonce, iv: iv, body: body,
                                      mac: computeMAC(keys: keys, nonce: requestNonce, iv: iv, body: body))
    }

    /// The reply if it answers `expectedNonce` for this secret's token and its MAC verifies
    /// (checked before decrypting); nil otherwise. The phone's side (XSOpenReplyV2), for tests.
    public func open(secret: Data, expectedNonce: String) -> ChannelReply? {
        let keys = ChannelKeys(secret: secret)
        guard ChannelCrypto.wellFormed(token: token, iv: iv, body: body, mac: mac), nonce == expectedNonce,
              ChannelEnvelope.constantTimeEqual(token, keys.token) else { return nil }
        let expected = Self.computeMAC(keys: keys, nonce: nonce, iv: iv, body: body)
        guard ChannelEnvelope.constantTimeEqual(expected, mac),
              let plain = try? ChannelCrypto.aesCTR(key: keys.encryption, iv: iv, body) else { return nil }
        return try? ChannelReply.decode(body: plain)
    }

    public func encodedLine() throws -> Data {
        try JSONEncoder.channel.encode(self) + Data([0x0A])
    }

    public static func decode(line: Data) throws -> ChannelReplyEnvelopeV2 {
        try JSONDecoder.channel.decode(ChannelReplyEnvelopeV2.self, from: line)
    }
}

/// What names the installation in a request line: v1's id, or v2's token.
public enum ChannelKeyRef: Equatable, Sendable {
    case installationID(String)
    case token(Data)
}

/// The clear part of a request line, read before it authenticates (to find the installation).
public struct ChannelLineHead: Equatable, Sendable {
    public var ref: ChannelKeyRef
    public var version: ChannelVersion
    /// The line's timestamp; trustworthy only once `ChannelHandler.receive` authenticated the line.
    public var timestamp: Int64

    public init(ref: ChannelKeyRef, version: ChannelVersion, timestamp: Int64) {
        self.ref = ref
        self.version = version
        self.timestamp = timestamp
    }
}

/// A request line, parsed in the version it says: a "v" key makes it v2 (and only v2: any other
/// value, or a v2 line missing a field, is malformed); no "v" key, v1.
enum ChannelParsedLine {
    case v1(ChannelEnvelope)
    case v2(ChannelEnvelopeV2)

    private struct Probe: Decodable {
        let hasVersion: Bool
        init(from decoder: Decoder) throws {
            hasVersion = try decoder.container(keyedBy: AnyKey.self).contains(AnyKey(stringValue: "v"))
        }
    }

    init?(_ line: Data) {
        guard let probe = try? JSONDecoder.channel.decode(Probe.self, from: line) else { return nil }
        if probe.hasVersion {
            guard let e = try? ChannelEnvelopeV2.decode(line: line) else { return nil }
            self = .v2(e)
        } else {
            guard let e = try? ChannelEnvelope.decode(line: line) else { return nil }
            self = .v1(e)
        }
    }

    var head: ChannelLineHead {
        switch self {
        case .v1(let e): ChannelLineHead(ref: .installationID(e.installationID), version: .v1, timestamp: e.timestamp)
        case .v2(let e): ChannelLineHead(ref: .token(e.token), version: .v2, timestamp: e.timestamp)
        }
    }

    var nonce: String {
        switch self {
        case .v1(let e): e.nonce
        case .v2(let e): e.nonce
        }
    }
}

extension AppLibrary {
    /// The installation a request line names: by exact channel id (v1), or by the token its secret
    /// derives (v2). Only the token is derived per installation (one HKDF each, no enc/mac keys);
    /// the caller derives the full schedule for the one it matched.
    public func installation(channelRef ref: ChannelKeyRef) -> (recordID: UUID, installation: Installation)? {
        switch ref {
        case .installationID(let id):
            return installation(channelID: id)
        case .token(let token):
            guard token.count == ChannelCrypto.tokenLength else { return nil }
            for record in records() {
                for installation in record.installations {
                    if let secret = installation.channelSecret, ChannelKeys.token(secret: secret) == token {
                        return (record.id, installation)
                    }
                }
            }
            return nil
        }
    }
}
