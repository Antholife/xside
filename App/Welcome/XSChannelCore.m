// See XSChannelCore.h. Mirrors ChannelEnvelope / ChannelReplyEnvelope in
// Sources/XSideCore/Channel.swift; checked by scripts/test-welcome-hmac.sh.

#import "XSChannelCore.h"
#import "XSSettingsCore.h"
#import <CommonCrypto/CommonHMAC.h>
#import <Security/SecRandom.h>

NSData *XSHMACSHA256(NSData *key, NSData *message) {
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, message.bytes, message.length, mac);
    return [NSData dataWithBytes:mac length:sizeof mac];
}

BOOL XSNonceValid(NSString *nonce) {
    if (![nonce isKindOfClass:NSString.class]) return NO;
    NSData *utf8 = [nonce dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8.length < 1 || utf8.length > 64) return NO;
    const uint8_t *b = utf8.bytes;
    for (NSUInteger i = 0; i < utf8.length; i++) {
        uint8_t c = b[i];
        BOOL ok = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '-' || c == '_';
        if (!ok) return NO;
    }
    return YES;
}

NSString *XSNewNonce(void) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    uint8_t random[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof random, random) != errSecSuccess) {
        arc4random_buf(random, sizeof random);
    }
    char text[33];
    for (size_t i = 0; i < sizeof random; i++) text[i] = alphabet[random[i] & 63];
    text[32] = 0;
    return @(text);
}

NSData *XSJSONData(id object) {
    if (![NSJSONSerialization isValidJSONObject:object]) return nil;
    // Same output as the Mac's JSONEncoder.channel (sorted keys, "/" unescaped); the MAC covers
    // these bytes as sent, so this only matters for the fixture check, not for interoperability.
    return [NSJSONSerialization dataWithJSONObject:object
                                           options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                             error:NULL];
}

static NSString *XSBase64(NSData *data) { return [data base64EncodedStringWithOptions:0]; }

NSString *XSRequestSignedString(NSString *installationID, int64_t millis, NSString *nonce, NSData *body) {
    return [NSString stringWithFormat:@"%@|%lld|%@|%@", installationID, (long long)millis, nonce, XSBase64(body)];
}

NSString *XSReplySignedString(NSString *installationID, NSString *nonce, NSData *body) {
    return [NSString stringWithFormat:@"reply|%@|%@|%@", installationID, nonce, XSBase64(body)];
}

NSData *XSSealRequest(NSDictionary *body, NSString *installationID, NSData *secret, int64_t millis, NSString *nonce) {
    if (!XSNonceValid(nonce) || installationID.length == 0 || secret.length == 0) return nil;
    NSData *json = XSJSONData(body);
    if (!json) return nil;
    NSString *signedString = XSRequestSignedString(installationID, millis, nonce, json);
    NSData *mac = XSHMACSHA256(secret, [signedString dataUsingEncoding:NSUTF8StringEncoding]);
    NSDictionary *envelope = @{@"installationID": installationID, @"timestamp": @(millis), @"nonce": nonce,
                               @"body": XSBase64(json), @"mac": XSBase64(mac)};
    NSMutableData *line = [XSJSONData(envelope) mutableCopy];
    if (!line) return nil;
    [line appendBytes:"\n" length:1];
    return line;
}

NSDictionary *XSRefreshBody(void) { return @{@"type": @"refresh"}; }

NSDictionary *XSSetAutoRefreshBody(BOOL on) { return @{@"type": @"setAutoRefresh", @"on": on ? @YES : @NO}; }

NSDictionary *XSCheckInBody(NSDictionary *settings, NSDictionary *lastRefresh, NSString *appVersion) {
    NSMutableDictionary *body = [@{@"type": @"checkIn", @"settings": XSSettingsJSONObject(settings)} mutableCopy];
    if ([lastRefresh[@"at"] isKindOfClass:NSDate.class]) {
        NSMutableDictionary *last = [@{@"at": @(XSMillis(lastRefresh[@"at"])),
                                       @"succeeded": [lastRefresh[@"succeeded"] boolValue] ? @YES : @NO} mutableCopy];
        if ([lastRefresh[@"reasonKey"] isKindOfClass:NSString.class]) last[@"reasonKey"] = lastRefresh[@"reasonKey"];
        body[@"lastRefresh"] = last;
    }
    if ([appVersion isKindOfClass:NSString.class] && appVersion.length) body[@"appVersion"] = appVersion;
    return body;
}

NSData *XSCanonicalBase64(id text) {
    if (![text isKindOfClass:NSString.class]) return nil;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:text options:0];
    if (!data || ![XSBase64(data) isEqualToString:text]) return nil;
    return data;
}

static BOOL XSConstantTimeEqual(NSData *a, NSData *b) {
    if (a.length != b.length) return NO;
    const uint8_t *x = a.bytes, *y = b.bytes;
    uint8_t diff = 0;
    for (NSUInteger i = 0; i < a.length; i++) diff |= x[i] ^ y[i];
    return diff == 0;
}

XSReplyStatus XSOpenReply(NSData *line, NSData *secret, NSString *installationID, NSString *nonce, NSDictionary **body) {
    if (body) *body = nil;
    NSData *trimmed = line;
    if (line.length && ((const char *)line.bytes)[line.length - 1] == '\n') {
        trimmed = [line subdataWithRange:NSMakeRange(0, line.length - 1)];
    }
    if (trimmed.length == 0 || trimmed.length > 64 * 1024) return XSReplyInvalid;
    id json = [NSJSONSerialization JSONObjectWithData:trimmed options:0 error:NULL];
    if (![json isKindOfClass:NSDictionary.class]) return XSReplyInvalid;
    NSDictionary *envelope = json;
    // The one unsigned line XSide sends: only ever read as "this XSide doesn't know me".
    if (envelope.count == 1 && [envelope[@"type"] isEqual:@"rejected"]) return XSReplyUnknownInstallation;
    if (![envelope[@"installationID"] isEqual:installationID] || ![envelope[@"nonce"] isEqual:nonce]) return XSReplyInvalid;
    NSData *payload = XSCanonicalBase64(envelope[@"body"]);
    NSData *mac = XSCanonicalBase64(envelope[@"mac"]);
    if (!payload || !mac || secret.length == 0) return XSReplyInvalid;
    NSString *signedString = XSReplySignedString(installationID, nonce, payload);
    NSData *expected = XSHMACSHA256(secret, [signedString dataUsingEncoding:NSUTF8StringEncoding]);
    if (!XSConstantTimeEqual(expected, mac)) return XSReplyInvalid;
    id reply = [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL];
    if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"type"] isKindOfClass:NSString.class]) return XSReplyInvalid;
    if (body) *body = reply;
    return XSReplyOK;
}
