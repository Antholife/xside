// The run marker in the app's container (rules in XSRunMarkerCore): whether the app is in front
// or left cleanly, so the next launch can tell XSide on the Mac that the previous run stopped
// while in use (a crash, or killed while in front) and XSide looks at the device's crash logs at
// once. Kept in Library/Application Support/io.github.xside.welcome/run-marker.plist (excluded
// from backups); every read and write runs on its own serial queue, never on the main thread;
// at termination the main thread waits for the last write at most 200 ms. Never throws; a file that can't be read or written only
// costs the report.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// At launch (the library's constructor): reads how the previous run ended, then marks this one
/// running.
void XSRunMarkerLaunched(void);
/// The app came to the front (YES) or left it: backgrounded, or terminating (`wait`: written
/// before returning, at most 200 ms: the process is about to end).
void XSRunMarkerInFront(BOOL inFront, BOOL wait);
/// The report a check-in or a watch carries now (nil when none; also until the launch read is
/// done, a few milliseconds). Any thread: a lock, never the queue's I/O.
NSDictionary *_Nullable XSRunMarkerPendingReport(void);
/// A signed reply came to a request that carried `report`: it is not sent again.
void XSRunMarkerSent(NSDictionary *_Nullable report);

NS_ASSUME_NONNULL_END
