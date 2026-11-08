// The local-network channel to XSide on the Mac (spec §5): Bonjour `_xside._tcp`, one TCP
// connection per request, frames from XSChannelCore. Never browses before the person tapped a
// Refresh once (the local network prompt then comes with an obvious reason).

#import "XSCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// "Refresh now" from the phone (late pill, quick action): asks XSide, tells the outcome in the
/// pill, and a failure that arrives later in a notification. Main thread.
void XSRequestRefresh(void);

/// The silent check-in at launch (≤ 3 s): sends this phone's settings and last refresh, adopts
/// the merged settings XSide answers. Only once the local network was allowed. Main thread.
void XSCheckIn(void);

NS_ASSUME_NONNULL_END
