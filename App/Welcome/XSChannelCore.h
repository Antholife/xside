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

NS_ASSUME_NONNULL_END
