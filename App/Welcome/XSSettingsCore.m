// See XSSettingsCore.h. Mirrors Sources/XSideCore/InAppSettings.swift.

#import "XSSettingsCore.h"

static NSArray<NSString *> *XSBoolFields(void) {
    return @[@"showValidity", @"alertLate", @"refreshCard", @"reminder", @"autoRefresh"];
}

NSArray<NSString *> *XSSettingFields(void) {
    return @[@"showValidity", @"alertLate", @"refreshCard", @"reminder", @"language", @"autoRefresh"];
}

/// The strings a choice field accepts; nil for a Bool field.
static NSArray<NSString *> *XSChoices(NSString *field) {
    if ([field isEqualToString:@"language"]) return @[@"automatic", @"fr", @"en"];
    return nil;
}

static BOOL XSIsBoolNumber(id value) {
    // A plist or JSON boolean is a CFBoolean; iOS Settings also stores toggles as such. A plain
    // 0/1 number is accepted too (older payloads wrote `reminder` as an integer).
    if (![value isKindOfClass:NSNumber.class]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return YES;
    long long v = [value longLongValue];
    return (v == 0 || v == 1) && [value doubleValue] == (double)v;
}

BOOL XSSettingValueValid(NSString *field, id value) {
    if (!value) return NO;
    NSArray *choices = XSChoices(field);
    if (choices) return [value isKindOfClass:NSString.class] && [choices containsObject:value];
    if ([XSBoolFields() containsObject:field]) return XSIsBoolNumber(value);
    return NO;
}

/// The value in canonical form (@YES/@NO for Bools), so equal values compare equal.
static id XSCanonicalValue(NSString *field, id value) {
    return XSChoices(field) ? value : ([value boolValue] ? @YES : @NO);
}

static NSDictionary *XSField(NSString *field, id value, NSDate *at, NSString *by) {
    return @{@"value": XSCanonicalValue(field, value), @"changedAt": at, @"changedBy": by};
}

NSDictionary *XSSettingsDefaults(BOOL reminder, NSDate *at) {
    return @{
        @"showValidity": XSField(@"showValidity", @YES, at, @"mac"), // on by default (Anthony, 2026-11-08)
        @"alertLate": XSField(@"alertLate", @YES, at, @"mac"),
        @"refreshCard": XSField(@"refreshCard", @YES, at, @"mac"),
        @"reminder": XSField(@"reminder", @(reminder), at, @"mac"),
        @"language": XSField(@"language", @"automatic", at, @"mac"),
        @"autoRefresh": XSField(@"autoRefresh", @YES, at, @"mac"),
    };
}

/// `raw` as a field of `field` if it is a valid one (value, date, origin); nil otherwise.
static NSDictionary *XSValidField(NSString *field, id raw) {
    if (![raw isKindOfClass:NSDictionary.class]) return nil;
    id value = raw[@"value"], at = raw[@"changedAt"], by = raw[@"changedBy"];
    if (!XSSettingValueValid(field, value) || ![at isKindOfClass:NSDate.class]) return nil;
    if (![by isEqual:@"mac"] && ![by isEqual:@"device"]) return nil;
    if (!isfinite([at timeIntervalSince1970])) return nil;
    return XSField(field, value, at, by);
}

NSDictionary *XSSettingsSanitized(id raw, NSDictionary *fallback) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSDictionary *input = [raw isKindOfClass:NSDictionary.class] ? raw : @{};
    for (NSString *f in XSSettingFields()) {
        NSDictionary *valid = XSValidField(f, input[f]) ?: XSValidField(f, fallback[f]);
        if (valid) result[f] = valid;
    }
    // A fallback that is itself incomplete still yields every field.
    NSDictionary *defaults = XSSettingsDefaults(YES, [NSDate dateWithTimeIntervalSince1970:0]);
    for (NSString *f in XSSettingFields()) if (!result[f]) result[f] = defaults[f];
    return result;
}

NSDictionary *XSFieldMerge(NSDictionary *a, NSDictionary *b) {
    // Port of Field.merge (Sources/XSideCore/InAppSettings.swift; tests: InAppSettingsTests):
    // newest changedAt wins; exact tie -> the device's; same date and origin -> a.
    NSComparisonResult order = [(NSDate *)a[@"changedAt"] compare:b[@"changedAt"]];
    if (order != NSOrderedSame) return order == NSOrderedDescending ? a : b;
    if (![a[@"changedBy"] isEqual:b[@"changedBy"]]) return [a[@"changedBy"] isEqual:@"device"] ? a : b;
    return a;
}

NSDictionary *XSSettingsMerge(NSDictionary *a, NSDictionary *b) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *f in XSSettingFields()) {
        NSDictionary *x = a[f], *y = b[f];
        result[f] = x && y ? XSFieldMerge(x, y) : (x ?: y);
    }
    return result;
}

NSDictionary *XSSettingsSetting(NSDictionary *s, NSString *field, id value, NSDate *at, NSString *by) {
    if (!XSSettingValueValid(field, value)) return s;
    NSMutableDictionary *copy = [s mutableCopy];
    copy[field] = XSField(field, value, at, by);
    return copy;
}

NSDictionary *XSSettingsNoticingRowChanges(NSDictionary *local, NSDictionary *rows, NSDictionary *shadow, NSDate *now) {
    NSDictionary *result = local;
    for (NSString *f in XSSettingFields()) {
        id value = rows[f];
        if (!XSSettingValueValid(f, value)) continue;
        id known = XSSettingValueValid(f, shadow[f]) ? shadow[f] : XSSettingValue(local, f);
        if (![value isEqual:known]) {
            result = XSSettingsSetting(result, f, value, now, @"device");
        }
    }
    return result;
}

const NSTimeInterval XSReturnCheckInInterval = 15;

BOOL XSShouldCheckInOnReturn(BOOL changed, BOOL pending, NSDate *lastCheckIn, NSDate *now) {
    if (changed || pending || !lastCheckIn) return YES;
    NSTimeInterval since = [now timeIntervalSinceDate:lastCheckIn];
    return since < 0 || since >= XSReturnCheckInInterval;
}

NSArray<NSString *> *XSChangedFields(NSDictionary *before, NSDictionary *after) {
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *f in XSSettingFields()) {
        id a = XSSettingValue(before, f), b = XSSettingValue(after, f);
        if (a != b && ![a isEqual:b]) [fields addObject:f];
    }
    return fields;
}

NSArray<NSString *> *XSFieldsChangedByMac(NSDictionary *before, NSDictionary *after) {
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *f in XSChangedFields(before, after)) {
        id field = after[f];
        if ([field isKindOfClass:NSDictionary.class] && [field[@"changedBy"] isEqual:@"mac"]) [fields addObject:f];
    }
    return fields;
}

id XSSettingValue(NSDictionary *s, NSString *field) {
    id f = s[field];
    return [f isKindOfClass:NSDictionary.class] ? f[@"value"] : nil;
}

BOOL XSSettingBool(NSDictionary *s, NSString *field) {
    id v = XSSettingValue(s, field);
    return [v isKindOfClass:NSNumber.class] && [v boolValue];
}

// Port of InAppSettings' level and visibility helpers (Sources/XSideCore/InAppSettings.swift;
// tests: InAppSettingsTests.visibilityFollowsTheFourSwitches, levelIsDerivedFromTheSwitches).
// Keep them identical.

NSString *XSDerivedLevel(NSDictionary *s) {
    BOOL v = XSSettingBool(s, @"showValidity"), l = XSSettingBool(s, @"alertLate");
    BOOL c = XSSettingBool(s, @"refreshCard"), r = XSSettingBool(s, @"reminder");
    if (v && l && c && r) return @"all";
    if (!v && l && !c && r) return @"essentials";
    if (!v && !l && !c && !r) return @"none";
    return @"custom";
}

BOOL XSShowsLatePill(NSDictionary *s, BOOL late) { return late && XSSettingBool(s, @"alertLate"); }

BOOL XSShowsValidityPill(NSDictionary *s, BOOL late) {
    return XSSettingBool(s, @"showValidity") && !XSShowsLatePill(s, late);
}

BOOL XSShowsRefreshCard(NSDictionary *s) { return XSSettingBool(s, @"refreshCard"); }
BOOL XSSchedulesReminder(NSDictionary *s) { return XSSettingBool(s, @"reminder"); }
BOOL XSShowsInstallSheet(NSDictionary *s) { return ![XSDerivedLevel(s) isEqualToString:@"none"]; }

BOOL XSShowsPills(NSDictionary *s) { return ![XSDerivedLevel(s) isEqualToString:@"none"]; }

BOOL XSShowsPill(NSDictionary *s, BOOL answer) { return answer || XSShowsPills(s); }

BOOL XSShowsMacUpdatePill(NSDictionary *before, NSDictionary *after) {
    return XSShowsPills(before) || XSShowsPills(after);
}

BOOL XSPillScreenFree(BOOL hasPill, BOOL onScreenWhenFree, BOOL windowHidden, NSTimeInterval shownFor,
                      NSTimeInterval duration) {
    if (!hasPill || onScreenWhenFree || windowHidden) return YES;
    return duration > 0 && shownFor > duration + 3;
}

NSArray<NSString *> *XSSheetPages(BOOL channel, BOOL granted, BOOL explained, BOOL askNotifications) {
    NSMutableArray *pages = [NSMutableArray arrayWithObject:@"welcome"];
    if (channel && !granted && !explained) [pages addObject:@"network"];
    if (askNotifications) [pages addObject:@"notifications"];
    return pages;
}

BOOL XSNeedsNetworkExplanation(BOOL channel, BOOL granted, BOOL explained) {
    return channel && !granted && !explained;
}

BOOL XSProbesNetworkFirst(BOOL channel, BOOL granted, BOOL explained, BOOL appUsesNetwork, BOOL systemAlertSeen) {
    return XSNeedsNetworkExplanation(channel, granted, explained) && appUsesNetwork && systemAlertSeen;
}

NSString *XSNetworkPageAfterProbe(XSNetworkProbe probe) {
    switch (probe) {
        case XSNetworkProbeAllowed: return nil;
        case XSNetworkProbeDenied: return @"networkDenied";
        case XSNetworkProbeUnknown: return @"network";
    }
    return @"network";
}

/// The row's title in iOS Settings (XSideSettingsSection.swift writes the same).
static NSString *XSFieldTitle(NSString *field, BOOL fr) {
    NSDictionary<NSString *, NSArray<NSString *> *> *titles = @{
        @"showValidity": @[@"Afficher la validité à l'ouverture", @"Show validity when opening"],
        @"alertLate": @[@"Alerter si pas rafraîchie", @"Alert if not refreshed"],
        @"refreshCard": @[@"Carte après un rafraîchissement", @"Card after a refresh"],
        @"reminder": @[@"Rappel avant l'expiration", @"Reminder before expiry"],
        @"autoRefresh": @[@"Rafraîchissement automatique", @"Automatic refresh"],
        @"language": @[@"Langue des messages XSide", @"XSide messages language"],
    };
    NSArray<NSString *> *pair = titles[field];
    return pair ? pair[fr ? 0 : 1] : field;
}

/// A field's value in words: on/off, or the language's name.
static NSString *XSFieldValueText(NSString *field, id value, BOOL fr) {
    if ([field isEqualToString:@"language"]) {
        if ([value isEqual:@"fr"]) return @"Français";
        if ([value isEqual:@"en"]) return @"English";
        return fr ? @"Automatique" : @"Automatic";
    }
    BOOL on = [value isKindOfClass:NSNumber.class] && [value boolValue];
    return fr ? (on ? @"activé" : @"désactivé") : (on ? @"on" : @"off");
}

NSDictionary<NSString *, NSString *> *XSChangeTexts(NSArray<NSString *> *fields, NSDictionary *s, BOOL byMac, BOOL fr) {
    if (fields.count == 1) {
        NSString *f = fields.firstObject;
        id value = XSSettingValue(s, f);
        NSString *title = XSFieldTitle(f, fr);
        NSString *what;
        if ([f isEqualToString:@"autoRefresh"]) {
            BOOL on = [value boolValue];
            what = fr ? [NSString stringWithFormat:@"%@ %@", title, on ? @"réactivé" : @"désactivé"]
                      : [NSString stringWithFormat:@"%@ %@", title, on ? @"turned back on" : @"turned off"];
            if (byMac) {
                return @{@"lead": [what stringByAppendingString:fr ? @" depuis XSide sur ton Mac" : @" from XSide on your Mac"]};
            }
        } else if ([f isEqualToString:@"language"]) {
            what = fr ? [NSString stringWithFormat:@"« %@ » : %@", title, XSFieldValueText(f, value, fr)]
                      : [NSString stringWithFormat:@"\"%@\": %@", title, XSFieldValueText(f, value, fr)];
            if (byMac) return @{@"lead": [what stringByAppendingString:fr ? @", depuis ton Mac" : @", from your Mac"]};
        } else {
            BOOL on = [value boolValue];
            what = fr ? [NSString stringWithFormat:@"« %@ » %@", title, on ? @"activé" : @"désactivé"]
                      : [NSString stringWithFormat:@"\"%@\" %@", title, on ? @"turned on" : @"turned off"];
            if (byMac) return @{@"lead": [what stringByAppendingString:fr ? @" depuis ton Mac" : @" from your Mac"]};
        }
        return @{@"lead": [what stringByAppendingString:fr ? @" : XSide sur ton Mac est au courant" : @": XSide on your Mac knows"]};
    }
    NSString *lead = byMac ? (fr ? @"Réglages mis à jour depuis ton Mac" : @"Settings updated from your Mac")
                           : (fr ? @"Réglages envoyés à XSide sur ton Mac" : @"Settings sent to XSide on your Mac");
    if (fields.count == 0) return @{@"lead": lead};
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (NSString *f in fields) {
        [items addObject:[NSString stringWithFormat:fr ? @"%@ : %@" : @"%@: %@", XSFieldTitle(f, fr),
                          XSFieldValueText(f, XSSettingValue(s, f), fr)]];
    }
    return @{@"lead": lead, @"list": [items componentsJoinedByString:@" · "]};
}

NSTimeInterval XSForegroundPollInterval(BOOL lowPower) { return lowPower ? 45 : 15; }

BOOL XSShouldPoll(BOOL channel, BOOL granted, NSDate *lastCheckIn, NSDate *now, BOOL lowPower, BOOL watching) {
    if (!channel || !granted || watching) return NO;
    // A second of slack: the timer fires one interval after the last check-in it made.
    return !lastCheckIn || [now timeIntervalSinceDate:lastCheckIn] >= XSForegroundPollInterval(lowPower) - 1;
}

const NSTimeInterval XSWatchKeepAliveTimeout = 60;

BOOL XSShouldOpenWatch(BOOL channel, BOOL granted, BOOL watching, NSDate *retryAt, NSDate *now) {
    if (!channel || !granted || watching) return NO;
    return !retryAt || [now compare:retryAt] != NSOrderedAscending;
}

NSTimeInterval XSWatchRetryDelay(BOOL answered, NSTimeInterval lived) {
    // A watch that worked and ended (XSide's 5 min, a network change): another one at once. One
    // that never answered, or ended right away (an XSide without watches, no slot left, a line
    // that didn't check out): polling for a minute instead of reconnecting in a loop.
    return answered && lived >= 20 ? 0 : 60;
}

BOOL XSKeepsAnswerForReturn(BOOL onScreen, NSTimeInterval duration) { return !onScreen && duration > 0; }

const NSTimeInterval XSKeptAnswerLifetime = 10 * 60;

BOOL XSKeptAnswerStillFresh(NSDate *keptAt, NSDate *now) {
    return keptAt && [now timeIntervalSinceDate:keptAt] <= XSKeptAnswerLifetime;
}

NSDate *XSRowChangeDate(NSDate *fileModified, NSDate *lastLooked, NSDate *now) {
    NSDate *date = fileModified ?: now;
    if (lastLooked && [date compare:lastLooked] == NSOrderedAscending) date = lastLooked;
    if ([date compare:now] == NSOrderedDescending) date = now;
    return date;
}

NSDate *XSPrefsDateForLoad(NSDate *atStart, NSDate *live, BOOL firstLoad) {
    return firstLoad ? atStart : live;
}

NSString *XSSettingsRowTitle(id root) {
    if (![root isKindOfClass:NSDictionary.class]) return nil;
    id items = root[@"PreferenceSpecifiers"];
    if (![items isKindOfClass:NSArray.class]) return nil;
    for (id item in items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        if (![item[@"Key"] isEqual:@"io.github.xside.settings.pane"]) continue;
        id title = item[@"Title"];
        return [title isKindOfClass:NSString.class] && [title length] ? title : nil;
    }
    return nil;
}

NSString *XSSettingsRowTable(id root) {
    id table = [root isKindOfClass:NSDictionary.class] ? root[@"StringsTable"] : nil;
    return [table isKindOfClass:NSString.class] && [table length] ? table : @"Root";
}

BOOL XSIsXSideShortcutType(id type) {
    return [type isKindOfClass:NSString.class] && [type hasPrefix:@"io.github.xside.shortcut."];
}

BOOL XSInfoHasXSideShortcut(id infoItems) {
    if (![infoItems isKindOfClass:NSArray.class]) return NO;
    for (id item in infoItems) {
        if ([item isKindOfClass:NSDictionary.class] && XSIsXSideShortcutType(item[@"UIApplicationShortcutItemType"])) return YES;
    }
    return NO;
}

BOOL XSIsLate(NSTimeInterval timeLeft, NSInteger thresholdHours) {
    return timeLeft < (thresholdHours - 6) * 3600.0;
}

// MARK: - Channel JSON

static const int64_t XSMaxMillis = 32503680000000; // year 3000, as channelMaxMillis on the Mac

int64_t XSMillis(NSDate *date) {
    double ms = round(date.timeIntervalSince1970 * 1000);
    if (!isfinite(ms) || ms < 0) return 0;
    if (ms > (double)XSMaxMillis) return XSMaxMillis;
    return (int64_t)ms;
}

NSDate *XSDateFromMillis(int64_t ms) {
    return [NSDate dateWithTimeIntervalSince1970:(double)ms / 1000.0];
}

NSDictionary *XSSettingsJSONObject(NSDictionary *s) {
    NSMutableDictionary *json = [NSMutableDictionary dictionary];
    for (NSString *f in XSSettingFields()) {
        NSDictionary *field = s[f];
        if (![field isKindOfClass:NSDictionary.class]) continue;
        json[f] = @{@"value": field[@"value"], @"changedAt": @(XSMillis(field[@"changedAt"])),
                    @"changedBy": field[@"changedBy"]};
    }
    return json;
}

NSDictionary *XSSettingsFromJSONObject(id json) {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *f in XSSettingFields()) {
        id raw = json[f];
        if (![raw isKindOfClass:NSDictionary.class]) return nil;
        id at = raw[@"changedAt"];
        if (![at isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)at) == CFBooleanGetTypeID()) return nil;
        long long ms = [at longLongValue];
        if (ms < 0 || ms > XSMaxMillis || [at doubleValue] != (double)ms) return nil;
        NSDictionary *field = XSValidField(f, @{@"value": raw[@"value"] ?: NSNull.null, @"changedAt": XSDateFromMillis(ms),
                                                @"changedBy": raw[@"changedBy"] ?: NSNull.null});
        if (!field) return nil;
        result[f] = field;
    }
    return result;
}

NSDictionary *XSRefreshOutcomeFromJSONObject(id json) {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    id at = json[@"at"], succeeded = json[@"succeeded"], reason = json[@"reasonKey"];
    if (![at isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)at) == CFBooleanGetTypeID()) return nil;
    long long ms = [at longLongValue];
    if (ms < 0 || ms > XSMaxMillis || [at doubleValue] != (double)ms) return nil;
    if (![succeeded isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)succeeded) != CFBooleanGetTypeID()) return nil;
    NSMutableDictionary *outcome = [@{@"at": XSDateFromMillis(ms), @"succeeded": [succeeded boolValue] ? @YES : @NO} mutableCopy];
    if ([reason isKindOfClass:NSString.class]) outcome[@"reasonKey"] = reason;
    return outcome;
}
