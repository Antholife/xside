// XSSettingsCore: the XSide-in-app settings of one installation, as the dylib keeps them. Pure
// Foundation (no UIKit), so scripts/test-welcome-hmac.sh can compile and check it on the Mac.
//
// A settings dictionary maps each field name (XSSettingFields) to a field dictionary
// {value, changedAt (NSDate), changedBy ("mac"|"device")}: the shape of the Info.plist payload
// (WelcomePayload in Sources/XSideCore) and of InAppSettings on the Mac.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// level, showValidity, alertLate, refreshCard, reminder, language, autoRefresh.
NSArray<NSString *> *XSSettingFields(void);

/// The Mac's defaults for an installation (InAppSettings.defaults): everything on (the reminder
/// as given), level "all", language "automatic"; dated `at`, changed by the Mac.
NSDictionary *XSSettingsDefaults(BOOL reminder, NSDate *at);

/// Whether `value` is valid for `field` (a Bool NSNumber, or one of the field's strings).
BOOL XSSettingValueValid(NSString *field, id _Nullable value);

/// `raw`'s valid fields, each completed from `fallback` when missing or invalid. Never nil.
NSDictionary *XSSettingsSanitized(id _Nullable raw, NSDictionary *fallback);

/// One field: the newest `changedAt` wins; on an exact tie the device's change wins. The port of
/// `Field.merge` in Sources/XSideCore/InAppSettings.swift, checked by InAppSettingsTests (Swift)
/// and scripts/test-welcome-hmac.sh (this file). Keep the three in step.
NSDictionary *XSFieldMerge(NSDictionary *a, NSDictionary *b);

/// Field-by-field merge of two sanitized settings dictionaries (InAppSettings.merge).
NSDictionary *XSSettingsMerge(NSDictionary *a, NSDictionary *b);

/// A copy with `field` set to `value`, dated `at`, changed by `by`.
NSDictionary *XSSettingsSetting(NSDictionary *s, NSString *field, id value, NSDate *at, NSString *by);

id _Nullable XSSettingValue(NSDictionary *s, NSString *field);
BOOL XSSettingBool(NSDictionary *s, NSString *field);

// MARK: Effective visibility: the port of InAppSettings' helpers (spec §1 matrix, the
// Essentials ceiling). Tested on the Swift side (InAppSettingsTests.visibilityMatrix) and here.

BOOL XSShowsLatePill(NSDictionary *s, BOOL late);
BOOL XSShowsValidityPill(NSDictionary *s, BOOL late);
BOOL XSShowsRefreshCard(NSDictionary *s);
BOOL XSSchedulesReminder(NSDictionary *s);
BOOL XSShowsInstallSheet(NSDictionary *s);

/// Late (spec §1): less time left than the refresh threshold minus 6 h of margin.
BOOL XSIsLate(NSTimeInterval timeLeft, NSInteger thresholdHours);

// MARK: Channel JSON (dates as integer epoch milliseconds, see Sources/XSideCore/Channel.swift)

/// The settings as JSON objects ({"level":{"changedAt":ms,"changedBy":"mac","value":"all"},…}).
NSDictionary *XSSettingsJSONObject(NSDictionary *s);
/// Settings from a channel JSON object; nil unless every field is present and valid.
NSDictionary *_Nullable XSSettingsFromJSONObject(id _Nullable json);

/// A refresh outcome from a channel JSON object ({"at":ms,"succeeded":bool,"reasonKey":…}) as
/// {at (NSDate), succeeded (NSNumber), reasonKey (optional)}; nil if malformed.
NSDictionary *_Nullable XSRefreshOutcomeFromJSONObject(id _Nullable json);

/// Integer epoch milliseconds, clamped to 1970...3000 (the channel's accepted range).
int64_t XSMillis(NSDate *date);
NSDate *XSDateFromMillis(int64_t ms);

NS_ASSUME_NONNULL_END
