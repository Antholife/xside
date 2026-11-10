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

/// An answer to a Refresh (busy, paused, Mac not found…) that arrives while the app is not on
/// screen (the person left during the wait) is kept and shown at the return, instead of being
/// lost (final review minor 6): only a final one (`duration` > 0; a pill in progress isn't), and
/// only within `XSKeptAnswerLifetime` of its arrival. `onScreen`: the app isn't in the background
/// (an iOS alert over it, e.g. the local network prompt, still counts as on screen).
BOOL XSKeepsAnswerForReturn(BOOL onScreen, NSTimeInterval duration);
extern const NSTimeInterval XSKeptAnswerLifetime;
BOOL XSKeptAnswerStillFresh(NSDate *_Nullable keptAt, NSDate *now);

/// When a change found in the iOS Settings rows was made (final review minor 1): iOS Settings
/// writes the app's preferences file when the person changes a row, so the file's modification
/// date (`fileModified`) is the best clue; the app writing its own preferences since only moves it
/// later. Kept no earlier than the last time the library looked at the rows (`lastLooked`: the
/// change came after) and no later than `now`. Without a file date: `now`.
NSDate *XSRowChangeDate(NSDate *_Nullable fileModified, NSDate *_Nullable lastLooked, NSDate *now);

/// The preferences file date to date row changes by (mega review minor 1): for the first load of
/// a run, the one captured when the library loaded (`atStart`), before the app and its SDKs write
/// their own preferences at launch, which would date a change made while it was closed at launch;
/// nil then means no file, so nothing was changed in iOS Settings. Later loads: the `live` one.
NSDate *_Nullable XSPrefsDateForLoad(NSDate *_Nullable atStart, NSDate *_Nullable live, BOOL firstLoad);

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
/// "… depuis ton Mac": a change made on the Mac, told unless every message is off both before and
/// after it (device feedback 3, E2: it was under "Carte après rafraîchissement", so turning that
/// card off from the Mac, or having it off, told nothing and read as the change not arriving).
BOOL XSShowsMacUpdatePill(NSDictionary *before, NSDictionary *after);
/// The pill on screen no longer holds a "when free" one back: there is none, it is itself a "when
/// free" one, its window is hidden, or its time is over (`shownFor` past `duration` + 3 s: its
/// dismissal never came). One without a duration (work in progress) holds it until replaced.
BOOL XSPillScreenFree(BOOL hasPill, BOOL onScreenWhenFree, BOOL windowHidden, NSTimeInterval shownFor,
                      NSTimeInterval duration);

// MARK: First launch (device feedback round 1, B1)

/// The pages of the first-launch sheet: "welcome", then "network" when the app talks to XSide
/// (`channel`) and the local network was neither allowed (`granted`) nor explained yet, then
/// "notifications" when iOS will be asked for them (`askNotifications`).
NSArray<NSString *> *XSSheetPages(BOOL channel, BOOL granted, BOOL explained, BOOL askNotifications);
/// The first network access must wait for the "Réseau local" page: the app talks to XSide and the
/// local network is neither allowed nor explained yet. Whatever the messages: the page is what
/// the iOS prompt is about, not one of XSide's messages (device feedback round 2, P4: with every
/// message off, the access used to go ahead with no page).
BOOL XSNeedsNetworkExplanation(BOOL channel, BOOL granted, BOOL explained);

/// What a silent check of the local network found (device feedback 3, E4).
typedef NS_ENUM(NSInteger, XSNetworkProbe) {
    /// XSide on the Mac was found: allowed.
    XSNetworkProbeAllowed,
    /// iOS refused it (kDNSServiceErr_PolicyDenied).
    XSNetworkProbeDenied,
    /// Nothing found in time: not decided yet, or no Mac around.
    XSNetworkProbeUnknown,
};
/// The app uses the local network itself (a Bonjour service of its own, e.g. YouTube's Cast) and
/// a system alert came and went since launch: iOS has likely asked already, for the app. XSide
/// then checks silently before its page instead of explaining a question already answered.
BOOL XSProbesNetworkFirst(BOOL channel, BOOL granted, BOOL explained, BOOL appUsesNetwork, BOOL systemAlertSeen);
/// The page to show after that check: nil (allowed: none), "networkDenied" (how to turn it back
/// on), "network" (the usual page).
NSString *_Nullable XSNetworkPageAfterProbe(XSNetworkProbe probe);

// MARK: What a change pill says (device feedback round 2, P2)

/// The texts of the one pill for a settings change (`fields`, in XSSettingFields order, with
/// their new values in `s`): {lead, list?}. `byMac`: the Mac changed them (a check-in reply
/// brought them); otherwise the phone did and XSide was told. One field: the lead says which
/// and how ("Rafraîchissement automatique réactivé depuis XSide sur ton Mac"); several (or none
/// known): a general lead and, for several, `list` ("Rappel avant l'expiration : désactivé · …").
/// Names are the rows' titles in iOS Settings.
NSDictionary<NSString *, NSString *> *XSChangeTexts(NSArray<NSString *> *fields, NSDictionary *s, BOOL byMac, BOOL french);

// MARK: Live updates while the app is in front (device feedback round 2, P3)

/// Seconds between two check-ins while the app is in front: 15, or 45 in Low Power Mode.
NSTimeInterval XSForegroundPollInterval(BOOL lowPower);
/// A check-in is due now: the app talks to XSide (`channel`), the local network was allowed
/// (`granted`: polling never makes iOS ask), no watch is open or opening (`watching`: XSide writes
/// its changes on it, device feedback 4), and the last check-in (any kind) is at least one
/// interval old.
BOOL XSShouldPoll(BOOL channel, BOOL granted, NSDate *_Nullable lastCheckIn, NSDate *now, BOOL lowPower, BOOL watching);

// MARK: Watch while the app is in front (device feedback 4)

/// No line (live or alive: XSide writes one at least every 25 s) for this long: the watch is dead,
/// the phone closes it.
extern const NSTimeInterval XSWatchKeepAliveTimeout;
/// A watch should be opened now: channel, local network allowed (never makes iOS ask), none open
/// or opening, and the retry time (`retryAt`, nil: none) passed.
BOOL XSShouldOpenWatch(BOOL channel, BOOL granted, BOOL watching, NSDate *_Nullable retryAt, NSDate *now);
/// Seconds before the next watch after one ended: 0 when it had answered and lasted at least 20 s,
/// else 60 (the app polls meanwhile).
NSTimeInterval XSWatchRetryDelay(BOOL answered, NSTimeInterval lived);

/// The title of XSide's row in the app's Settings.bundle page (`root`: its Root.plist), as XSide
/// wrote it at signing: plain text in the installation's language, the key of the translations
/// in the app's languages. nil when the page has none (mega review minor 5).
NSString *_Nullable XSSettingsRowTitle(id _Nullable root);
/// The strings table iOS reads the page's titles from: its StringsTable, else "Root".
NSString *XSSettingsRowTable(id _Nullable root);

// MARK: Tweaks of this copy (XSideWelcome.tweaks, PhoneTweaks in Sources/XSideCore)

/// The payload's tweak list, read as untrusted: at most 64 entries (from the first 1024 items),
/// each a dictionary with a non-blank string `name` (else dropped); `version`, `author`,
/// `summary` kept only as non-blank strings, capped at 64, 128 and 1000 characters (`name` 128),
/// never cut inside a character; `converted` and `off` always present as Bool NSNumbers (NO
/// unless a number says YES). Anything else: an empty list. The caps are PhoneTweaks's.
NSArray<NSDictionary *> *XSTweaksSanitized(id _Nullable raw);
/// The sanitized tweaks in the app (not `off`): the N of « Tweaks · N ».
NSUInteger XSTweaksInjectedCount(NSArray<NSDictionary *> *tweaks);
/// « version · auteur » of a sanitized tweak, what is known of it; « — » for nothing.
NSString *XSTweakVersionLine(NSDictionary *tweak);

// MARK: Quick actions (device feedback 3, E1: static Info.plist items written on the Mac)

/// io.github.xside.shortcut.<name>.
BOOL XSIsXSideShortcutType(id _Nullable type);
/// Info.plist's UIApplicationShortcutItems holds one of XSide's (none when the app's own took the
/// 4 slots, or when it was signed without XSide features).
BOOL XSInfoHasXSideShortcut(id _Nullable infoItems);

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

/// The end of a Mac pause of a while, from a `settings` or `live` reply's "pausedUntil" (integer
/// epoch milliseconds); nil when absent or malformed (review D–G, minor 7).
NSDate *_Nullable XSPausedUntilFromReply(NSDictionary *_Nullable reply);

/// "Reprend tout seul le 9 nov. à 14:00" / "Resumes by itself on 9 Nov at 14:00", in `zone`.
NSString *XSPauseEndHint(NSDate *until, BOOL french, NSTimeZone *zone);

/// Integer epoch milliseconds, clamped to 1970...3000 (the channel's accepted range).
int64_t XSMillis(NSDate *date);
NSDate *XSDateFromMillis(int64_t ms);

NS_ASSUME_NONNULL_END
