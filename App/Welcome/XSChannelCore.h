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
NSDictionary *XSCheckInBody(NSDictionary *settings, NSDictionary *_Nullable lastRefresh,
                            NSString *_Nullable appVersion);

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

/// Standard base64 with padding, decoded only if it is canonical (re-encodes to the same text).
NSData *_Nullable XSCanonicalBase64(id _Nullable text);

NS_ASSUME_NONNULL_END
