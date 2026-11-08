// The local-network channel to XSide on the Mac (spec §5): Bonjour `_xside._tcp`, one TCP
// connection per request, frames from XSChannelCore. Never browses before the person tapped a
// Refresh once (the local network prompt then comes with an obvious reason).

#import "XSCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// "Refresh now" from the phone (late pill, quick action): asks XSide, tells the outcome in the
/// pill, and a failure that arrives later in a notification. Main thread.
void XSRequestRefresh(void);

/// The silent check-in (≤ 3 s): sends this phone's settings and last refresh, adopts the merged
/// settings and the refresh outcome XSide answers. Only once the local network was allowed.
/// `done` (main queue) runs in every case, after the answer if any. Main thread.
void XSCheckIn(void (^_Nullable done)(void));

NS_ASSUME_NONNULL_END
