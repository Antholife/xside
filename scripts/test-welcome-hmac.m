// The dylib's channel frames and settings merge, compiled for the Mac by
// scripts/test-welcome-hmac.sh and checked against the Swift side's fixture
// (Tests/XSideCoreTests/Fixtures/channel-fixture.json, written by ChannelTests) and against the
// cases of InAppSettingsTests. Exits non-zero on the first difference.

#import <Foundation/Foundation.h>
#import "XSChannelCore.h"
#import "XSSettingsCore.h"
#import "XSRunMarkerCore.h"

static int failures = 0;

static void check(BOOL ok, NSString *what) {
    if (!ok) { failures++; fprintf(stderr, "FAIL: %s\n", what.UTF8String); }
    else printf("ok: %s\n", what.UTF8String);
}

static NSData *hex(NSString *s) {
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < s.length; i += 2) {
        unsigned v = 0;
        [[NSScanner scannerWithString:[s substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&v];
        uint8_t b = (uint8_t)v;
        [d appendBytes:&b length:1];
    }
    return d;
}

static NSString *str(NSData *d) { return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"(nil)"; }

static NSDate *ms(int64_t v) { return XSDateFromMillis(v); }

static NSDictionary *field(id value, int64_t at, NSString *by) {
    return @{@"value": value, @"changedAt": ms(at), @"changedBy": by};
}

/// ChannelTests.fixtureSettings.
static NSDictionary *fixtureSettings(void) {
    return @{
        @"showValidity": field(@YES, 1799999000456, @"mac"),
        @"alertLate": field(@NO, 1799999001000, @"device"),
        @"refreshCard": field(@YES, 1799999002000, @"mac"),
        @"reminder": field(@NO, 1799999003000, @"mac"),
        @"language": field(@"fr", 1799999004000, @"device"),
        @"autoRefresh": field(@YES, 1799999005007, @"mac"),
    };
}

static BOOL sameSettings(NSDictionary *a, NSDictionary *b) {
    for (NSString *f in XSSettingFields()) {
        NSDictionary *x = a[f], *y = b[f];
        if (![x[@"value"] isEqual:y[@"value"]] || ![x[@"changedBy"] isEqual:y[@"changedBy"]]) return NO;
        if (XSMillis(x[@"changedAt"]) != XSMillis(y[@"changedAt"])) return NO;
    }
    return YES;
}

static void requestCase(NSDictionary *entry, NSData *secret, NSDictionary *body, NSString *name) {
    NSString *iid = entry[@"installationID"];
    int64_t ts = [entry[@"timestamp"] longLongValue];
    NSString *nonce = entry[@"nonce"];
    NSData *json = XSJSONData(body);
    check([str(json) isEqualToString:entry[@"bodyJSON"]], [name stringByAppendingString:@": body JSON"]);
    NSString *signedString = json ? XSRequestSignedString(iid, ts, nonce, json) : @"";
    check([signedString isEqualToString:entry[@"signedString"]], [name stringByAppendingString:@": signed string"]);
    NSData *mac = XSHMACSHA256(secret, [signedString dataUsingEncoding:NSUTF8StringEncoding]);
    check([[mac base64EncodedStringWithOptions:0] isEqualToString:entry[@"mac"]], [name stringByAppendingString:@": MAC"]);
    NSData *line = XSSealRequest(body, iid, secret, ts, nonce);
    NSString *expected = [entry[@"line"] stringByAppendingString:@"\n"];
    check([str(line) isEqualToString:expected], [name stringByAppendingString:@": request line"]);
}

static void requestCaseV2(NSDictionary *entry, NSData *secret, NSDictionary *body, NSString *name) {
    int64_t ts = [entry[@"timestamp"] longLongValue];
    NSString *nonce = entry[@"nonce"];
    NSData *iv = [[NSData alloc] initWithBase64EncodedString:entry[@"iv"] options:0];
    NSData *token = XSChannelToken(secret);
    check([str(XSJSONData(body)) isEqualToString:entry[@"bodyJSON"]], [name stringByAppendingString:@": v2 plaintext JSON"]);
    NSData *ct = XSAESCTR(XSChannelEncKey(secret), iv, XSJSONData(body));
    check([[ct base64EncodedStringWithOptions:0] isEqualToString:entry[@"body"]], [name stringByAppendingString:@": v2 ciphertext"]);
    NSString *signedString = ct ? XSRequestSignedStringV2(token, ts, nonce, iv, ct) : @"";
    check([signedString isEqualToString:entry[@"signedString"]], [name stringByAppendingString:@": v2 signed string"]);
    NSData *mac = XSHMACSHA256(XSChannelMacKey(secret), [signedString dataUsingEncoding:NSUTF8StringEncoding]);
    check([[mac base64EncodedStringWithOptions:0] isEqualToString:entry[@"mac"]], [name stringByAppendingString:@": v2 MAC"]);
    NSData *line = XSSealRequestV2WithIV(body, secret, ts, nonce, iv);
    check([str(line) isEqualToString:[entry[@"line"] stringByAppendingString:@"\n"]], [name stringByAppendingString:@": v2 request line"]);
}

/// A line's JSON object with `key` set to `value` (nil removes it), as a line.
static NSData *withField(NSString *line, NSString *key, id value) {
    NSMutableDictionary *o = [[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] mutableCopy];
    o[key] = value;
    return XSJSONData(o);
}

/// `b64` with byte `index` flipped.
static NSString *flipped(NSString *b64, NSUInteger index) {
    NSMutableData *d = [[[NSData alloc] initWithBase64EncodedString:b64 options:0] mutableCopy];
    ((uint8_t *)d.mutableBytes)[index] ^= 1;
    return [d base64EncodedStringWithOptions:0];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: %s channel-fixture.json\n", argv[0]); return 2; }
        NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
        NSDictionary *fx = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (![fx isKindOfClass:NSDictionary.class]) { fprintf(stderr, "unreadable fixture\n"); return 2; }
        NSData *secret = hex(fx[@"secretHex"]);

        // Requests: the exact bytes XSide expects.
        requestCase(fx[@"refreshRequest"], secret, XSRefreshBody(), @"refresh");
        NSDictionary *last = @{@"at": ms(1799990000500), @"succeeded": @NO, @"reasonKey": @"refresh.reason.offline"};
        requestCase(fx[@"checkInRequest"], secret, XSCheckInBody(fixtureSettings(), last, @"2.3.1", 45), @"checkIn");
        check([str(XSJSONData(XSSetAutoRefreshBody(NO))) isEqualToString:@"{\"on\":false,\"type\":\"setAutoRefresh\"}"],
              @"setAutoRefresh body");

        // The settings reply: opened, bound to its request, settings read back.
        NSDictionary *reply = fx[@"settingsReply"];
        NSString *iid = reply[@"installationID"], *nonce = reply[@"nonce"];
        NSData *line = [reply[@"line"] dataUsingEncoding:NSUTF8StringEncoding];
        check([XSReplySignedString(iid, nonce, [reply[@"bodyJSON"] dataUsingEncoding:NSUTF8StringEncoding])
               isEqualToString:reply[@"signedString"]], @"reply: signed string");
        NSDictionary *body = nil;
        XSReplyStatus status = XSOpenReply(line, secret, iid, nonce, &body);
        check(status == XSReplyOK && [body[@"type"] isEqual:@"settings"], @"reply: opens");
        NSDictionary *settings = XSSettingsFromJSONObject(body[@"settings"]);
        check(settings && sameSettings(settings, fixtureSettings()), @"reply: settings read back");
        NSDictionary *outcome = XSRefreshOutcomeFromJSONObject(body[@"lastRefresh"]);
        check(outcome && XSMillis(outcome[@"at"]) == 1799995000250 && [outcome[@"succeeded"] isEqual:@NO]
              && [outcome[@"reasonKey"] isEqual:@"deviceLocked"], @"reply: refresh outcome read back");
        check(XSRefreshOutcomeFromJSONObject(@{@"at": @1, @"succeeded": @1}) == nil
              && XSRefreshOutcomeFromJSONObject(@{@"succeeded": @YES}) == nil, @"refresh outcome: malformed refused");
        NSMutableData *withNewline = [line mutableCopy];
        [withNewline appendBytes:"\n" length:1];
        check(XSOpenReply(withNewline, secret, iid, nonce, NULL) == XSReplyOK, @"reply: with its newline");
        check(XSOpenReply(line, secret, iid, @"other", NULL) == XSReplyInvalid, @"reply: other nonce refused");
        check(XSOpenReply(line, secret, @"rec|other", nonce, NULL) == XSReplyInvalid, @"reply: other installation refused");
        check(XSOpenReply(line, hex(@"ff"), iid, nonce, NULL) == XSReplyInvalid, @"reply: other secret refused");
        NSString *tampered = [reply[@"line"] stringByReplacingOccurrencesOfString:reply[@"mac"]
                                                                       withString:[@"A" stringByAppendingString:[reply[@"mac"] substringFromIndex:1]]];
        check(XSOpenReply([tampered dataUsingEncoding:NSUTF8StringEncoding], secret, iid, nonce, NULL) == XSReplyInvalid,
              @"reply: tampered MAC refused");
        check(XSOpenReply([@"{\"type\":\"rejected\"}\n" dataUsingEncoding:NSUTF8StringEncoding], secret, iid, nonce, NULL)
              == XSReplyUnknownInstallation, @"reply: bare rejected");
        check(XSOpenReply([@"{\"type\":\"refreshed\"}" dataUsingEncoding:NSUTF8StringEncoding], secret, iid, nonce, NULL)
              == XSReplyInvalid, @"reply: unsigned refreshed refused");
        check(XSOpenReply([@"garbage" dataUsingEncoding:NSUTF8StringEncoding], secret, iid, nonce, NULL) == XSReplyInvalid,
              @"reply: garbage refused");
        check(XSCanonicalBase64(@"eyJ0eXBlIjoicmVmcmVzaCJ9") != nil && XSCanonicalBase64(@"eyJ0eXBlIjoicmVmcmVzaCJ9\n") == nil
              && XSCanonicalBase64(@"QQ") == nil, @"canonical base64");

        // Review D–G minor 7: a Mac pause of a while says when it ends.
        NSDictionary *pausedEntry = fx[@"pausedReply"], *pausedBody = nil;
        check(XSOpenReply([pausedEntry[@"line"] dataUsingEncoding:NSUTF8StringEncoding], secret, iid, pausedEntry[@"nonce"], &pausedBody) == XSReplyOK
              && [XSSettingValue(XSSettingsFromJSONObject(pausedBody[@"settings"]) ?: @{}, @"autoRefresh") isEqual:@NO]
              && XSMillis(XSPausedUntilFromReply(pausedBody)) == 1800007220000, @"paused reply: its end read back");
        check(XSPausedUntilFromReply(body) == nil && XSPausedUntilFromReply(@{@"pausedUntil": @YES}) == nil
              && XSPausedUntilFromReply(@{@"pausedUntil": @1.5}) == nil && XSPausedUntilFromReply(@{@"pausedUntil": @"1"}) == nil
              && XSPausedUntilFromReply(@{@"pausedUntil": @(-1)}) == nil, @"paused reply: absent or malformed end ignored");
        NSTimeZone *utc = [NSTimeZone timeZoneForSecondsFromGMT:0];
        NSDate *end = XSDateFromMillis(1800007220000); // 2027-01-15 10:00:20 UTC
        check([XSPauseEndHint(end, YES, utc) hasPrefix:@"Reprend tout seul le 15"] && [XSPauseEndHint(end, YES, utc) hasSuffix:@" à 10:00"]
              && [XSPauseEndHint(end, NO, utc) hasPrefix:@"Resumes by itself on 15"] && [XSPauseEndHint(end, NO, utc) hasSuffix:@" at 10:00"],
              @"pause end hint, fr and en");

        // Device feedback 4: the watch request, and the lines XSide writes on it.
        NSDictionary *watchLast = nil;
        requestCase(fx[@"watchRequest"], secret, XSWatchBody(fixtureSettings(), watchLast, @"2.3.1", NO), @"watch");

        // The run marker's report and the watch's goodbye (crashes seen at once).
        NSDictionary *crashedRun = @{@"ended": @"crashed", @"since": ms(1799999900125)};
        requestCase(fx[@"crashedRunCheckIn"], secret,
                    XSWithRunReport(XSCheckInBody(fixtureSettings(), nil, @"2.3.1", 15), crashedRun), @"checkIn with a crashed run");
        requestCase(fx[@"byeWatchRequest"], secret,
                    XSWithRunReport(XSWatchBody(fixtureSettings(), nil, @"2.3.1", YES), @{@"ended": @"clean", @"since": ms(1799999000000)}),
                    @"watch that says goodbye, with a clean run");
        requestCase(fx[@"byeRequest"], secret, XSByeBody(), @"bye");
        NSDictionary *plain = XSCheckInBody(fixtureSettings(), nil, @"2.3.1", 15);
        check([XSWithRunReport(plain, nil) isEqual:plain] && [XSWithRunReport(plain, @{@"ended": @"exploded", @"since": ms(1)}) isEqual:plain]
              && [XSWithRunReport(plain, @{@"ended": @"crashed", @"since": @1}) isEqual:plain]
              && [XSWithRunReport(plain, (NSDictionary *)@"x") isEqual:plain], @"run report: none or malformed leaves the body alone");

        // The run marker's state machine.
        NSDate *l0 = ms(1800000000000), *l1 = ms(1800000060000), *l2 = ms(1800000120000), *l3 = ms(1800000180000);
        NSDictionary *first = XSRunMarkerAtLaunch(nil, l0);
        check([first[@"state"] isEqual:@"running"] && [first[@"since"] isEqual:l0] && XSRunMarkerReport(first) == nil,
              @"marker: first launch, running, nothing to report");
        // Crashed in front: still "running" on disk at the next launch.
        NSDictionary *afterCrash = XSRunMarkerAtLaunch(XSRunMarkerPlist(first), l1);
        NSDictionary *rep = XSRunMarkerReport(afterCrash);
        check([rep[@"ended"] isEqual:@"crashed"] && XSMillis(rep[@"since"]) == XSMillis(l0) && [afterCrash[@"state"] isEqual:@"running"]
              && [afterCrash[@"since"] isEqual:l1], @"marker: a run that stopped in front is reported crashed, since its start");
        // Went to the background, then killed there (or terminated): clean.
        NSDictionary *bg = XSRunMarkerWithState(first, NO, l1);
        NSDictionary *afterClean = XSRunMarkerAtLaunch(XSRunMarkerPlist(bg), l2);
        check([XSRunMarkerReport(afterClean)[@"ended"] isEqual:@"clean"] && XSMillis(XSRunMarkerReport(afterClean)[@"since"]) == XSMillis(l0),
              @"marker: a run that left the front is reported clean");
        // Back to the front: running since then; already in front: unchanged.
        NSDictionary *back = XSRunMarkerWithState(bg, YES, l2);
        check([back[@"state"] isEqual:@"running"] && [back[@"since"] isEqual:l2]
              && [XSRunMarkerWithState(back, YES, l3)[@"since"] isEqual:l2], @"marker: back in front, since its return");
        NSDictionary *crashAfterReturn = XSRunMarkerAtLaunch(XSRunMarkerPlist(back), l3);
        check([XSRunMarkerReport(crashAfterReturn)[@"ended"] isEqual:@"crashed"]
              && XSMillis(XSRunMarkerReport(crashAfterReturn)[@"since"]) == XSMillis(l2), @"marker: a crash after a return dates from the return");
        // The report stays until acknowledged, through state changes.
        NSDictionary *kept = XSRunMarkerWithState(XSRunMarkerWithState(afterCrash, NO, l2), YES, l3);
        check([XSRunMarkerReport(kept) isEqual:rep], @"marker: the report survives leaving and coming back");
        check(XSRunMarkerReport(XSRunMarkerAcknowledged(kept, rep)) == nil, @"marker: acknowledged, the report goes");
        check([XSRunMarkerReport(XSRunMarkerAcknowledged(kept, @{@"ended": @"clean", @"since": l0})) isEqual:rep]
              && [XSRunMarkerReport(XSRunMarkerAcknowledged(kept, nil)) isEqual:rep], @"marker: another report's reply leaves it");
        // Never acknowledged (no Mac around): a crash isn't lost to a later clean run.
        NSDictionary *unsent = XSRunMarkerWithState(afterCrash, NO, l2);
        NSDictionary *next = XSRunMarkerAtLaunch(XSRunMarkerPlist(unsent), l3);
        check([XSRunMarkerReport(next)[@"ended"] isEqual:@"crashed"] && XSMillis(XSRunMarkerReport(next)[@"since"]) == XSMillis(l0),
              @"marker: an unsent crash outlives a clean run");
        NSDictionary *twice = XSRunMarkerAtLaunch(XSRunMarkerPlist(afterCrash), l3);
        check(XSMillis(XSRunMarkerReport(twice)[@"since"]) == XSMillis(l1), @"marker: a newer crash replaces an unsent one");
        // Whatever is on disk, a launch gets a sound marker.
        NSArray *hostile = @[@"x", @[], @{}, @{@"state": @"running"}, @{@"state": @"weird", @"since": @1},
                             @{@"state": @"running", @"since": @YES}, @{@"state": @"running", @"since": @(-5)},
                             @{@"state": @"running", @"since": @1e300}, @{@"state": @"clean", @"since": @"1"}];
        BOOL sound = YES;
        for (id raw in hostile) {
            NSDictionary *m = XSRunMarkerAtLaunch(raw, l0);
            sound = sound && [m[@"state"] isEqual:@"running"] && XSRunMarkerReport(m) == nil && XSRunMarkerSanitized(raw) == nil;
        }
        check(sound, @"marker: hostile or broken files are ignored");
        NSDictionary *badReport = XSRunMarkerSanitized(@{@"state": @"clean", @"since": @1800000000000,
                                                         @"report": @{@"ended": @"crashed", @"since": @"no"}});
        check(badReport && badReport[@"report"] == nil, @"marker: a broken report is dropped, the rest kept");
        NSDictionary *round = XSRunMarkerSanitized(XSRunMarkerPlist(afterCrash));
        check([round[@"state"] isEqual:@"running"] && XSMillis(round[@"since"]) == XSMillis(l1)
              && [XSRunMarkerReport(round)[@"ended"] isEqual:@"crashed"]
              && [NSPropertyListSerialization propertyList:XSRunMarkerPlist(afterCrash) isValidForFormat:NSPropertyListBinaryFormat_v1_0],
              @"marker: stored as a property list and read back");
        NSDictionary *liveEntry = fx[@"liveLine"], *aliveEntry = fx[@"aliveLine"];
        NSString *wnonce = liveEntry[@"nonce"];
        NSData *live = [liveEntry[@"line"] dataUsingEncoding:NSUTF8StringEncoding];
        NSData *alive = [aliveEntry[@"line"] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *pushed = nil;
        check(XSOpenWatchLine(live, secret, iid, wnonce, 0, &pushed) == XSReplyOK && [pushed[@"type"] isEqual:@"live"]
              && [XSSettingValue(XSSettingsFromJSONObject(pushed[@"settings"]) ?: @{}, @"reminder") isEqual:@YES]
              && [XSSettingsFromJSONObject(pushed[@"settings"])[@"reminder"][@"changedBy"] isEqual:@"mac"],
              @"watch: live line opens, with the Mac's change");
        check(XSOpenWatchLine(alive, secret, iid, wnonce, 1, &pushed) == XSReplyOK && [pushed[@"type"] isEqual:@"alive"],
              @"watch: alive line opens after it");
        check(XSOpenWatchLine(live, secret, iid, wnonce, 1, NULL) == XSReplyInvalid
              && XSOpenWatchLine(live, secret, iid, wnonce, 2, NULL) == XSReplyInvalid,
              @"watch: a replayed line is refused");
        check(XSOpenWatchLine(alive, secret, iid, wnonce, 0, NULL) == XSReplyInvalid, @"watch: a skipped line is refused");
        check(XSOpenWatchLine(live, secret, iid, @"another-watch", 0, NULL) == XSReplyInvalid
              && XSOpenWatchLine(live, secret, @"rec|other", wnonce, 0, NULL) == XSReplyInvalid,
              @"watch: a line from another watch or installation is refused");
        NSString *forgedLive = [liveEntry[@"line"] stringByReplacingOccurrencesOfString:liveEntry[@"mac"]
                                                                             withString:[@"A" stringByAppendingString:[liveEntry[@"mac"] substringFromIndex:1]]];
        check(XSOpenWatchLine([forgedLive dataUsingEncoding:NSUTF8StringEncoding], secret, iid, wnonce, 0, NULL) == XSReplyInvalid
              && XSOpenWatchLine(live, hex(@"ff"), iid, wnonce, 0, NULL) == XSReplyInvalid,
              @"watch: a forged line (wrong MAC, other key) is refused");
        // A forged line signed with another key: the right shape, the wrong secret.
        NSData *otherKey = hex(@"ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100");
        NSData *forgedBody = XSJSONData(@{@"type": @"live", @"seq": @1, @"settings": XSSettingsJSONObject(fixtureSettings())});
        NSString *forgedMac = [XSHMACSHA256(otherKey, [XSReplySignedString(iid, wnonce, forgedBody) dataUsingEncoding:NSUTF8StringEncoding])
                               base64EncodedStringWithOptions:0];
        NSData *forgedLine = XSJSONData(@{@"installationID": iid, @"nonce": wnonce,
                                          @"body": [forgedBody base64EncodedStringWithOptions:0], @"mac": forgedMac});
        check(XSOpenWatchLine(forgedLine, secret, iid, wnonce, 0, NULL) == XSReplyInvalid
              && XSOpenWatchLine(forgedLine, otherKey, iid, wnonce, 0, NULL) == XSReplyOK,
              @"watch: a line signed with another key is refused (and opens only with that key)");
        check(XSOpenWatchLine([@"{\"type\":\"rejected\"}" dataUsingEncoding:NSUTF8StringEncoding], secret, iid, wnonce, 0, NULL) == XSReplyInvalid
              && XSOpenWatchLine([@"{\"seq\":1,\"type\":\"alive\"}" dataUsingEncoding:NSUTF8StringEncoding], secret, iid, wnonce, 0, NULL) == XSReplyInvalid
              && XSOpenWatchLine(line, secret, iid, nonce, 0, NULL) == XSReplyInvalid,
              @"watch: unsigned lines, bare rejected and non-watch replies are refused");
        // A Bool or fractional seq isn't a line number.
        NSData *(^signedBody)(NSDictionary *) = ^NSData *(NSDictionary *b) {
            NSData *json = XSJSONData(b);
            NSString *m = [XSHMACSHA256(secret, [XSReplySignedString(iid, wnonce, json) dataUsingEncoding:NSUTF8StringEncoding])
                           base64EncodedStringWithOptions:0];
            return XSJSONData(@{@"installationID": iid, @"nonce": wnonce, @"body": [json base64EncodedStringWithOptions:0], @"mac": m});
        };
        check(XSOpenWatchLine(signedBody(@{@"type": @"alive", @"seq": @YES}), secret, iid, wnonce, 0, NULL) == XSReplyInvalid
              && XSOpenWatchLine(signedBody(@{@"type": @"alive", @"seq": @1.5}), secret, iid, wnonce, 0, NULL) == XSReplyInvalid
              && XSOpenWatchLine(signedBody(@{@"type": @"alive", @"seq": @1}), secret, iid, wnonce, 0, NULL) == XSReplyOK,
              @"watch: seq must be the next integer");

        // Channel v2 (mega review C2): keys, sealed requests, opened replies, hostile lines.
        NSDictionary *v2 = fx[@"v2"];
        check([XSChannelEncKey(secret) isEqual:hex(v2[@"encKeyHex"])] && [XSChannelMacKey(secret) isEqual:hex(v2[@"macKeyHex"])]
              && [XSChannelToken(secret) isEqual:hex(v2[@"tokenHex"])], @"v2: HKDF keys and token match the Mac's");
        check(XSChannelToken(hex(@"ff")).length == 16 && ![XSChannelToken(hex(@"ff")) isEqual:XSChannelToken(secret)]
              && XSChannelToken([NSData data]) == nil, @"v2: another secret, another token; no secret, none");
        // NIST SP 800-38A F.5.5, first block.
        NSData *nk = hex(@"603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");
        NSData *nctr = hex(@"f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff");
        check([XSAESCTR(nk, nctr, hex(@"6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"))
               isEqual:hex(@"601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c5")]
              && XSAESCTR(nk, [nctr subdataWithRange:NSMakeRange(0, 15)], nctr) == nil
              && XSAESCTR([nk subdataWithRange:NSMakeRange(0, 31)], nctr, nctr) == nil, @"v2: AES-256-CTR (NIST vector, lengths)");
        requestCaseV2(v2[@"refreshRequest"], secret, XSRefreshBody(), @"v2 refresh");
        requestCaseV2(v2[@"checkInRequest"], secret, XSCheckInBody(fixtureSettings(), last, @"2.3.1", 45), @"v2 checkIn");
        requestCaseV2(v2[@"byeWatchRequest"], secret,
                      XSWithRunReport(XSWatchBody(fixtureSettings(), nil, @"2.3.1", YES), @{@"ended": @"clean", @"since": ms(1799999000000)}),
                      @"v2 bye watch");
        requestCaseV2(v2[@"byeRequest"], secret, XSByeBody(), @"v2 bye");
        NSData *r1 = XSSealRequestV2(XSRefreshBody(), secret, 1800000000000, @"n1");
        NSData *r2 = XSSealRequestV2(XSRefreshBody(), secret, 1800000000000, @"n1");
        check(r1 && r2 && ![r1 isEqual:r2] && ![str(r1) containsString:@"refresh"] && ![str(r1) containsString:@"rec|dev"]
              && [str(r1) containsString:@"\"v\":2"], @"v2: a random IV per request, nothing readable on the wire");
        check(XSSealRequestV2WithIV(XSRefreshBody(), secret, 1800000000000, @"n1", [NSData dataWithBytes:"0123456789abcde" length:15]) == nil
              && XSSealRequestV2(XSRefreshBody(), [NSData data], 1800000000000, @"n1") == nil
              && XSSealRequestV2(XSRefreshBody(), secret, 1800000000000, @"bad nonce") == nil, @"v2: sealing refuses bad IV, secret, nonce");

        NSDictionary *sr = v2[@"settingsReply"];
        NSString *srNonce = sr[@"nonce"], *srLine = sr[@"line"];
        NSData *srData = [srLine dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *v2body = nil;
        check(XSOpenReplyV2(srData, secret, srNonce, &v2body) == XSReplyOK && [v2body[@"type"] isEqual:@"settings"]
              && sameSettings(XSSettingsFromJSONObject(v2body[@"settings"]) ?: @{}, fixtureSettings())
              && XSMillis(XSRefreshOutcomeFromJSONObject(v2body[@"lastRefresh"])[@"at"]) == 1799995000250, @"v2 reply: opens, settings read back");
        NSMutableData *srNL = [srData mutableCopy];
        [srNL appendBytes:"\n" length:1];
        check(XSOpenReplyV2(srNL, secret, srNonce, NULL) == XSReplyOK, @"v2 reply: with its newline");
        check(XSOpenReplyV2(srData, secret, @"other", NULL) == XSReplyInvalid
              && XSOpenReplyV2(srData, hex(@"ff"), srNonce, NULL) == XSReplyInvalid, @"v2 reply: other nonce or secret refused");
        NSArray<NSData *> *hostileV2 = @[
            withField(srLine, @"body", flipped(sr[@"body"], 0)),              // tampered ciphertext
            withField(srLine, @"iv", flipped(sr[@"iv"], 15)),                 // tampered IV
            withField(srLine, @"token", flipped(sr[@"token"], 0)),            // another token
            withField(srLine, @"mac", flipped(sr[@"mac"], 31)),               // tampered MAC
            withField(srLine, @"iv", [[NSData dataWithBytes:"0123456789abcde" length:15] base64EncodedStringWithOptions:0]),
            withField(srLine, @"iv", [[NSData dataWithBytes:"0123456789abcdefg" length:17] base64EncodedStringWithOptions:0]),
            withField(srLine, @"iv", nil),
            withField(srLine, @"body", @""),
            withField(srLine, @"mac", @"QQ=="),
            withField(srLine, @"v", nil),                                     // not v2
            withField(srLine, @"v", @1),
            withField(srLine, @"v", @"2"),
            withField(srLine, @"v", @YES),
            withField(srLine, @"installationID", @"rec|dev"),                 // a v1 field
            [srData subdataWithRange:NSMakeRange(0, srData.length / 2)],     // truncated
            [srData subdataWithRange:NSMakeRange(0, srData.length - 1)],
        ];
        BOOL allRefused = YES;
        for (NSUInteger i = 0; i < hostileV2.count; i++) {
            if (XSOpenReplyV2(hostileV2[i], secret, srNonce, NULL) != XSReplyInvalid) { allRefused = NO; fprintf(stderr, "hostile %lu\n", (unsigned long)i); }
        }
        check(allRefused, @"v2 reply: truncated, wrong IV length, tampered fields, other token, v1/v2 confusion refused");
        NSMutableData *huge = [NSMutableData dataWithLength:64 * 1024 + 1];
        memset(huge.mutableBytes, 'a', huge.length);
        check(XSOpenReplyV2(huge, secret, srNonce, NULL) == XSReplyInvalid, @"v2 reply: over 64 KB refused");
        // No fallback: the v1 reply (well signed) isn't a v2 one, nor the reverse.
        check(XSOpenReplyV2(line, secret, nonce, NULL) == XSReplyInvalid
              && XSOpenReply(srData, secret, iid, srNonce, NULL) == XSReplyInvalid, @"v2 reply: v1 and v2 replies never mixed");
        check(XSOpenReplyV2([@"{\"type\":\"rejected\"}\n" dataUsingEncoding:NSUTF8StringEncoding], secret, srNonce, NULL)
              == XSReplyUnknownInstallation, @"v2 reply: bare rejected");
        // A reply MAC computed as a request's (other domain) is refused.
        NSData *srIV = [[NSData alloc] initWithBase64EncodedString:sr[@"iv"] options:0];
        NSData *srCT = [[NSData alloc] initWithBase64EncodedString:sr[@"body"] options:0];
        NSString *asRequest = [XSHMACSHA256(XSChannelMacKey(secret), [XSRequestSignedStringV2(XSChannelToken(secret), 0, srNonce, srIV, srCT)
                                                                     dataUsingEncoding:NSUTF8StringEncoding]) base64EncodedStringWithOptions:0];
        check(XSOpenReplyV2(withField(srLine, @"mac", asRequest), secret, srNonce, NULL) == XSReplyInvalid
              && [XSReplySignedStringV2(XSChannelToken(secret), srNonce, srIV, srCT) isEqualToString:sr[@"signedString"]],
              @"v2 reply: signed string, request-domain MAC refused");
        // A well-MACed body that isn't a reply object.
        NSData *(^sealReplyV2)(NSData *, NSString *) = ^NSData *(NSData *plain, NSString *rn) {
            NSData *riv = [NSData dataWithBytes:"ABCDEFGHIJKLMNOP" length:16];
            NSData *ct = XSAESCTR(XSChannelEncKey(secret), riv, plain);
            NSString *m = [XSHMACSHA256(XSChannelMacKey(secret), [XSReplySignedStringV2(XSChannelToken(secret), rn, riv, ct)
                                                                  dataUsingEncoding:NSUTF8StringEncoding]) base64EncodedStringWithOptions:0];
            return XSJSONData(@{@"v": @2, @"token": [XSChannelToken(secret) base64EncodedStringWithOptions:0], @"nonce": rn,
                                @"iv": [riv base64EncodedStringWithOptions:0], @"body": [ct base64EncodedStringWithOptions:0], @"mac": m});
        };
        check(XSOpenReplyV2(sealReplyV2([@"not json" dataUsingEncoding:NSUTF8StringEncoding], srNonce), secret, srNonce, NULL) == XSReplyInvalid
              && XSOpenReplyV2(sealReplyV2([@"[1]" dataUsingEncoding:NSUTF8StringEncoding], srNonce), secret, srNonce, NULL) == XSReplyInvalid
              && XSOpenReplyV2(sealReplyV2(XSJSONData(@{@"type": @"busy"}), srNonce), secret, srNonce, NULL) == XSReplyOK,
              @"v2 reply: an authentic non-reply body refused (and a real one opens)");

        // v2 watch lines.
        NSDictionary *live2 = v2[@"liveLine"], *a2 = v2[@"aliveLine"];
        NSString *w2 = live2[@"nonce"];
        NSData *l2d = [live2[@"line"] dataUsingEncoding:NSUTF8StringEncoding], *a2d = [a2[@"line"] dataUsingEncoding:NSUTF8StringEncoding];
        check(XSOpenWatchLineV2(l2d, secret, w2, 0, &pushed) == XSReplyOK && [pushed[@"type"] isEqual:@"live"]
              && [XSSettingValue(XSSettingsFromJSONObject(pushed[@"settings"]) ?: @{}, @"reminder") isEqual:@YES]
              && XSOpenWatchLineV2(a2d, secret, w2, 1, &pushed) == XSReplyOK && [pushed[@"type"] isEqual:@"alive"],
              @"v2 watch: live then alive open");
        check(XSOpenWatchLineV2(l2d, secret, w2, 1, NULL) == XSReplyInvalid && XSOpenWatchLineV2(a2d, secret, w2, 0, NULL) == XSReplyInvalid
              && XSOpenWatchLineV2(l2d, secret, @"other", 0, NULL) == XSReplyInvalid
              && XSOpenWatchLineV2(srData, secret, srNonce, 0, NULL) == XSReplyInvalid
              && XSOpenWatchLineV2(live, secret, wnonce, 0, NULL) == XSReplyInvalid
              && XSOpenWatchLine(l2d, secret, iid, w2, 0, NULL) == XSReplyInvalid
              && XSOpenWatchLineV2([@"{\"type\":\"rejected\"}" dataUsingEncoding:NSUTF8StringEncoding], secret, w2, 0, NULL) == XSReplyInvalid
              && XSOpenWatchLineV2(withField(live2[@"line"], @"body", flipped(live2[@"body"], 3)), secret, w2, 0, NULL) == XSReplyInvalid,
              @"v2 watch: replayed, skipped, other watch, settings reply, v1 line, bare rejected, tampered refused");
        check(XSOpenWatchLineV2(sealReplyV2(XSJSONData(@{@"type": @"alive", @"seq": @YES}), w2), secret, w2, 0, NULL) == XSReplyInvalid
              && XSOpenWatchLineV2(sealReplyV2(XSJSONData(@{@"type": @"alive", @"seq": @1}), w2), secret, w2, 0, NULL) == XSReplyOK,
              @"v2 watch: seq must be the next integer");

        // Nonces.
        check(XSNonceValid(@"n1") && XSNonceValid(@"a-b_C9") && !XSNonceValid(@"") && !XSNonceValid(@"a|b")
              && !XSNonceValid([@"" stringByPaddingToLength:65 withString:@"a" startingAtIndex:0]), @"nonce validation");
        NSString *n = XSNewNonce();
        check(XSNonceValid(n) && ![n isEqualToString:XSNewNonce()], @"new nonces are valid and differ");

        // Merge: InAppSettingsTests' cases.
        NSDate *t0 = [NSDate dateWithTimeIntervalSince1970:1800000000];
        NSDate *(^at)(double) = ^(double s) { return [t0 dateByAddingTimeInterval:s]; };
        NSDictionary *base = XSSettingsDefaults(YES, t0);
        NSDictionary *mac = XSSettingsSetting(base, @"language", @"fr", at(2), @"mac");
        mac = XSSettingsSetting(mac, @"reminder", @NO, at(1), @"mac");
        NSDictionary *dev = XSSettingsSetting(base, @"reminder", @YES, at(3), @"device");
        dev = XSSettingsSetting(dev, @"refreshCard", @NO, at(1), @"device");
        dev = XSSettingsSetting(dev, @"language", @"en", at(1), @"device");
        for (NSDictionary *m in @[XSSettingsMerge(mac, dev), XSSettingsMerge(dev, mac)]) {
            check([XSSettingValue(m, @"language") isEqual:@"fr"] && [XSSettingValue(m, @"reminder") isEqual:@YES]
                  && [m[@"reminder"][@"changedBy"] isEqual:@"device"] && [XSSettingValue(m, @"refreshCard") isEqual:@NO]
                  && [m[@"showValidity"] isEqual:base[@"showValidity"]], @"merge keeps the newest change per field");
        }
        NSDictionary *tm = XSSettingsSetting(base, @"alertLate", @NO, at(5), @"mac");
        NSDictionary *td = XSSettingsSetting(base, @"alertLate", @YES, at(5), @"device");
        check([XSSettingValue(XSSettingsMerge(tm, td), @"alertLate") isEqual:@YES]
              && [XSSettingValue(XSSettingsMerge(td, tm), @"alertLate") isEqual:@YES], @"tie goes to the device");
        NSDictionary *d0 = XSSettingsDefaults(NO, t0);
        check(!XSSettingBool(d0, @"reminder") && XSSettingBool(d0, @"showValidity") && XSSettingBool(d0, @"alertLate")
              && XSSettingBool(d0, @"refreshCard") && XSSettingBool(d0, @"autoRefresh")
              && d0[@"level"] == nil && [XSSettingValue(d0, @"language") isEqual:@"automatic"],
              @"defaults");
        NSDictionary *partial = XSSettingsSanitized(@{@"alertLate": field(@"bogus", 1, @"mac"), @"reminder": field(@NO, 7, @"device"),
                                                      @"level": field(@"none", 9, @"device"),
                                                      @"language": @"fr"}, base);
        check([XSSettingValue(partial, @"alertLate") isEqual:@YES] && [XSSettingValue(partial, @"reminder") isEqual:@NO]
              && partial[@"level"] == nil
              && [XSSettingValue(partial, @"language") isEqual:@"automatic"], @"sanitized: invalid fields fall back");

        // Visibility and level: InAppSettingsTests.visibilityFollowsTheFourSwitches / levelIsDerived….
        NSDictionary *(^S)(BOOL, BOOL, BOOL, BOOL) = ^(BOOL validity, BOOL alert, BOOL card, BOOL reminder) {
            NSDictionary *s = XSSettingsDefaults(reminder, t0);
            s = XSSettingsSetting(s, @"showValidity", @(validity), t0, @"mac");
            s = XSSettingsSetting(s, @"alertLate", @(alert), t0, @"mac");
            return XSSettingsSetting(s, @"refreshCard", @(card), t0, @"mac");
        };
        BOOL rows[4][6] = {{1, 1, 1, 0, 0, 1}, {0, 1, 0, 0, 0, 1}, {1, 0, 1, 0, 1, 0}, {0, 0, 0, 0, 0, 0}};
        BOOL matrix = YES;
        for (int i = 0; i < 4; i++) {
            NSDictionary *s = S(rows[i][0], rows[i][1], YES, YES);
            matrix = matrix && XSShowsValidityPill(s, NO) == rows[i][2] && XSShowsLatePill(s, NO) == rows[i][3]
                && XSShowsValidityPill(s, YES) == rows[i][4] && XSShowsLatePill(s, YES) == rows[i][5];
        }
        check(matrix, @"visibility matrix");
        check(!XSShowsRefreshCard(S(YES, YES, NO, YES)) && XSShowsRefreshCard(S(NO, NO, YES, NO))
              && !XSSchedulesReminder(S(YES, YES, YES, NO)) && XSSchedulesReminder(S(NO, NO, NO, YES)), @"card and reminder: own switch");
        BOOL sheet = !XSShowsInstallSheet(S(NO, NO, NO, NO));
        for (int i = 0; i < 4; i++) sheet = sheet && XSShowsInstallSheet(S(i == 0, i == 1, i == 2, i == 3));
        check(sheet, @"install sheet unless all four are off");
        check([XSDerivedLevel(S(YES, YES, YES, YES)) isEqual:@"all"] && [XSDerivedLevel(S(NO, YES, NO, YES)) isEqual:@"essentials"]
              && [XSDerivedLevel(S(NO, NO, NO, NO)) isEqual:@"none"] && [XSDerivedLevel(S(YES, YES, NO, YES)) isEqual:@"custom"]
              && [XSDerivedLevel(S(NO, YES, NO, NO)) isEqual:@"custom"], @"derived level");
        check(XSIsLate(41 * 3600, 48) && !XSIsLate(43 * 3600, 48) && XSIsLate(17 * 3600, 24), @"late = threshold - 6 h");

        // Device feedback 2026-11-08: off on the phone (t1), back on from the Mac (t2), app opened.
        NSDictionary *(^values)(NSDictionary *) = ^(NSDictionary *st) {
            NSMutableDictionary *v = [NSMutableDictionary dictionary];
            for (NSString *f in XSSettingFields()) v[f] = XSSettingValue(st, f);
            return (NSDictionary *)v;
        };
        NSDictionary *shown = values(base); // the iOS Settings rows and their shadow, as last written
        NSMutableDictionary *rowsOff = [shown mutableCopy];
        rowsOff[@"autoRefresh"] = @NO; // turned off in iOS Settings
        NSDictionary *phoneOff = XSSettingsNoticingRowChanges(base, rowsOff, shown, at(10));
        check([phoneOff[@"autoRefresh"] isEqual:field(@NO, XSMillis(at(10)), @"device")]
              && [phoneOff[@"reminder"] isEqual:base[@"reminder"]], @"a row changed in iOS Settings is a device change dated now");
        // Reported; the Mac resumes at t2 = 20 s; the next check-in's reply is adopted (merged, stored,
        // rows and shadow rewritten together).
        NSDictionary *macReply = XSSettingsSetting(phoneOff, @"autoRefresh", @YES, at(20), @"mac");
        NSDictionary *adopted = XSSettingsMerge(phoneOff, macReply);
        check([adopted[@"autoRefresh"] isEqual:field(@YES, XSMillis(at(20)), @"mac")], @"the Mac's newer resume wins on the phone");
        NSDictionary *again = XSSettingsNoticingRowChanges(adopted, values(adopted), values(adopted), at(30));
        check([again isEqual:adopted], @"adopted values written to the rows are not re-stamped as the phone's");
        // Final review minor 6: an answer to a Refresh that came while the person was away is shown
        // on return, if still recent; a pill still in progress (no duration) is not kept.
        check(XSKeepsAnswerForReturn(NO, 8) && !XSKeepsAnswerForReturn(YES, 8) && !XSKeepsAnswerForReturn(NO, 0),
              @"answer kept for the return only when away, and only a final one");
        check(XSKeptAnswerStillFresh(at(0), at(XSKeptAnswerLifetime)) && !XSKeptAnswerStillFresh(at(0), at(XSKeptAnswerLifetime + 1))
              && !XSKeptAnswerStillFresh(nil, at(0)), @"kept answer: shown within its lifetime only");

        // Final review minor 1: a change made in iOS Settings while the app was closed is dated by
        // the preferences file's modification (iOS Settings writes it then), kept between the last
        // time the library looked at the rows and now; without a file date, now.
        check([XSRowChangeDate(at(5), at(1), at(9)) isEqual:at(5)], @"row change dated by the file");
        check([XSRowChangeDate(at(12), at(1), at(9)) isEqual:at(9)] && [XSRowChangeDate(nil, at(1), at(9)) isEqual:at(9)],
              @"row change: never after now");
        check([XSRowChangeDate(at(0), at(3), at(9)) isEqual:at(3)] && [XSRowChangeDate(at(0), nil, at(9)) isEqual:at(0)]
              && [XSRowChangeDate(at(0), at(20), at(9)) isEqual:at(9)], @"row change: never before the library last looked");
        // Mega review minor 1: the first load of a run uses the file date captured when the library
        // loaded, before the app wrote its own preferences at launch; later loads the live one.
        check([XSPrefsDateForLoad(at(2), at(8), YES) isEqual:at(2)] && [XSPrefsDateForLoad(at(2), at(8), NO) isEqual:at(8)],
              @"prefs date: captured at start for the first load, live after");
        check(XSPrefsDateForLoad(nil, at(8), YES) == nil && [XSPrefsDateForLoad(nil, at(8), NO) isEqual:at(8)],
              @"prefs date: no file at start means no change made while closed");
        // Mega review minor 5: the row's title as written at signing (the Mac's language when the
        // app has no lproj), read from the app's Settings.bundle, so the hint quotes what iOS shows.
        NSDictionary *page = @{@"StringsTable": @"Main", @"PreferenceSpecifiers": @[
            @{@"Type": @"PSGroupSpecifier", @"Title": @"App"},
            @{@"Type": @"PSChildPaneSpecifier", @"Title": @"Réglages XSide", @"File": @"XSide",
              @"Key": @"io.github.xside.settings.pane"}]};
        check([XSSettingsRowTitle(page) isEqual:@"Réglages XSide"] && [XSSettingsRowTable(page) isEqual:@"Main"],
              @"settings row: title and table from the app's page");
        check(XSSettingsRowTitle(@{@"PreferenceSpecifiers": @[@{@"Title": @"Other", @"Key": @"x"}]}) == nil
              && XSSettingsRowTitle(nil) == nil && XSSettingsRowTitle(@"junk") == nil
              && [XSSettingsRowTable(@{}) isEqual:@"Root"], @"settings row: none without XSide's, Root by default");
        // A return from the background checks in too (the Mac's change must reach a running app),
        // but not again within a few seconds of the last one.
        check(XSShouldCheckInOnReturn(NO, NO, nil, at(0)) && XSShouldCheckInOnReturn(NO, NO, at(-60), at(0))
              && !XSShouldCheckInOnReturn(NO, NO, at(-5), at(0)) && XSShouldCheckInOnReturn(YES, NO, at(-5), at(0))
              && XSShouldCheckInOnReturn(NO, YES, at(-5), at(0)), @"check-in on return from the background");

        // Device feedback round 1, B4: what a check-in reply changed, and who changed it.
        NSDictionary *fromMac = XSSettingsSetting(XSSettingsSetting(adopted, @"reminder", @NO, at(40), @"mac"),
                                                  @"showValidity", @YES, at(41), @"mac"); // same value: not a change
        fromMac = XSSettingsSetting(fromMac, @"language", @"en", at(42), @"device");
        check([XSChangedFields(adopted, fromMac) isEqual:(@[@"reminder", @"language"])], @"changed fields: values only, in field order");
        check([XSFieldsChangedByMac(adopted, fromMac) isEqual:@[@"reminder"]], @"fields changed by the Mac");
        check(XSFieldsChangedByMac(adopted, adopted).count == 0 && XSChangedFields(adopted, again).count == 0,
              @"nothing changed: no field");

        // Which pills show: none at all with every message off; the Mac's news under the refresh card.
        check(!XSShowsPills(S(NO, NO, NO, NO)) && XSShowsPills(S(NO, NO, NO, YES)) && XSShowsPills(S(YES, NO, NO, NO)),
              @"pills: only \"Aucun\" silences them all");
        // Ledger ruling: the answers to something the person just asked (a Refresh and its outcome)
        // show even with every message off; silence would look broken.
        check(XSShowsPill(S(NO, NO, NO, NO), YES) && !XSShowsPill(S(NO, NO, NO, NO), NO)
              && XSShowsPill(S(NO, NO, NO, YES), NO) && XSShowsPill(S(YES, YES, YES, YES), YES),
              @"pills: answers to the person show even with \"Aucun\"");
        // Device feedback 3, E2: a change made on the Mac is told unless every message is off,
        // before and after it (it no longer depends on "Carte après rafraîchissement", whose own
        // change from the Mac was never told).
        check(XSShowsMacUpdatePill(S(YES, YES, YES, YES), S(YES, YES, NO, YES)) && XSShowsMacUpdatePill(S(NO, YES, NO, YES), S(NO, NO, NO, YES))
              && XSShowsMacUpdatePill(S(NO, YES, NO, NO), S(NO, NO, NO, NO)) && !XSShowsMacUpdatePill(S(NO, NO, NO, NO), S(NO, NO, NO, NO)),
              @"\"updated from your Mac\": unless every message is off before and after");

        // Device feedback 3, E2, the whole sequence on the phone: it holds the settings of its
        // signing; a poll's reply (JSON, dates in ms) carries the Mac's newer "Carte après
        // rafraîchissement"; adopted, it is the one field changed by the Mac, and its pill shows.
        NSDictionary *signedSettings = XSSettingsDefaults(YES, at(0));
        NSDictionary *macEdited = XSSettingsSetting(signedSettings, @"refreshCard", @NO, at(30.5), @"mac");
        NSDictionary *replied = XSSettingsFromJSONObject(XSSettingsJSONObject(macEdited));
        NSDictionary *adoptedReply = XSSettingsMerge(signedSettings, replied ?: @{});
        check(replied && [XSFieldsChangedByMac(signedSettings, adoptedReply) isEqual:@[@"refreshCard"]]
              && XSShowsMacUpdatePill(signedSettings, adoptedReply)
              && XSFieldsChangedByMac(adoptedReply, XSSettingsMerge(adoptedReply, replied ?: @{})).count == 0,
              @"sequence: the Mac's change in a poll's reply is adopted, named and told once");
        // A pill on screen holds the next one back only while it is really there.
        check(XSPillScreenFree(NO, NO, NO, 0, 0) && XSPillScreenFree(YES, YES, NO, 1, 5) && XSPillScreenFree(YES, NO, YES, 1, 5)
              && !XSPillScreenFree(YES, NO, NO, 4, 5) && !XSPillScreenFree(YES, NO, NO, 600, 0)
              && XSPillScreenFree(YES, NO, NO, 9, 5), @"pills: one whose time is over no longer holds the next back");

        // B1: the first-launch sheet's pages, and the local network explanation.
        check([XSSheetPages(YES, NO, NO, YES) isEqual:(@[@"welcome", @"network", @"notifications"])], @"sheet: three pages");
        check([XSSheetPages(NO, NO, NO, YES) isEqual:(@[@"welcome", @"notifications"])]
              && [XSSheetPages(YES, YES, NO, NO) isEqual:@[@"welcome"]]
              && [XSSheetPages(YES, NO, YES, NO) isEqual:@[@"welcome"]], @"sheet: no page for what needs no asking");
        check(XSNeedsNetworkExplanation(YES, NO, NO), @"network explained before the first access");
        check(!XSNeedsNetworkExplanation(NO, NO, NO) && !XSNeedsNetworkExplanation(YES, YES, NO)
              && !XSNeedsNetworkExplanation(YES, NO, YES), @"network: no channel, already allowed, or already explained");
        // Device feedback 3, E4: an app that uses the local network itself (YouTube's Cast) may
        // have made iOS ask before XSide's page; once a system alert was seen, XSide checks
        // silently first: allowed, no page; refused, a short page saying how to turn it back on;
        // unknown (no Mac found in time), the page as before.
        check(XSProbesNetworkFirst(YES, NO, NO, YES, YES) && !XSProbesNetworkFirst(YES, NO, NO, NO, YES)
              && !XSProbesNetworkFirst(YES, NO, NO, YES, NO) && !XSProbesNetworkFirst(YES, YES, NO, YES, YES)
              && !XSProbesNetworkFirst(YES, NO, YES, YES, YES) && !XSProbesNetworkFirst(NO, NO, NO, YES, YES),
              @"network: checked first only after a system alert, in an app that uses it itself");
        check(XSNetworkPageAfterProbe(XSNetworkProbeAllowed) == nil
              && [XSNetworkPageAfterProbe(XSNetworkProbeDenied) isEqual:@"networkDenied"]
              && [XSNetworkPageAfterProbe(XSNetworkProbeUnknown) isEqual:@"network"], @"network: page after the silent check");
        // Device feedback round 2, P4: the explanation comes before iOS asks whatever the messages
        // (it is not one of XSide's messages but what the iOS prompt is about), so it no longer
        // depends on the settings.

        // Device feedback round 2, P2: a change pill says what changed.
        NSDictionary *one = XSSettingsSetting(adopted, @"autoRefresh", @YES, at(50), @"mac");
        check([XSChangeTexts(@[@"autoRefresh"], one, YES, YES)[@"lead"]
                  isEqual:@"Rafraîchissement automatique réactivé depuis XSide sur ton Mac"]
              && [XSChangeTexts(@[@"autoRefresh"], one, YES, NO)[@"lead"]
                  isEqual:@"Automatic refresh turned back on from XSide on your Mac"]
              && XSChangeTexts(@[@"autoRefresh"], one, YES, YES)[@"list"] == nil, @"change pill: one field from the Mac says which");
        NSDictionary *offed = XSSettingsSetting(adopted, @"autoRefresh", @NO, at(50), @"mac");
        check([XSChangeTexts(@[@"autoRefresh"], offed, YES, YES)[@"lead"]
                  isEqual:@"Rafraîchissement automatique désactivé depuis XSide sur ton Mac"], @"change pill: turned off from the Mac");
        NSDictionary *rem = XSSettingsSetting(adopted, @"reminder", @NO, at(50), @"mac");
        check([XSChangeTexts(@[@"reminder"], rem, YES, YES)[@"lead"] isEqual:@"« Rappel avant l'expiration » désactivé depuis ton Mac"]
              && [XSChangeTexts(@[@"reminder"], rem, YES, NO)[@"lead"] isEqual:@"\"Reminder before expiry\" turned off from your Mac"],
              @"change pill: a switch from the Mac, by its row's name");
        NSDictionary *lang = XSSettingsSetting(adopted, @"language", @"en", at(50), @"mac");
        check([XSChangeTexts(@[@"language"], lang, YES, YES)[@"lead"] isEqual:@"« Langue des messages XSide » : English, depuis ton Mac"]
              && [XSChangeTexts(@[@"language"], lang, YES, NO)[@"lead"] isEqual:@"\"XSide messages language\": English, from your Mac"],
              @"change pill: the language from the Mac");
        NSDictionary *two = XSSettingsSetting(rem, @"autoRefresh", @YES, at(51), @"mac");
        NSDictionary *both = XSChangeTexts(@[@"reminder", @"autoRefresh"], two, YES, YES);
        check([both[@"lead"] isEqual:@"Réglages mis à jour depuis ton Mac"]
              && [both[@"list"] isEqual:@"Rappel avant l'expiration : désactivé · Rafraîchissement automatique : activé"],
              @"change pill: several fields from the Mac, listed");
        check([XSChangeTexts(@[@"reminder", @"autoRefresh"], two, YES, NO)[@"list"]
                  isEqual:@"Reminder before expiry: off · Automatic refresh: on"], @"change pill: the list in English");
        // Phone -> Mac: the confirmation says what XSide now knows.
        check([XSChangeTexts(@[@"autoRefresh"], offed, NO, YES)[@"lead"]
                  isEqual:@"Rafraîchissement automatique désactivé : XSide sur ton Mac est au courant"]
              && [XSChangeTexts(@[@"autoRefresh"], one, NO, NO)[@"lead"]
                  isEqual:@"Automatic refresh turned back on: XSide on your Mac knows"], @"confirmation: automatic refresh");
        check([XSChangeTexts(@[@"reminder"], rem, NO, YES)[@"lead"]
                  isEqual:@"« Rappel avant l'expiration » désactivé : XSide sur ton Mac est au courant"],
              @"confirmation: one switch");
        check([XSChangeTexts(@[@"reminder", @"autoRefresh"], two, NO, YES)[@"lead"] isEqual:@"Réglages envoyés à XSide sur ton Mac"]
              && [XSChangeTexts(@[], two, NO, NO)[@"lead"] isEqual:@"Settings sent to XSide on your Mac"]
              && XSChangeTexts(@[], two, NO, NO)[@"list"] == nil, @"confirmation: several or unknown fields");

        // Device feedback round 2, P3: while the app is in front, XSide is asked every few seconds
        // (less often in Low Power Mode), only once the local network is allowed, and not right
        // after another check-in.
        check(XSForegroundPollInterval(NO) == 15 && XSForegroundPollInterval(YES) == 45, @"poll: 15 s, 45 s in Low Power Mode");
        check(XSShouldPoll(YES, YES, nil, at(0), NO, NO) && XSShouldPoll(YES, YES, at(-15), at(0), NO, NO)
              && !XSShouldPoll(YES, YES, at(-10), at(0), NO, NO) && !XSShouldPoll(YES, YES, at(-30), at(0), YES, NO)
              && XSShouldPoll(YES, YES, at(-45), at(0), YES, NO), @"poll: not again right after a check-in");
        check(!XSShouldPoll(NO, YES, nil, at(0), NO, NO) && !XSShouldPoll(YES, NO, nil, at(0), NO, NO),
              @"poll: never without the channel or before the local network was allowed");

        // Device feedback 4: a watch instead of the 15 s poll.
        check(!XSShouldPoll(YES, YES, nil, at(0), NO, YES) && !XSShouldPoll(YES, YES, at(-600), at(0), NO, YES),
              @"watch: no poll while a watch is open or opening");
        check(XSShouldOpenWatch(YES, YES, NO, nil, at(0)) && XSShouldOpenWatch(YES, YES, NO, at(0), at(0))
              && !XSShouldOpenWatch(YES, YES, NO, at(1), at(0)) && !XSShouldOpenWatch(YES, YES, YES, nil, at(0))
              && !XSShouldOpenWatch(NO, YES, NO, nil, at(0)) && !XSShouldOpenWatch(YES, NO, NO, nil, at(0)),
              @"watch: opened with the channel, once allowed, one at a time, after its retry time");
        check(XSWatchRetryDelay(YES, 300) == 0 && XSWatchRetryDelay(YES, 19) == 60 && XSWatchRetryDelay(NO, 300) == 60
              && XSWatchKeepAliveTimeout > 25, @"watch: again at once after a good one, a minute after a failed one");

        // Device feedback 3, E1: XSide's quick actions are static Info.plist items again (written
        // on the Mac); the library only handles them, and finds them in the Info.plist.
        check(XSIsXSideShortcutType(@"io.github.xside.shortcut.refresh") && !XSIsXSideShortcutType(@"com.app.search")
              && !XSIsXSideShortcutType(nil) && !XSIsXSideShortcutType(@3), @"quick actions: XSide's types");
        id infoItems = @[@{@"UIApplicationShortcutItemType": @"com.app.new"}, @"junk",
                         @{@"UIApplicationShortcutItemType": @"io.github.xside.shortcut.settings"}];
        check(XSInfoHasXSideShortcut(infoItems) && !XSInfoHasXSideShortcut(@[@{@"UIApplicationShortcutItemType": @"com.app.new"}])
              && !XSInfoHasXSideShortcut(nil) && !XSInfoHasXSideShortcut(@"x"), @"quick actions: XSide's found in the Info.plist items");

        // JSON round trip of the settings.
        check(sameSettings(XSSettingsFromJSONObject(XSSettingsJSONObject(fixtureSettings())) ?: @{}, fixtureSettings()),
              @"settings JSON round trip");
        NSMutableDictionary *missing = [XSSettingsJSONObject(fixtureSettings()) mutableCopy];
        [missing removeObjectForKey:@"alertLate"];
        check(XSSettingsFromJSONObject(missing) == nil, @"settings JSON with a missing field refused");
    }
    @autoreleasepool {
        // The tweak list XSide writes at signing (XSideWelcome.tweaks, PhoneTweaks on the Mac):
        // read as untrusted, never trusted for type, length or count.
        NSArray *good = XSTweaksSanitized(@[
            @{@"name": @"XSPivotFix", @"version": @"1.0", @"author": @"Anthony", @"summary": @"Puts the tab back.",
              @"converted": @NO, @"off": @NO},
            @{@"name": @"uYouPlus", @"version": @"3.0.5", @"author": @"MiRO92", @"converted": @YES, @"off": @NO},
            @{@"name": @"Shorts Remover", @"version": @"2.0", @"converted": @NO, @"off": @YES}]);
        check(good.count == 3 && [good[0][@"name"] isEqual:@"XSPivotFix"] && [good[0][@"summary"] isEqual:@"Puts the tab back."]
              && ![good[0][@"converted"] boolValue] && [good[1][@"converted"] boolValue] && [good[2][@"off"] boolValue]
              && good[1][@"summary"] == nil && good[2][@"author"] == nil, @"tweaks: the Mac's list read as written");
        check(XSTweaksInjectedCount(good) == 2, @"tweaks: N counts those in the app, not those off here");
        check([XSTweakVersionLine(good[0]) isEqual:@"1.0 · Anthony"] && [XSTweakVersionLine(good[2]) isEqual:@"2.0"]
              && [XSTweakVersionLine(@{@"name": @"X"}) isEqual:@"—"], @"tweaks: « version · auteur »");
        check(XSTweaksSanitized(nil).count == 0 && XSTweaksSanitized(@"x").count == 0 && XSTweaksSanitized(@{}).count == 0
              && XSTweaksSanitized(@[]).count == 0, @"tweaks: no list, or not a list: none");
        NSArray *odd = XSTweaksSanitized(@[@"junk", @3, @{}, @{@"name": @""}, @{@"name": @42}, @{@"name": @"   "},
                                           @{@"name": @"Kept", @"version": @7, @"author": @[@"a"], @"summary": NSNull.null,
                                             @"converted": @"yes", @"off": @{}}]);
        check(odd.count == 1 && [odd[0][@"name"] isEqual:@"Kept"] && odd[0][@"version"] == nil && odd[0][@"author"] == nil
              && odd[0][@"summary"] == nil && ![odd[0][@"converted"] boolValue] && ![odd[0][@"off"] boolValue],
              @"tweaks: entries of the wrong type dropped, fields of the wrong type left out");
        NSMutableArray *many = [NSMutableArray array];
        for (int i = 0; i < 5000; i++) [many addObject:@{@"name": [NSString stringWithFormat:@"T%d", i]}];
        check(XSTweaksSanitized(many).count == 64, @"tweaks: at most 64");
        NSString *huge = [@"" stringByPaddingToLength:100000 withString:@"é👍" startingAtIndex:0];
        NSDictionary *big = XSTweaksSanitized(@[@{@"name": huge, @"version": huge, @"author": huge, @"summary": huge}]).firstObject;
        check([big[@"name"] length] <= 128 * 2 && [big[@"version"] length] <= 64 * 2 && [big[@"author"] length] <= 128 * 2
              && [big[@"summary"] length] <= 1000 * 2 && [big[@"summary"] length] >= 1000, @"tweaks: lengths capped");
        NSString *cut = big[@"name"];
        check([cut rangeOfComposedCharacterSequenceAtIndex:cut.length - 1].location + [cut rangeOfComposedCharacterSequenceAtIndex:cut.length - 1].length
              == cut.length && [cut dataUsingEncoding:NSUTF8StringEncoding] != nil, @"tweaks: never cut inside a character");
    }
    if (failures) { fprintf(stderr, "%d check(s) failed\n", failures); return 1; }
    printf("all checks passed\n");
    return 0;
}
