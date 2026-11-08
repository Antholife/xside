// See XSSettingsCore.h. Mirrors Sources/XSideCore/InAppSettings.swift.

#import "XSSettingsCore.h"

static NSArray<NSString *> *XSBoolFields(void) {
    return @[@"showValidity", @"alertLate", @"refreshCard", @"reminder", @"autoRefresh"];
}

NSArray<NSString *> *XSSettingFields(void) {
    return @[@"level", @"showValidity", @"alertLate", @"refreshCard", @"reminder", @"language", @"autoRefresh"];
}

/// The strings a choice field accepts; nil for a Bool field.
static NSArray<NSString *> *XSChoices(NSString *field) {
    if ([field isEqualToString:@"level"]) return @[@"all", @"essentials", @"none"];
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
        @"level": XSField(@"level", @"all", at, @"mac"),
        @"showValidity": XSField(@"showValidity", @NO, at, @"mac"),
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

id XSSettingValue(NSDictionary *s, NSString *field) {
    id f = s[field];
    return [f isKindOfClass:NSDictionary.class] ? f[@"value"] : nil;
}

BOOL XSSettingBool(NSDictionary *s, NSString *field) {
    id v = XSSettingValue(s, field);
    return [v isKindOfClass:NSNumber.class] && [v boolValue];
}

static BOOL XSLevelIs(NSDictionary *s, NSString *level) { return [XSSettingValue(s, @"level") isEqual:level]; }

// Port of InAppSettings' visibility helpers (Sources/XSideCore/InAppSettings.swift; tests:
// InAppSettingsTests.visibilityMatrix). Keep them identical.

BOOL XSShowsLatePill(NSDictionary *s, BOOL late) {
    return late && !XSLevelIs(s, @"none") && XSSettingBool(s, @"alertLate");
}

BOOL XSShowsValidityPill(NSDictionary *s, BOOL late) {
    return XSLevelIs(s, @"all") && XSSettingBool(s, @"showValidity") && !XSShowsLatePill(s, late);
}

BOOL XSShowsRefreshCard(NSDictionary *s) { return XSLevelIs(s, @"all") && XSSettingBool(s, @"refreshCard"); }
BOOL XSSchedulesReminder(NSDictionary *s) { return !XSLevelIs(s, @"none") && XSSettingBool(s, @"reminder"); }
BOOL XSShowsInstallSheet(NSDictionary *s) { return XSLevelIs(s, @"all"); }

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
