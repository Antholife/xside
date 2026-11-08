// The local-network channel to XSide on the Mac (spec §5): Bonjour `_xside._tcp`, one TCP
// connection per request, frames from XSChannelCore. Never browses before the person tapped a
// Refresh once or changed "Rafraîchissement automatique" in iOS Settings (the local network
// prompt then comes with an obvious reason).

#import "XSCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// "Refresh now" from the phone (late pill, quick action): asks XSide, tells the outcome in the
/// pill, and a failure that arrives later in a notification. Main thread.
void XSRequestRefresh(void);

/// The silent check-in (≤ 3 s): sends this phone's settings and last refresh, adopts the merged
/// settings and the refresh outcome XSide answers. Only once the local network was allowed.
/// `done` (main queue) runs in every case, after the answer if any. Main thread.
void XSCheckIn(void (^_Nullable done)(void));

/// "Rafraîchissement automatique" was just changed in iOS Settings: XSide is told now, patiently
/// (a check-in carrying the dated change; the first time it browses, iOS asks for the local
/// network), and the pill says whether the Mac knows or will at the next connection. The one place
/// that starts the channel for a changed setting. Main thread.
void XSTellAutoRefreshChange(void);

NS_ASSUME_NONNULL_END
