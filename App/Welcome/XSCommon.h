// Shared by the XSideWelcome library's files (see XSideWelcome.m for what the library does).
// Everything here is main-thread UIKit unless said otherwise.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: The app as installed (XSCommon.m)

/// The app's Info.plist as written by XSide, read from the file itself: tweaks may fake
/// NSBundle's copy. Any thread.
NSDictionary *XSInfo(void);
/// Info.plist `XSideWelcome` (WelcomePayload in Sources/XSideCore), or an empty dictionary.
NSDictionary *XSPayload(void);
/// ExpirationDate / CreationDate of the app's embedded.mobileprovision. Any thread.
NSDate *_Nullable XSExpirationDate(void);
NSDate *_Nullable XSProfileCreationDate(void);
/// CFBundleShortVersionString, as installed.
NSString *_Nullable XSAppVersion(void);
/// The name on the home screen.
NSString *XSAppName(void);
/// The app's defaults, where iOS Settings stores the "Réglages XSide" values: the real bundle
/// id's even when a tweak makes NSBundle report another one. Any thread.
NSUserDefaults *XSDefaults(void);
/// The app's notification center, under its real bundle id. Any thread.
UNUserNotificationCenter *XSCenter(void);
/// "iPhone" or "iPad".
NSString *XSDeviceKind(void);
/// The hardware model ("iPhone16,1").
NSString *XSDeviceModel(void);

// MARK: Texts

/// French for XSide's own texts: the "Langue des messages XSide" setting, else the device's
/// language. Any thread.
BOOL XSFrench(void);
/// The device's language, ignoring the setting (rows of the iOS Settings page, which iOS shows in
/// the device's language). Any thread.
BOOL XSDeviceFrench(void);
static inline NSString *XST(NSString *fr, NSString *en) { return XSFrench() ? fr : en; }
/// "jeu. 12 nov., 14:30" in the device's locale.
NSString *XSDate(NSDate *date);
/// A failure reason key from XSide (XSideError keys, "cancelled", "unknown") in plain words.
NSString *XSReasonText(NSString *_Nullable reasonKey, BOOL french);
/// "Réglages > Apps > <app>" (iOS 18+) or "Réglages > <app>".
NSString *XSSettingsPath(void);

// MARK: UI

/// The foreground scene, with a window on screen; nil while there's none.
UIWindowScene *_Nullable XSScene(void);
UIColor *XSViolet(void);
UIColor *XSPink(void);
UIImage *_Nullable XSIcon(void);
/// XSide's logo as PNG bytes (compiled in); nil in a build without it.
NSData *_Nullable XSIconPNG(void);
/// A system font that follows the reader's text size (Dynamic Type), up to 1.6 times `size`.
UIFont *XSScaledFont(CGFloat size, UIFontWeight weight);
/// Opens the app's page in iOS Settings.
void XSOpenAppSettings(void);

/// The primary button: XSide's violet-to-pink gradient.
@interface XSGradientButton : UIButton
@end

/// Touches outside its content go to the app.
@interface XSPassthroughWindow : UIWindow
@end

// MARK: Settings (XSSettings.m)

/// The effective XSide-in-app settings (see XSSettingsCore.h). Any thread.
NSDictionary *XSCurrentSettings(void);
/// Reads the payload and the app's defaults, notes changes made in iOS Settings (dated now,
/// by the device), merges, writes the result back. Returns YES if a value changed since the last
/// call. Main thread.
BOOL XSLoadSettings(void);
/// Adopts settings XSide sent (merged field by field). Main thread.
void XSAdoptSettings(NSDictionary *settings);
/// A change made on the phone by the dylib itself (e.g. turning automatic refresh back on).
void XSSetDeviceSetting(NSString *field, id value);
/// Refresh threshold (hours) and reminder lead (seconds) from the payload.
NSInteger XSThresholdHours(void);
NSTimeInterval XSReminderLead(void);
/// When XSide signed this app (payload `signedAt`), else the profile's creation date.
NSDate *_Nullable XSSignedAt(void);
/// The channel credentials from the payload; nil when the app has none.
NSString *_Nullable XSInstallationID(void);
NSData *_Nullable XSChannelSecret(void);
/// The last refresh outcome the phone knows {at, succeeded, reasonKey?}; nil if none.
NSDictionary *_Nullable XSLastRefresh(void);
void XSRecordRefresh(BOOL succeeded, NSString *_Nullable reasonKey, NSDate *at);
void XSRecordCheckIn(NSDate *at);
/// The pending-state key of a refresh XSide accepted but whose outcome never reached the phone.
static NSString *const XSNoOutcomeKey = @"noOutcome";
/// A refresh the person asked for failed (a reason key) or was never heard of (XSNoOutcomeKey)
/// while the app was not on screen: said by the next launch's pill. Cleared when taken, or by a
/// new signature; a check-in answer turns a "noOutcome" into the real result.
void XSSetPendingFailure(NSString *reasonKey, NSDate *at);
NSString *_Nullable XSPendingFailure(void);
NSString *_Nullable XSTakePendingFailure(void);
/// An outcome XSide sent with its check-in answer ({at, succeeded, reasonKey?}).
void XSAdoptRefreshOutcome(NSDictionary *outcome);
/// Notes the app's signature at launch: a new one counts as a successful refresh.
void XSNoteSignature(NSDate *expiry);
/// Rewrites the read-only rows (dates, connection, last refresh) in the device's locale.
void XSWriteStatusRows(NSDate *_Nullable expiry);
/// The person allowed the local network once (after tapping Refresh): checking in at launch is fine.
BOOL XSChannelGranted(void);
void XSSetChannelGranted(void);

// MARK: Reminder (XSideWelcome.m)

void XSScheduleReminder(NSDate *expiry, BOOL askIfNeeded);

NS_ASSUME_NONNULL_END
