// See XSRunMarkerCore.h. Mirrored on the Mac by PreviousRun / CrashWatch in Sources/XSideCore.

#import "XSRunMarkerCore.h"
#import "XSSettingsCore.h"

static NSString *const XSRunning = @"running";
static NSString *const XSClean = @"clean";
static NSString *const XSCrashed = @"crashed";

/// An epoch-milliseconds number (not a Bool) within 1970...3000, or an NSDate in that range.
static NSDate *XSMarkerDate(id value) {
    if ([value isKindOfClass:NSDate.class]) {
        NSTimeInterval t = [value timeIntervalSince1970];
        return isfinite(t) && t >= 0 && t <= 32503680000.0 ? value : nil;
    }
    if (![value isKindOfClass:NSNumber.class]) return nil;
    if (strcmp([value objCType], @encode(BOOL)) == 0 || strcmp([value objCType], @encode(char)) == 0) return nil;
    double ms = [value doubleValue];
    if (!isfinite(ms) || ms < 0 || ms > 32503680000000.0) return nil;
    return XSDateFromMillis((int64_t)llround(ms));
}

static NSDictionary *XSReportSanitized(id raw) {
    if (![raw isKindOfClass:NSDictionary.class]) return nil;
    id ended = raw[@"ended"];
    if (![ended isEqual:XSCrashed] && ![ended isEqual:XSClean]) return nil;
    NSDate *since = XSMarkerDate(raw[@"since"]);
    if (!since) return nil;
    return @{@"ended": ended, @"since": since};
}

NSDictionary *XSRunMarkerSanitized(id raw) {
    if (![raw isKindOfClass:NSDictionary.class]) return nil;
    id state = raw[@"state"];
    if (![state isEqual:XSRunning] && ![state isEqual:XSClean]) return nil;
    NSDate *since = XSMarkerDate(raw[@"since"]);
    if (!since) return nil;
    NSMutableDictionary *marker = [@{@"state": state, @"since": since} mutableCopy];
    NSDictionary *report = XSReportSanitized(raw[@"report"]);
    if (report) marker[@"report"] = report;
    return marker;
}

NSDictionary *XSRunMarkerAtLaunch(id previous, NSDate *now) {
    NSMutableDictionary *marker = [@{@"state": XSRunning, @"since": now} mutableCopy];
    NSDictionary *old = XSRunMarkerSanitized(previous);
    if (!old) return marker;
    NSDictionary *report = @{@"ended": [old[@"state"] isEqual:XSRunning] ? XSCrashed : XSClean, @"since": old[@"since"]};
    NSDictionary *pending = old[@"report"];
    if ([pending[@"ended"] isEqual:XSCrashed] && [report[@"ended"] isEqual:XSClean]) report = pending;
    marker[@"report"] = report;
    return marker;
}

NSDictionary *XSRunMarkerWithState(NSDictionary *marker, BOOL inFront, NSDate *now) {
    NSMutableDictionary *next = [(XSRunMarkerSanitized(marker) ?: @{@"state": XSClean, @"since": now}) mutableCopy];
    if (inFront) {
        if (![next[@"state"] isEqual:XSRunning]) {
            next[@"state"] = XSRunning;
            next[@"since"] = now;
        }
    } else {
        next[@"state"] = XSClean;
    }
    return next;
}

NSDictionary *XSRunMarkerReport(NSDictionary *marker) {
    return XSRunMarkerSanitized(marker)[@"report"];
}

NSDictionary *XSRunMarkerAcknowledged(NSDictionary *marker, NSDictionary *sent) {
    NSDictionary *report = XSRunMarkerReport(marker);
    NSDictionary *was = XSReportSanitized(sent);
    // Compared to the millisecond, as sent on the wire.
    if (!report || !was || ![report[@"ended"] isEqual:was[@"ended"]]
        || XSMillis(report[@"since"]) != XSMillis(was[@"since"])) return marker;
    NSMutableDictionary *next = [marker mutableCopy];
    [next removeObjectForKey:@"report"];
    return next;
}

NSDictionary *XSRunMarkerPlist(NSDictionary *marker) {
    NSDictionary *m = XSRunMarkerSanitized(marker);
    if (!m) return @{};
    NSMutableDictionary *plist = [@{@"state": m[@"state"], @"since": @(XSMillis(m[@"since"]))} mutableCopy];
    NSDictionary *report = m[@"report"];
    if (report) plist[@"report"] = @{@"ended": report[@"ended"], @"since": @(XSMillis(report[@"since"]))};
    return plist;
}
