// The dylib's channel frames and settings merge, compiled for the Mac by
// scripts/test-welcome-hmac.sh and checked against the Swift side's fixture
// (Tests/XSideCoreTests/Fixtures/channel-fixture.json, written by ChannelTests) and against the
// cases of InAppSettingsTests. Exits non-zero on the first difference.

#import <Foundation/Foundation.h>
#import "XSChannelCore.h"
#import "XSSettingsCore.h"

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
        @"level": field(@"essentials", 1799999000123, @"device"),
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
        requestCase(fx[@"checkInRequest"], secret, XSCheckInBody(fixtureSettings(), last, @"2.3.1"), @"checkIn");
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
        dev = XSSettingsSetting(dev, @"level", @"essentials", at(1), @"device");
        dev = XSSettingsSetting(dev, @"language", @"en", at(1), @"device");
        for (NSDictionary *m in @[XSSettingsMerge(mac, dev), XSSettingsMerge(dev, mac)]) {
            check([XSSettingValue(m, @"language") isEqual:@"fr"] && [XSSettingValue(m, @"reminder") isEqual:@YES]
                  && [m[@"reminder"][@"changedBy"] isEqual:@"device"] && [XSSettingValue(m, @"level") isEqual:@"essentials"]
                  && [m[@"showValidity"] isEqual:base[@"showValidity"]], @"merge keeps the newest change per field");
        }
        NSDictionary *tm = XSSettingsSetting(base, @"alertLate", @NO, at(5), @"mac");
        NSDictionary *td = XSSettingsSetting(base, @"alertLate", @YES, at(5), @"device");
        check([XSSettingValue(XSSettingsMerge(tm, td), @"alertLate") isEqual:@YES]
              && [XSSettingValue(XSSettingsMerge(td, tm), @"alertLate") isEqual:@YES], @"tie goes to the device");
        NSDictionary *d0 = XSSettingsDefaults(NO, t0);
        check(!XSSettingBool(d0, @"reminder") && !XSSettingBool(d0, @"showValidity") && XSSettingBool(d0, @"alertLate")
              && XSSettingBool(d0, @"refreshCard") && XSSettingBool(d0, @"autoRefresh")
              && [XSSettingValue(d0, @"level") isEqual:@"all"] && [XSSettingValue(d0, @"language") isEqual:@"automatic"],
              @"defaults");
        NSDictionary *partial = XSSettingsSanitized(@{@"level": field(@"bogus", 1, @"mac"), @"reminder": field(@NO, 7, @"device"),
                                                      @"language": @"fr"}, base);
        check([XSSettingValue(partial, @"level") isEqual:@"all"] && [XSSettingValue(partial, @"reminder") isEqual:@NO]
              && [XSSettingValue(partial, @"language") isEqual:@"automatic"], @"sanitized: invalid fields fall back");

        // Visibility: InAppSettingsTests.visibilityMatrix.
        NSDictionary *(^S)(NSString *, BOOL, BOOL, BOOL, BOOL) = ^(NSString *level, BOOL validity, BOOL alert, BOOL card, BOOL reminder) {
            NSDictionary *s = XSSettingsDefaults(reminder, t0);
            s = XSSettingsSetting(s, @"level", level, t0, @"mac");
            s = XSSettingsSetting(s, @"showValidity", @(validity), t0, @"mac");
            s = XSSettingsSetting(s, @"alertLate", @(alert), t0, @"mac");
            return XSSettingsSetting(s, @"refreshCard", @(card), t0, @"mac");
        };
        BOOL rows[4][6] = {{1, 1, 1, 0, 0, 1}, {0, 1, 0, 0, 0, 1}, {1, 0, 1, 0, 1, 0}, {0, 0, 0, 0, 0, 0}};
        BOOL matrix = YES;
        for (int i = 0; i < 4; i++) {
            NSDictionary *s = S(@"all", rows[i][0], rows[i][1], YES, YES);
            matrix = matrix && XSShowsValidityPill(s, NO) == rows[i][2] && XSShowsLatePill(s, NO) == rows[i][3]
                && XSShowsValidityPill(s, YES) == rows[i][4] && XSShowsLatePill(s, YES) == rows[i][5];
        }
        check(matrix, @"visibility matrix (level all)");
        NSDictionary *e = S(@"essentials", YES, YES, YES, YES);
        check(!XSShowsValidityPill(e, NO) && !XSShowsValidityPill(e, YES) && XSShowsLatePill(e, YES) && !XSShowsLatePill(e, NO)
              && !XSShowsRefreshCard(e) && !XSShowsInstallSheet(e) && XSSchedulesReminder(e), @"essentials ceiling");
        NSDictionary *eOff = S(@"essentials", YES, NO, YES, NO);
        check(!XSShowsLatePill(eOff, YES) && !XSSchedulesReminder(eOff), @"essentials respects the switches");
        NSDictionary *none = S(@"none", YES, YES, YES, YES);
        check(!XSShowsValidityPill(none, NO) && !XSShowsLatePill(none, YES) && !XSShowsRefreshCard(none)
              && !XSSchedulesReminder(none) && !XSShowsInstallSheet(none), @"none shows nothing");
        NSDictionary *a = S(@"all", NO, YES, NO, YES);
        check(!XSShowsRefreshCard(a) && XSShowsInstallSheet(a) && XSSchedulesReminder(a)
              && XSShowsRefreshCard(S(@"all", NO, YES, YES, YES)), @"card and sheet under all");
        check(XSIsLate(41 * 3600, 48) && !XSIsLate(43 * 3600, 48) && XSIsLate(17 * 3600, 24), @"late = threshold - 6 h");

        // JSON round trip of the settings.
        check(sameSettings(XSSettingsFromJSONObject(XSSettingsJSONObject(fixtureSettings())) ?: @{}, fixtureSettings()),
              @"settings JSON round trip");
        NSMutableDictionary *missing = [XSSettingsJSONObject(fixtureSettings()) mutableCopy];
        [missing removeObjectForKey:@"level"];
        check(XSSettingsFromJSONObject(missing) == nil, @"settings JSON with a missing field refused");
    }
    if (failures) { fprintf(stderr, "%d check(s) failed\n", failures); return 1; }
    printf("all checks passed\n");
    return 0;
}
