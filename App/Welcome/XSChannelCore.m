// See XSChannelCore.h. Mirrors ChannelEnvelope / ChannelReplyEnvelope in
// Sources/XSideCore/Channel.swift; checked by scripts/test-welcome-hmac.sh.

#import "XSChannelCore.h"
#import "XSSettingsCore.h"
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonCryptor.h>
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

NSDictionary *XSCheckInBody(NSDictionary *settings, NSDictionary *lastRefresh, NSString *appVersion,
                            NSTimeInterval pollEvery) {
    NSMutableDictionary *body = [@{@"type": @"checkIn", @"settings": XSSettingsJSONObject(settings)} mutableCopy];
    if ([lastRefresh[@"at"] isKindOfClass:NSDate.class]) {
        NSMutableDictionary *last = [@{@"at": @(XSMillis(lastRefresh[@"at"])),
                                       @"succeeded": [lastRefresh[@"succeeded"] boolValue] ? @YES : @NO} mutableCopy];
        if ([lastRefresh[@"reasonKey"] isKindOfClass:NSString.class]) last[@"reasonKey"] = lastRefresh[@"reasonKey"];
        body[@"lastRefresh"] = last;
    }
    if ([appVersion isKindOfClass:NSString.class] && appVersion.length) body[@"appVersion"] = appVersion;
    if (pollEvery >= 1) body[@"pollEvery"] = @((NSInteger)llround(pollEvery));
    return body;
}

NSDictionary *XSWatchBody(NSDictionary *settings, NSDictionary *lastRefresh, NSString *appVersion, BOOL saysBye) {
    // No poll interval: while the watch is open the Mac knows the app is in front.
    NSMutableDictionary *body = [XSCheckInBody(settings, lastRefresh, appVersion, 0) mutableCopy];
    body[@"type"] = @"watch";
    if (saysBye) body[@"saysBye"] = @YES;
    return body;
}

NSDictionary *XSByeBody(void) { return @{@"type": @"bye"}; }

NSDictionary *XSWithRunReport(NSDictionary *body, NSDictionary *report) {
    if (![report isKindOfClass:NSDictionary.class]) return body;
    id ended = report[@"ended"];
    id since = report[@"since"];
    if ((![ended isEqual:@"crashed"] && ![ended isEqual:@"clean"]) || ![since isKindOfClass:NSDate.class]) return body;
    NSMutableDictionary *with = [body mutableCopy];
    with[@"previousRunEnded"] = ended;
    with[@"previousRunSince"] = @(XSMillis(since));
    return with;
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

/// A watch line's reply after its signature checked: `live` or `alive`, "seq" exactly the next one.
static BOOL XSIsNextWatchLine(NSDictionary *reply, int64_t lastSeq) {
    if (![reply[@"type"] isEqual:@"live"] && ![reply[@"type"] isEqual:@"alive"]) return NO;
    id seq = reply[@"seq"];
    // An integer (not a Bool, not a fraction), exactly the next one.
    if (![seq isKindOfClass:NSNumber.class] || strcmp([seq objCType], @encode(BOOL)) == 0
        || strcmp([seq objCType], @encode(char)) == 0) return NO;
    if ([seq doubleValue] != (double)[seq longLongValue] || [seq longLongValue] != lastSeq + 1) return NO;
    return YES;
}

XSReplyStatus XSOpenWatchLine(NSData *line, NSData *secret, NSString *installationID, NSString *nonce,
                              int64_t lastSeq, NSDictionary **body) {
    if (body) *body = nil;
    NSDictionary *reply = nil;
    // The bare `rejected` (unsigned) is only ever a first line: here it is invalid like any other.
    if (XSOpenReply(line, secret, installationID, nonce, &reply) != XSReplyOK) return XSReplyInvalid;
    if (!XSIsNextWatchLine(reply, lastSeq)) return XSReplyInvalid;
    if (body) *body = reply;
    return XSReplyOK;
}

// MARK: - v2

static const NSUInteger XSIVLength = 16, XSTokenLength = 16, XSMACLength = 32, XSMaxLine = 64 * 1024;

NSData *XSHKDFSHA256(NSData *ikm, NSData *salt, NSData *info, NSUInteger length) {
    if (ikm.length == 0 || length == 0 || length > 255 * CC_SHA256_DIGEST_LENGTH) return nil;
    NSData *prk = XSHMACSHA256(salt, ikm);
    NSMutableData *okm = [NSMutableData data];
    NSData *previous = [NSData data];
    for (uint8_t i = 1; okm.length < length; i++) {
        NSMutableData *block = [previous mutableCopy];
        [block appendData:info];
        [block appendBytes:&i length:1];
        previous = XSHMACSHA256(prk, block);
        [okm appendData:previous];
    }
    return [okm subdataWithRange:NSMakeRange(0, length)];
}

static NSData *XSChannelKey(NSData *secret, const char *info, NSUInteger length) {
    if (![secret isKindOfClass:NSData.class] || secret.length == 0) return nil;
    NSData *salt = [@"XSide channel v2" dataUsingEncoding:NSUTF8StringEncoding];
    return XSHKDFSHA256(secret, salt, [NSData dataWithBytes:info length:strlen(info)], length);
}

NSData *XSChannelEncKey(NSData *secret) { return XSChannelKey(secret, "enc", 32); }
NSData *XSChannelMacKey(NSData *secret) { return XSChannelKey(secret, "mac", 32); }
NSData *XSChannelToken(NSData *secret) { return XSChannelKey(secret, "token", XSTokenLength); }

NSData *XSAESCTR(NSData *key, NSData *iv, NSData *input) {
    if (key.length != kCCKeySizeAES256 || iv.length != XSIVLength || !input) return nil;
    if (input.length == 0) return [NSData data];
    CCCryptorRef cryptor = NULL;
    if (CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding, iv.bytes, key.bytes, key.length,
                                NULL, 0, 0, kCCModeOptionCTR_BE, &cryptor) != kCCSuccess || !cryptor) return nil;
    NSMutableData *output = [NSMutableData dataWithLength:input.length];
    size_t moved = 0;
    CCCryptorStatus status = CCCryptorUpdate(cryptor, input.bytes, input.length, output.mutableBytes, output.length, &moved);
    CCCryptorRelease(cryptor);
    if (status != kCCSuccess || moved != input.length) return nil;
    return output;
}

NSString *XSRequestSignedStringV2(NSData *token, int64_t millis, NSString *nonce, NSData *iv, NSData *ciphertext) {
    return [NSString stringWithFormat:@"xside2|request|%@|%lld|%@|%@|%@", XSBase64(token), (long long)millis, nonce,
            XSBase64(iv), XSBase64(ciphertext)];
}

NSString *XSReplySignedStringV2(NSData *token, NSString *nonce, NSData *iv, NSData *ciphertext) {
    return [NSString stringWithFormat:@"xside2|reply|%@|%@|%@|%@", XSBase64(token), nonce, XSBase64(iv), XSBase64(ciphertext)];
}

NSData *XSSealRequestV2WithIV(NSDictionary *body, NSData *secret, int64_t millis, NSString *nonce, NSData *iv) {
    if (!XSNonceValid(nonce) || ![iv isKindOfClass:NSData.class] || iv.length != XSIVLength) return nil;
    NSData *encKey = XSChannelEncKey(secret), *macKey = XSChannelMacKey(secret), *token = XSChannelToken(secret);
    NSData *json = XSJSONData(body);
    if (!encKey || !macKey || !token || json.length == 0) return nil;
    NSData *ciphertext = XSAESCTR(encKey, iv, json);
    if (!ciphertext) return nil;
    NSString *signedString = XSRequestSignedStringV2(token, millis, nonce, iv, ciphertext);
    NSData *mac = XSHMACSHA256(macKey, [signedString dataUsingEncoding:NSUTF8StringEncoding]);
    NSDictionary *envelope = @{@"v": @2, @"token": XSBase64(token), @"timestamp": @(millis), @"nonce": nonce,
                               @"iv": XSBase64(iv), @"body": XSBase64(ciphertext), @"mac": XSBase64(mac)};
    NSMutableData *line = [XSJSONData(envelope) mutableCopy];
    if (!line || line.length > XSMaxLine) return nil;
    [line appendBytes:"\n" length:1];
    return line;
}

NSData *XSSealRequestV2(NSDictionary *body, NSData *secret, int64_t millis, NSString *nonce) {
    uint8_t random[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof random, random) != errSecSuccess) return nil; // no weak IV
    return XSSealRequestV2WithIV(body, secret, millis, nonce, [NSData dataWithBytes:random length:sizeof random]);
}

/// The integer 2 (not a Bool, not a char, not a float/double like 2.0, not "2", not 2.5). The
/// Swift side decodes "v" as Int, which rejects a non-integer; match it.
static BOOL XSIsVersion2(id v) {
    if (![v isKindOfClass:NSNumber.class]) return NO;
    const char *type = [v objCType];
    if (strcmp(type, @encode(BOOL)) == 0 || strcmp(type, @encode(char)) == 0) return NO;
    if (strcmp(type, @encode(float)) == 0 || strcmp(type, @encode(double)) == 0) return NO;
    return [v longLongValue] == 2;
}

XSReplyStatus XSOpenReplyV2(NSData *line, NSData *secret, NSString *nonce, NSDictionary **body) {
    if (body) *body = nil;
    NSData *trimmed = line;
    if (line.length && ((const char *)line.bytes)[line.length - 1] == '\n') {
        trimmed = [line subdataWithRange:NSMakeRange(0, line.length - 1)];
    }
    if (trimmed.length == 0 || trimmed.length > XSMaxLine) return XSReplyInvalid;
    id json = [NSJSONSerialization JSONObjectWithData:trimmed options:0 error:NULL];
    if (![json isKindOfClass:NSDictionary.class]) return XSReplyInvalid;
    NSDictionary *envelope = json;
    if (envelope.count == 1 && [envelope[@"type"] isEqual:@"rejected"]) return XSReplyUnknownInstallation;
    // Exactly the v2 reply's fields: no v1 envelope, nothing riding along.
    static NSSet *fields;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fields = [NSSet setWithObjects:@"v", @"token", @"nonce", @"iv", @"body", @"mac", nil]; });
    if (![[NSSet setWithArray:envelope.allKeys] isEqualToSet:fields] || !XSIsVersion2(envelope[@"v"])) return XSReplyInvalid;
    if (!XSNonceValid(nonce) || ![envelope[@"nonce"] isEqual:nonce]) return XSReplyInvalid;
    NSData *token = XSCanonicalBase64(envelope[@"token"]), *iv = XSCanonicalBase64(envelope[@"iv"]);
    NSData *ciphertext = XSCanonicalBase64(envelope[@"body"]), *mac = XSCanonicalBase64(envelope[@"mac"]);
    if (token.length != XSTokenLength || iv.length != XSIVLength || mac.length != XSMACLength
        || ciphertext.length == 0 || ciphertext.length > XSMaxLine) return XSReplyInvalid;
    NSData *encKey = XSChannelEncKey(secret), *macKey = XSChannelMacKey(secret), *mine = XSChannelToken(secret);
    if (!encKey || !macKey || !mine || !XSConstantTimeEqual(token, mine)) return XSReplyInvalid;
    NSString *signedString = XSReplySignedStringV2(token, nonce, iv, ciphertext);
    NSData *expected = XSHMACSHA256(macKey, [signedString dataUsingEncoding:NSUTF8StringEncoding]);
    if (!XSConstantTimeEqual(expected, mac)) return XSReplyInvalid;
    // Authenticated: only now decrypted and parsed.
    NSData *plain = XSAESCTR(encKey, iv, ciphertext);
    if (!plain) return XSReplyInvalid;
    id reply = [NSJSONSerialization JSONObjectWithData:plain options:0 error:NULL];
    if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"type"] isKindOfClass:NSString.class]) return XSReplyInvalid;
    if (body) *body = reply;
    return XSReplyOK;
}

XSReplyStatus XSOpenWatchLineV2(NSData *line, NSData *secret, NSString *nonce, int64_t lastSeq, NSDictionary **body) {
    if (body) *body = nil;
    NSDictionary *reply = nil;
    if (XSOpenReplyV2(line, secret, nonce, &reply) != XSReplyOK) return XSReplyInvalid;
    if (!XSIsNextWatchLine(reply, lastSeq)) return XSReplyInvalid;
    if (body) *body = reply;
    return XSReplyOK;
}
