// The "Réglages XSide" of the app on the phone (spec §2 and "Sync model"): the payload XSide wrote
// at signing, the values the person set in iOS Settings (the app's defaults under
// io.github.xside.settings.<field>), and what came through the channel, merged field by field
// (XSSettingsCore). Also the read-only rows of that page, rewritten in the device's locale.

#import "XSCommon.h"
#import "XSSettingsCore.h"

static NSString *const XSRowPrefix = @"io.github.xside.settings.";
/// The merged settings, with their dates: {field: {value, changedAt, changedBy}}.
static NSString *const XSStoredKey = @"io.github.xside.welcome.settings";
/// The values last written to (or seen in) the iOS Settings rows: a different value found later
/// was changed there by the person.
static NSString *const XSShadowKey = @"io.github.xside.welcome.settingsShadow";
static NSString *const XSLastRefreshKey = @"io.github.xside.welcome.lastRefresh";
static NSString *const XSLastCheckInKey = @"io.github.xside.welcome.lastCheckIn";
static NSString *const XSPendingFailureKey = @"io.github.xside.welcome.pendingFailure";
static NSString *const XSLastExpiryKey = @"io.github.xside.welcome.lastExpiry";
static NSString *const XSChannelGrantedKey = @"io.github.xside.welcome.channelGranted";
static NSString *const XSNetworkExplainedKey = @"io.github.xside.welcome.networkExplained";
/// The "changed on phone" flags, also saved (mega review minor 4): settings can first be loaded
/// during a background launch (the wrapped setShortcutItems:), and a process killed before it
/// became active would otherwise lose the news, so the change would never be told.
static NSString *const XSAutoRefreshChangedKey = @"io.github.xside.welcome.autoRefreshChangedOnPhone";
static NSString *const XSOtherChangedKey = @"io.github.xside.welcome.otherChangedOnPhone";
/// When the library last looked at the iOS Settings rows (saved when the app leaves).
static NSString *const XSLastLookedKey = @"io.github.xside.welcome.rowsLookedAt";

static NSObject *XSLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSDictionary *XSCached; // guarded by XSLock()
static BOOL XSAutoRefreshChangedOnPhone; // guarded by XSLock()
/// The other fields changed in iOS Settings, in XSSettingFields order, so the pill that sends them
/// can say which (device feedback round 2, P2). Guarded by XSLock().
static NSMutableArray<NSString *> *XSOtherChangedOnPhone;
static NSDate *XSLookedAt; // guarded by XSLock()

/// The latest time the library looked at the rows: this run's, else the one saved when it left.
static NSDate *XSLastLooked(void) {
    id saved = [XSDefaults() objectForKey:XSLastLookedKey];
    NSDate *stored = [saved isKindOfClass:NSDate.class] ? saved : nil;
    if (!XSLookedAt) return stored;
    return stored ? [XSLookedAt laterDate:stored] : XSLookedAt;
}

/// When the app's preferences file was last written (iOS Settings writes it on a change).
static NSDate *XSDefaultsModified(void) {
    NSURL *file = XSDefaultsFile();
    if (!file) return nil;
    NSDate *date = nil;
    if (![file getResourceValue:&date forKey:NSURLContentModificationDateKey error:NULL]) return nil;
    return date;
}

/// The preferences file date when the library loaded, and whether a load used it yet (mega review
/// minor 1). Guarded by XSLock().
static NSDate *XSDefaultsModifiedAtStart;
static BOOL XSLoadedOnce;

void XSNoteStartDefaultsDate(void) {
    NSDate *date = XSDefaultsModified();
    @synchronized (XSLock()) { XSDefaultsModifiedAtStart = date; }
}

void XSNoteLeaving(void) {
    @synchronized (XSLock()) {
        [XSDefaults() setObject:NSDate.date forKey:XSLastLookedKey];
    }
}

/// The payload's settings; for a payload without them (or with invalid ones), the Mac's defaults
/// dated 1970, so anything set on the phone wins.
static NSDictionary *XSPayloadSettings(void) {
    NSDictionary *payload = XSPayload();
    id legacy = payload[@"reminder"];
    BOOL reminder = [legacy isKindOfClass:NSNumber.class] ? [legacy boolValue] : YES;
    NSDictionary *fallback = XSSettingsDefaults(reminder, [NSDate dateWithTimeIntervalSince1970:0]);
    return XSSettingsSanitized(payload[@"settings"], fallback);
}

/// Saves `settings` and writes their values into the iOS Settings rows (and the shadow copy).
/// Only what changed is written: a write posts a defaults-change notification inside the app.
static void XSStore(NSDictionary *settings) {
    NSUserDefaults *d = XSDefaults();
    NSMutableDictionary *shadow = [NSMutableDictionary dictionary];
    for (NSString *f in XSSettingFields()) {
        id value = XSSettingValue(settings, f);
        if (!value) continue;
        shadow[f] = value;
        NSString *key = [XSRowPrefix stringByAppendingString:f];
        if (![[d objectForKey:key] isEqual:value]) [d setObject:value forKey:key];
    }
    // "Messages XSide" of an earlier 1.1 build: now derived from the switches, its row is gone.
    NSString *oldLevel = [XSRowPrefix stringByAppendingString:@"level"];
    if ([d objectForKey:oldLevel]) [d removeObjectForKey:oldLevel];
    if (![[d objectForKey:XSStoredKey] isEqual:settings]) [d setObject:settings forKey:XSStoredKey];
    if (![[d objectForKey:XSShadowKey] isEqual:shadow]) [d setObject:shadow forKey:XSShadowKey];
    XSCached = settings;
}

BOOL XSLoadSettings(void) {
    @synchronized (XSLock()) {
        NSUserDefaults *d = XSDefaults();
        NSDictionary *payload = XSPayloadSettings();
        id saved = [d objectForKey:XSStoredKey];
        NSDictionary *local = saved ? XSSettingsSanitized(saved, payload) : payload;
        id rawShadow = [d objectForKey:XSShadowKey];
        NSDictionary *shadow = [rawShadow isKindOfClass:NSDictionary.class] ? rawShadow : @{};
        // Changes made in iOS Settings since the library last wrote the rows, by the device (spec
        // "Sync model"). Dated by the preferences file iOS Settings wrote, between the last look
        // and now (final review minor 1: dating them now made a change made while the app was
        // closed beat a newer Mac change).
        NSMutableDictionary *rows = [NSMutableDictionary dictionary];
        for (NSString *f in XSSettingFields()) {
            id value = [d objectForKey:[XSRowPrefix stringByAppendingString:f]];
            if (value) rows[f] = value;
        }
        NSDate *now = NSDate.date;
        NSDate *fileDate = XSPrefsDateForLoad(XSDefaultsModifiedAtStart, XSDefaultsModified(), !XSLoadedOnce);
        XSLoadedOnce = YES;
        NSDate *when = XSRowChangeDate(fileDate, XSLastLooked(), now);
        XSLookedAt = now;
        NSDictionary *noticed = XSSettingsNoticingRowChanges(local, rows, shadow, when);
        // Restamped fields (a new date, even when the value is back to what it was) are told.
        for (NSString *f in XSSettingFields()) {
            if ([noticed[f] isEqual:local[f]]) continue;
            NSLog(@"XSide: %@ changed in iOS Settings, dated %@ (file at start %@)", f, when, XSDefaultsModifiedAtStart);
            if ([f isEqualToString:@"autoRefresh"]) {
                XSAutoRefreshChangedOnPhone = YES;
                [d setBool:YES forKey:XSAutoRefreshChangedKey];
            } else {
                if (!XSOtherChangedOnPhone) XSOtherChangedOnPhone = [NSMutableArray array];
                if (![XSOtherChangedOnPhone containsObject:f]) [XSOtherChangedOnPhone addObject:f];
                [d setObject:[XSOtherChangedOnPhone copy] forKey:XSOtherChangedKey];
            }
        }
        local = noticed;
        NSDictionary *merged = XSSettingsMerge(local, payload);
        NSDictionary *before = XSCached;
        XSStore(merged);
        BOOL changed = NO;
        for (NSString *f in XSSettingFields()) {
            if (before && ![XSSettingValue(before, f) isEqual:XSSettingValue(merged, f)]) changed = YES;
        }
        return changed;
    }
}

BOOL XSTakeAutoRefreshChangedOnPhone(void) {
    @synchronized (XSLock()) {
        NSUserDefaults *d = XSDefaults();
        BOOL changed = XSAutoRefreshChangedOnPhone || [d boolForKey:XSAutoRefreshChangedKey];
        XSAutoRefreshChangedOnPhone = NO;
        if ([d objectForKey:XSAutoRefreshChangedKey]) [d removeObjectForKey:XSAutoRefreshChangedKey];
        return changed;
    }
}

NSArray<NSString *> *XSTakeSettingsChangedOnPhone(void) {
    @synchronized (XSLock()) {
        NSUserDefaults *d = XSDefaults();
        id saved = [d objectForKey:XSOtherChangedKey];
        NSMutableOrderedSet<NSString *> *fields = [NSMutableOrderedSet orderedSet];
        if ([saved isKindOfClass:NSArray.class]) {
            for (id f in saved) if ([XSSettingFields() containsObject:f]) [fields addObject:f];
        }
        [fields addObjectsFromArray:XSOtherChangedOnPhone ?: @[]];
        // A flag saved by an earlier build (a plain YES) says something changed, not what.
        BOOL changed = fields.count > 0 || ([saved isKindOfClass:NSNumber.class] && [saved boolValue]);
        XSOtherChangedOnPhone = nil;
        if (saved) [d removeObjectForKey:XSOtherChangedKey];
        if (!changed) return nil;
        // In field order, as XSChangeTexts lists them.
        NSMutableArray<NSString *> *ordered = [NSMutableArray array];
        for (NSString *f in XSSettingFields()) if ([fields containsObject:f]) [ordered addObject:f];
        return ordered;
    }
}

NSDictionary *XSCurrentSettings(void) {
    @synchronized (XSLock()) {
        if (!XSCached) XSLoadSettings();
        return XSCached;
    }
}

void XSAdoptSettings(NSDictionary *settings) {
    @synchronized (XSLock()) {
        XSStore(XSSettingsMerge(XSCurrentSettings(), settings));
    }
}

void XSSetDeviceSetting(NSString *field, id value) {
    @synchronized (XSLock()) {
        XSStore(XSSettingsSetting(XSCurrentSettings(), field, value, NSDate.date, @"device"));
    }
}

NSInteger XSThresholdHours(void) {
    id hours = XSPayload()[@"thresholdHours"];
    NSInteger h = [hours isKindOfClass:NSNumber.class] ? [hours integerValue] : 48;
    return h >= 1 && h <= 24 * 30 ? h : 48;
}

NSTimeInterval XSReminderLead(void) {
    id hours = XSPayload()[@"reminderLeadHours"];
    NSInteger h = [hours isKindOfClass:NSNumber.class] ? [hours integerValue] : 24;
    return (h > 0 && h <= 48 ? h : 24) * 3600.0;
}

NSDate *XSSignedAt(void) {
    id value = XSPayload()[@"signedAt"];
    return [value isKindOfClass:NSDate.class] ? value : XSProfileCreationDate();
}

NSString *XSInstallationID(void) {
    id value = XSPayload()[@"installationID"];
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

NSData *XSChannelSecret(void) {
    id value = XSPayload()[@"channelSecret"];
    return [value isKindOfClass:NSData.class] && [value length] >= 16 ? value : nil;
}

// MARK: - Refresh and check-in records

NSDictionary *XSLastRefresh(void) {
    id last = [XSDefaults() objectForKey:XSLastRefreshKey];
    if (![last isKindOfClass:NSDictionary.class] || ![last[@"at"] isKindOfClass:NSDate.class]) return nil;
    return last;
}

void XSRecordRefresh(BOOL succeeded, NSString *reasonKey, NSDate *at) {
    NSMutableDictionary *last = [@{@"at": at, @"succeeded": @(succeeded)} mutableCopy];
    if (!succeeded && reasonKey) last[@"reasonKey"] = reasonKey;
    [XSDefaults() setObject:last forKey:XSLastRefreshKey];
    XSWriteStatusRows(nil);
}

void XSRecordCheckIn(NSDate *at) {
    [XSDefaults() setObject:at forKey:XSLastCheckInKey];
    XSWriteStatusRows(nil);
}

NSDate *XSLastCheckIn(void) {
    id at = [XSDefaults() objectForKey:XSLastCheckInKey];
    return [at isKindOfClass:NSDate.class] ? at : nil;
}

void XSSetPendingFailure(NSString *reasonKey, NSDate *at) {
    [XSDefaults() setObject:@{@"reasonKey": reasonKey, @"at": at} forKey:XSPendingFailureKey];
}

/// The pending state, if any: {reasonKey, at}.
static NSDictionary *XSPending(void) {
    id pending = [XSDefaults() objectForKey:XSPendingFailureKey];
    if (![pending isKindOfClass:NSDictionary.class] || ![pending[@"reasonKey"] isKindOfClass:NSString.class]) return nil;
    return pending;
}

NSString *XSPendingFailure(void) { return XSPending()[@"reasonKey"]; }

NSString *XSTakePendingFailure(void) {
    NSString *key = XSPendingFailure();
    [XSDefaults() removeObjectForKey:XSPendingFailureKey];
    return key;
}

void XSAdoptRefreshOutcome(NSDictionary *outcome) {
    NSDate *at = outcome[@"at"];
    if (![at isKindOfClass:NSDate.class]) return;
    BOOL succeeded = [outcome[@"succeeded"] boolValue];
    NSString *reason = [outcome[@"reasonKey"] isKindOfClass:NSString.class] ? outcome[@"reasonKey"] : @"unknown";
    NSDate *known = XSLastRefresh()[@"at"];
    if (!known || [at compare:known] == NSOrderedDescending) XSRecordRefresh(succeeded, reason, at);
    // A refresh the phone asked for and never heard of: this is its answer if it ended after the
    // request (with the channel's 2 min of clock difference).
    NSDictionary *pending = XSPending();
    if (![pending[@"reasonKey"] isEqual:XSNoOutcomeKey] || ![pending[@"at"] isKindOfClass:NSDate.class]) return;
    if ([at timeIntervalSinceDate:pending[@"at"]] < -120) return;
    if (succeeded) [XSDefaults() removeObjectForKey:XSPendingFailureKey];
    else XSSetPendingFailure(reason, at);
}

void XSNoteSignature(NSDate *expiry) {
    NSUserDefaults *d = XSDefaults();
    id last = [d objectForKey:XSLastExpiryKey];
    if ([last isKindOfClass:NSDate.class] && ![last isEqualToDate:expiry]) {
        // A new signature: XSide refreshed (or updated) the app, whatever asked for it.
        [d removeObjectForKey:XSPendingFailureKey];
        XSRecordRefresh(YES, nil, XSSignedAt() ?: NSDate.date);
    }
    [d setObject:expiry forKey:XSLastExpiryKey];
}

BOOL XSTakeRefreshOnLaunch(void) {
    // "Rafraîchir à la prochaine ouverture": an action, not a setting (not synced, not reported).
    NSUserDefaults *d = XSDefaults();
    NSString *key = [XSRowPrefix stringByAppendingString:@"refreshOnLaunch"];
    id on = [d objectForKey:key];
    if (![on isKindOfClass:NSNumber.class] || ![on boolValue]) return NO;
    [d setObject:@NO forKey:key]; // back off in iOS Settings: one press, one refresh
    return YES;
}

BOOL XSChannelGranted(void) { return [XSDefaults() boolForKey:XSChannelGrantedKey]; }
void XSSetChannelGranted(void) { [XSDefaults() setBool:YES forKey:XSChannelGrantedKey]; }
BOOL XSNetworkExplained(void) { return [XSDefaults() boolForKey:XSNetworkExplainedKey]; }
void XSSetNetworkExplained(void) { [XSDefaults() setBool:YES forKey:XSNetworkExplainedKey]; }
BOOL XSHasChannel(void) { return XSInstallationID() != nil && XSChannelSecret() != nil; }

// MARK: - Read-only rows

static NSString *XSRowDate(NSDate *date, BOOL withTime) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = NSLocale.currentLocale;
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = withTime ? NSDateFormatterShortStyle : NSDateFormatterNoStyle;
    return [formatter stringFromDate:date];
}

void XSWriteStatusRows(NSDate *expiry) {
    // In the device's language and locale, as iOS shows the rest of the page. Rows the library has
    // nothing better for keep what the Mac wrote at signing.
    BOOL fr = XSDeviceFrench();
    NSMutableDictionary<NSString *, NSString *> *rows = [NSMutableDictionary dictionary];
    if (expiry) rows[@"validUntil"] = XSRowDate(expiry, YES);
    NSDate *signedAt = XSSignedAt();
    if (signedAt) rows[@"refreshedOn"] = XSRowDate(signedAt, YES);
    id installed = XSPayload()[@"installedAt"];
    if ([installed isKindOfClass:NSDate.class]) rows[@"installedOn"] = XSRowDate(installed, NO);
    id checkIn = [XSDefaults() objectForKey:XSLastCheckInKey];
    if ([checkIn isKindOfClass:NSDate.class]) rows[@"connection"] = [@"✓ " stringByAppendingString:XSRowDate(checkIn, YES)];
    NSDictionary *last = XSLastRefresh();
    if (last) {
        rows[@"lastRefresh"] = [last[@"succeeded"] boolValue]
            ? [NSString stringWithFormat:fr ? @"Réussi le %@" : @"Succeeded %@", XSRowDate(last[@"at"], YES)]
            : [NSString stringWithFormat:fr ? @"Échec : %@" : @"Failed: %@", XSReasonText(last[@"reasonKey"], fr)];
    }
    NSUserDefaults *d = XSDefaults();
    [rows enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        NSString *full = [XSRowPrefix stringByAppendingString:key];
        if (![[d objectForKey:full] isEqual:value]) [d setObject:value forKey:full];
    }];
}
