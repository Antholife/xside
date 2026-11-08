// XSSettingsCore: the XSide-in-app settings of one installation, as the dylib keeps them. Pure
// Foundation (no UIKit), so scripts/test-welcome-hmac.sh can compile and check it on the Mac.
//
// A settings dictionary maps each field name (XSSettingFields) to a field dictionary
// {value, changedAt (NSDate), changedBy ("mac"|"device")}: the shape of the Info.plist payload
// (WelcomePayload in Sources/XSideCore) and of InAppSettings on the Mac.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// showValidity, alertLate, refreshCard, reminder, language, autoRefresh. (No "level": it is
/// derived from the four switches; a stored one from an earlier build is ignored.)
NSArray<NSString *> *XSSettingFields(void);

/// The Mac's defaults for an installation (InAppSettings.defaults): everything on (the reminder
/// as given), language "automatic"; dated `at`, changed by the Mac.
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

/// `local` with each value the person changed in iOS Settings since the library last wrote the
/// rows stamped as a device change dated `now` (spec "Sync model": there is no other way to know
/// when it was made). `rows`: the values iOS Settings holds now; `shadow`: the values the library
/// last wrote there (a field missing from it compares with `local`). Values the library wrote
/// itself (e.g. the Mac's, adopted from a check-in reply) are therefore never re-stamped.
NSDictionary *XSSettingsNoticingRowChanges(NSDictionary *local, NSDictionary *rows, NSDictionary *shadow, NSDate *now);

/// When a change found in the iOS Settings rows was made (final review minor 1): iOS Settings
/// writes the app's preferences file when the person changes a row, so the file's modification
/// date (`fileModified`) is the best clue; the app writing its own preferences since only moves it
/// later. Kept no earlier than the last time the library looked at the rows (`lastLooked`: the
/// change came after) and no later than `now`. Without a file date: `now`.
NSDate *XSRowChangeDate(NSDate *_Nullable fileModified, NSDate *_Nullable lastLooked, NSDate *now);

/// Back from the background: check in with XSide (pulling what changed on the Mac meanwhile)
/// unless the last check-in was less than `XSReturnCheckInInterval` ago and there is nothing to
/// tell (`changed`: settings changed in iOS Settings; `pending`: a refresh outcome still unknown).
extern const NSTimeInterval XSReturnCheckInInterval;
BOOL XSShouldCheckInOnReturn(BOOL changed, BOOL pending, NSDate *_Nullable lastCheckIn, NSDate *now);

/// The fields whose value differs between `before` and `after` (dates and origins ignored), in
/// XSSettingFields order.
NSArray<NSString *> *XSChangedFields(NSDictionary *before, NSDictionary *after);
/// Those of them whose value in `after` was set on the Mac: what a check-in reply brought.
NSArray<NSString *> *XSFieldsChangedByMac(NSDictionary *before, NSDictionary *after);

id _Nullable XSSettingValue(NSDictionary *s, NSString *field);
BOOL XSSettingBool(NSDictionary *s, NSString *field);

// MARK: Level and visibility: the port of InAppSettings' helpers (spec §1 matrix, each switch
// for itself). Tested on the Swift side (InAppSettingsTests) and here.

/// "all" (four switches on), "essentials" (only alertLate and reminder), "none" (all off) or
/// "custom": InAppSettings.derivedLevel.
NSString *XSDerivedLevel(NSDictionary *s);

BOOL XSShowsLatePill(NSDictionary *s, BOOL late);
BOOL XSShowsValidityPill(NSDictionary *s, BOOL late);
BOOL XSShowsRefreshCard(NSDictionary *s);
BOOL XSSchedulesReminder(NSDictionary *s);
BOOL XSShowsInstallSheet(NSDictionary *s);

/// Any pill XSide shows on its own: every message off ("Aucun") silences them all.
BOOL XSShowsPills(NSDictionary *s);
/// One pill: `answer` (the answer to something the person just asked: a Refresh and its outcome,
/// a pill's button) shows even with "Aucun", since silence after a tap looks broken (ledger
/// ruling after device feedback round 1); any other only when XSShowsPills.
BOOL XSShowsPill(NSDictionary *s, BOOL answer);
/// "Réglages mis à jour depuis ton Mac": news of what XSide did from the Mac, like the card after
/// a refresh, so under the same switch.
BOOL XSShowsMacUpdatePill(NSDictionary *s);

// MARK: First launch (device feedback round 1, B1)

/// The pages of the first-launch sheet: "welcome", then "network" when the app talks to XSide
/// (`channel`) and the local network was neither allowed (`granted`) nor explained yet, then
/// "notifications" when iOS will be asked for them (`askNotifications`).
NSArray<NSString *> *XSSheetPages(BOOL channel, BOOL granted, BOOL explained, BOOL askNotifications);
/// The first network access must wait for the "Réseau local" page: the app talks to XSide, the
/// local network is neither allowed nor explained yet, and the sheet is allowed by the settings
/// (with every message off, nothing is shown and the access goes ahead as before).
BOOL XSNeedsNetworkExplanation(BOOL channel, BOOL granted, BOOL explained, NSDictionary *s);

/// XSide's own page in iOS Settings, asked by the app's real bundle id: Settings' undocumented
/// "App-prefs:<id>&path=<specifier id>" (the child pane row's id, written by SettingsBundle).
NSString *XSSettingsPaneURLString(NSString *bundleID);

// MARK: Quick actions (final review Important 1)

/// iOS shows 4 quick actions at most: the app's static ones (Info.plist), then its dynamic ones
/// (set at runtime), then XSide's, which are dynamic and only take the slots left, in priority
/// order settings, refresh, report. Installing through XSide never takes an item of the app's.
extern const NSUInteger XSMaxShortcuts;
NSArray<NSString *> *XSShortcutNamesFitting(NSUInteger staticCount, NSUInteger appDynamicCount);
/// io.github.xside.shortcut.<name>.
BOOL XSIsXSideShortcutType(id _Nullable type);
/// The app's own items in Info.plist's UIApplicationShortcutItems (XSide's from an earlier
/// signing, if any, not counted).
NSUInteger XSAppStaticShortcutCount(id _Nullable infoItems);

/// Late (spec §1): less time left than the refresh threshold minus 6 h of margin.
BOOL XSIsLate(NSTimeInterval timeLeft, NSInteger thresholdHours);

// MARK: Channel JSON (dates as integer epoch milliseconds, see Sources/XSideCore/Channel.swift)

/// The settings as JSON objects ({"alertLate":{"changedAt":ms,"changedBy":"mac","value":true},…}).
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
