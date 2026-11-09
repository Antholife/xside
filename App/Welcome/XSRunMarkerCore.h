// XSRunMarkerCore: the run marker's rules, without any file or UIKit, so
// scripts/test-welcome-hmac.sh can check them on the Mac. The marker (XSRunMarker in
// XSideWelcome.m keeps it in a small file in the app's container) records whether the app is in
// front ("running") or left cleanly ("clean"), and since when. At the next launch, a marker still
// "running" means the previous run stopped while in use (a crash, or killed while in front): a
// report the check-in carries to XSide on the Mac (`previousRunEnded`, `previousRunSince`, see
// Sources/XSideCore/Channel.swift) until a signed reply acknowledges it.
//
// Marker: @{@"state": @"running" | @"clean", @"since": NSDate, @"report": report (optional)}.
// Report: @{@"ended": @"crashed" | @"clean", @"since": NSDate}.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A marker read from disk (anything: hostile, truncated, older), checked field by field; nil when
/// it isn't one. A report that doesn't check out is dropped, the rest kept.
NSDictionary *_Nullable XSRunMarkerSanitized(id _Nullable raw);

/// The marker for a launch at `now`, from the previous one read from disk (`previous`, any value):
/// running since `now`, with the report of how the previous run ended. A report the previous
/// launch never got acknowledged is kept when it says "crashed" and the new one says "clean"
/// (the crash matters more); otherwise the newer report wins. No previous marker: no report.
NSDictionary *XSRunMarkerAtLaunch(id _Nullable previous, NSDate *now);

/// The app came to the front (`inFront`, YES: running since `now` unless it already was) or left
/// it (background, termination: clean). The report is kept.
NSDictionary *XSRunMarkerWithState(NSDictionary *marker, BOOL inFront, NSDate *now);

/// The report waiting to be sent, nil when none.
NSDictionary *_Nullable XSRunMarkerReport(NSDictionary *marker);

/// A signed reply came to a request that carried `sent`: the report goes, unless a newer one
/// replaced it meanwhile.
NSDictionary *XSRunMarkerAcknowledged(NSDictionary *marker, NSDictionary *_Nullable sent);

/// The marker as stored on disk (dates as epoch milliseconds, a property list).
NSDictionary *XSRunMarkerPlist(NSDictionary *marker);

NS_ASSUME_NONNULL_END
