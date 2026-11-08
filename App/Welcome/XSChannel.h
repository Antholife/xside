// The local-network channel to XSide on the Mac (spec §5): Bonjour `_xside._tcp`, one TCP
// connection per request, frames from XSChannelCore. Never browses before the person went past
// the first-launch sheet's "Réseau local" page (or, the sheet being past, its stand-alone
// version shown before a Refresh or a change of "Rafraîchissement automatique"): the local
// network prompt always comes after XSide said why (device feedback round 1, B1).

#import "XSCommon.h"
#import "XSSettingsCore.h"
#import "XSPill.h"

NS_ASSUME_NONNULL_BEGIN

/// "Refresh now" from the phone (late pill, quick action): asks XSide, tells the outcome in the
/// pill, and a failure that arrives later in a notification. Main thread.
void XSRequestRefresh(void);

/// The silent check-in (≤ 3 s): sends this phone's settings and last refresh, adopts the merged
/// settings and the refresh outcome XSide answers. Only once the local network was allowed.
/// `done` (main queue) runs in every case, after the answer if any, with the one pill saying what
/// the Mac changed (XSChangeTexts), or nil when it changed nothing or that pill is off. The caller
/// shows it (or leaves it out). Main thread.
void XSCheckIn(void (^_Nullable done)(XSPillContent *_Nullable news));

/// Right after the first-launch sheet's "Réseau local" page: a silent check-in that browses even
/// before the local network was allowed, so iOS asks now, just after the page said why. Main thread.
void XSStartLocalNetwork(void);
/// A short silent check-in that tells whether the local network is allowed (the Mac answered),
/// refused (iOS said so) or unknown (device feedback 3, E4). It may make iOS ask when the question
/// is still open: only used once a system alert was seen in an app that uses the network itself.
void XSProbeLocalNetwork(void (^done)(XSNetworkProbe probe));

/// XSide settings other than automatic refresh (`fields`) were changed in iOS Settings: the
/// check-in sends them. `done` gets the one pill that says so (which, sent or the Mac unreachable),
/// or nil when nothing was sent: before the local network was allowed the next connection carries
/// them silently. Main thread.
void XSSendSettings(NSArray<NSString *> *fields, void (^done)(XSPillContent *_Nullable result));

/// "Rafraîchissement automatique" was just changed in iOS Settings: XSide is told now, patiently
/// (a check-in carrying the dated change; the first time, the "Réseau local" page comes first),
/// and one pill says whether the Mac knows or will at the next connection. Main thread.
void XSTellAutoRefreshChange(void);

/// While the app is in front, XSide is asked again every few seconds (XSForegroundPollInterval),
/// so a change made on the Mac shows without leaving the app (device feedback round 2, P3). Only
/// once the local network was allowed; stopped when the app leaves the foreground. Main thread.
void XSStartForegroundUpdates(void);
void XSStopForegroundUpdates(void);

NS_ASSUME_NONNULL_END
