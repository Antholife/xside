// The local-network channel to XSide on the Mac (spec §5): Bonjour `_xside._tcp`, one TCP
// connection per request, frames from XSChannelCore. Never browses before the person went past
// the first-launch sheet's "Réseau local" page (or, the sheet being past, its stand-alone
// version shown before a Refresh or a change of "Rafraîchissement automatique"): the local
// network prompt always comes after XSide said why (device feedback round 1, B1).

#import "XSCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// "Refresh now" from the phone (late pill, quick action): asks XSide, tells the outcome in the
/// pill, and a failure that arrives later in a notification. Main thread.
void XSRequestRefresh(void);

/// The silent check-in (≤ 3 s): sends this phone's settings and last refresh, adopts the merged
/// settings and the refresh outcome XSide answers. Only once the local network was allowed.
/// `done` (main queue) runs in every case, after the answer if any. Main thread.
void XSCheckIn(void (^_Nullable done)(void));

/// Right after the first-launch sheet's "Réseau local" page: a silent check-in that browses even
/// before the local network was allowed, so iOS asks now, just after the page said why. Main thread.
void XSStartLocalNetwork(void);

/// XSide settings other than automatic refresh were changed in iOS Settings: the check-in sends
/// them, with a pill ("envoi de tes réglages au Mac…", then sent, or the Mac unreachable: sent at
/// the next connection). Only once the local network was allowed (else silent: the next
/// connection carries them). `done` runs once answered (or at once when nothing is sent). Main thread.
void XSSendSettings(void (^_Nullable done)(void));

/// "Rafraîchissement automatique" was just changed in iOS Settings: XSide is told now, patiently
/// (a check-in carrying the dated change; the first time it browses, iOS asks for the local
/// network), and the pill says whether the Mac knows or will at the next connection. The one place
/// that starts the channel for a changed setting. Main thread.
void XSTellAutoRefreshChange(void);

NS_ASSUME_NONNULL_END
