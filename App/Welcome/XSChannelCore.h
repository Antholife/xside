// XSChannelCore: the request and reply frames of the channel to XSide on the Mac, byte for byte
// the wire format documented at the top of Sources/XSideCore/Channel.swift. Pure Foundation and
// CommonCrypto, so scripts/test-welcome-hmac.sh compiles it for the Mac and checks it against
// Tests/XSideCoreTests/Fixtures/channel-fixture.json.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// HMAC-SHA256 of `message` with `key`.
NSData *XSHMACSHA256(NSData *key, NSData *message);

/// 1 to 64 characters from [A-Za-z0-9_-].
BOOL XSNonceValid(NSString *_Nullable nonce);
/// A fresh random nonce (32 characters).
NSString *XSNewNonce(void);

/// Canonical JSON of a request or reply body: sorted keys, unescaped slashes, no newline.
NSData *_Nullable XSJSONData(id object);

/// `installationID|millis|nonce|base64(body)`: what a request's MAC covers.
NSString *XSRequestSignedString(NSString *installationID, int64_t millis, NSString *nonce, NSData *body);
/// `reply|installationID|nonce|base64(body)`: what a reply's MAC covers.
NSString *XSReplySignedString(NSString *installationID, NSString *nonce, NSData *body);

/// The request line (with its "\n") for `body` (a JSON object such as @{@"type": @"refresh"}),
/// sealed with `secret`. Nil for an invalid nonce or a body that isn't JSON.
NSData *_Nullable XSSealRequest(NSDictionary *body, NSString *installationID, NSData *secret,
                                int64_t millis, NSString *nonce);

/// Bodies of the three requests.
NSDictionary *XSRefreshBody(void);
NSDictionary *XSSetAutoRefreshBody(BOOL on);
/// `lastRefresh`: {at (NSDate), succeeded (Bool), reasonKey (optional)}; `appVersion` optional.
/// `pollEvery`: seconds to the next foreground poll (15, 45 in Low Power Mode), so the Mac says
/// "open, live" until then (device feedback 5, G3); 0 leaves it out (not polling: in the background).
NSDictionary *XSCheckInBody(NSDictionary *settings, NSDictionary *_Nullable lastRefresh,
                            NSString *_Nullable appVersion, NSTimeInterval pollEvery);
/// A check-in that keeps the connection open while the app is in front (device feedback 4): the
/// first line is the check-in's `settings` reply, then XSide writes `live`/`alive` lines on it.
/// `saysBye`: the app writes `bye` (XSByeBody) on it before closing it as it leaves the front, so
/// XSide can tell a watch that ended because the app vanished (a crash) and look at once.
NSDictionary *XSWatchBody(NSDictionary *settings, NSDictionary *_Nullable lastRefresh,
                          NSString *_Nullable appVersion, BOOL saysBye);
/// {"type":"bye"}: written on a watch, sealed like any request, just before the app closes it.
NSDictionary *XSByeBody(void);
/// A check-in or watch body carrying how the previous run ended (XSRunMarkerReport:
/// {ended: "crashed"|"clean", since: NSDate}) as `previousRunEnded` and `previousRunSince`; the
/// body unchanged when there's no report or it isn't one.
NSDictionary *XSWithRunReport(NSDictionary *body, NSDictionary *_Nullable report);

typedef NS_ENUM(NSInteger, XSReplyStatus) {
    /// A signed reply to this request: `*body` is its JSON object (with a "type").
    XSReplyOK,
    /// The bare unsigned {"type":"rejected"}: this XSide doesn't know the installation.
    XSReplyUnknownInstallation,
    /// Anything else (bad MAC, other request, unreadable): ignored.
    XSReplyInvalid,
};

/// Opens one reply line (with or without its "\n"), checking the MAC, the installation id and
/// that it answers `nonce`.
XSReplyStatus XSOpenReply(NSData *line, NSData *secret, NSString *installationID, NSString *nonce,
                          NSDictionary *_Nullable *_Nullable body);

/// One line XSide wrote on a watch after its first line: XSReplyOK only if it is signed for this
/// installation and this watch's `nonce` (XSOpenReply) and is `live` or `alive` with
/// "seq" == `lastSeq` + 1. Anything else (forged, from another watch, replayed, skipped, unsigned,
/// the bare `rejected`) is XSReplyInvalid: the phone then closes the watch. Mirrors
/// ChannelWatchReader in Sources/XSideCore/Channel.swift.
XSReplyStatus XSOpenWatchLine(NSData *line, NSData *secret, NSString *installationID, NSString *nonce,
                              int64_t lastSeq, NSDictionary *_Nullable *_Nullable body);

/// Standard base64 with padding, decoded only if it is canonical (re-encodes to the same text).
NSData *_Nullable XSCanonicalBase64(id _Nullable text);

// MARK: - Channel v2 (mega review C2): encrypted bodies, an opaque token. What this library sends.
// Keys from the 32-byte secret with HKDF-SHA256 (salt "XSide channel v2"); bodies AES-256-CTR with
// a random 16-byte IV per line; encrypt-then-MAC over every field, checked (constant time) before
// anything is decrypted. Mirrors ChannelV2.swift.

/// HKDF-SHA256 (RFC 5869) of `ikm`, `length` bytes (1 to 255 * 32); nil for an empty `ikm`.
NSData *_Nullable XSHKDFSHA256(NSData *ikm, NSData *salt, NSData *info, NSUInteger length);
/// The body key (32 bytes), the MAC key (32 bytes) and the token (16 bytes) of `secret`.
NSData *_Nullable XSChannelEncKey(NSData *secret);
NSData *_Nullable XSChannelMacKey(NSData *secret);
NSData *_Nullable XSChannelToken(NSData *secret);
/// AES-256-CTR (big-endian 128-bit counter from `iv`); encrypts and decrypts. Nil unless the key
/// is 32 bytes and the IV 16.
NSData *_Nullable XSAESCTR(NSData *key, NSData *iv, NSData *input);

/// `xside2|request|b64(token)|millis|nonce|b64(iv)|b64(ciphertext)`: what a v2 request's MAC covers.
NSString *XSRequestSignedStringV2(NSData *token, int64_t millis, NSString *nonce, NSData *iv, NSData *ciphertext);
/// `xside2|reply|b64(token)|nonce|b64(iv)|b64(ciphertext)`: what a v2 reply's MAC covers.
NSString *XSReplySignedStringV2(NSData *token, NSString *nonce, NSData *iv, NSData *ciphertext);

/// The v2 request line (with its "\n") for `body`, encrypted under a fresh random IV and sealed
/// with keys from `secret`. Nil for an invalid nonce, an empty secret or a body that isn't JSON.
NSData *_Nullable XSSealRequestV2(NSDictionary *body, NSData *secret, int64_t millis, NSString *nonce);
/// The same with a given IV (16 bytes, else nil): for the fixture check only.
NSData *_Nullable XSSealRequestV2WithIV(NSDictionary *body, NSData *secret, int64_t millis, NSString *nonce, NSData *iv);

/// Opens one v2 reply line: exactly the v2 fields, this secret's token, the request's `nonce`, the
/// MAC (before decrypting), then a JSON object with a "type". The bare unsigned {"type":"rejected"}
/// is XSReplyUnknownInstallation; a v1 reply, like anything else, is XSReplyInvalid.
XSReplyStatus XSOpenReplyV2(NSData *line, NSData *secret, NSString *nonce, NSDictionary *_Nullable *_Nullable body);
/// XSOpenWatchLine for a v2 watch: XSOpenReplyV2, then `live`/`alive` with "seq" == `lastSeq` + 1.
XSReplyStatus XSOpenWatchLineV2(NSData *line, NSData *secret, NSString *nonce, int64_t lastSeq,
                                NSDictionary *_Nullable *_Nullable body);

NS_ASSUME_NONNULL_END
