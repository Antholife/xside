// The app delegate's notification callbacks held until its deferred launch has run (re-review
// N1), Foundation only so scripts/test-duo-launch-hold.sh checks it on the Mac. XSideDuoLegacy.m
// holds them while didFinishLaunching waits for the scene, and replays them once it ran.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Whether UIKit's call `selName` to the app delegate waits for the deferred launch: a
/// notification the person may have tapped to open the app (its scene is coming). The other
/// background entry points (fetch, URL session, push token) run the launch first instead.
BOOL XSLaunchHoldWaits(const char *selName);

/// `value` kept for a later call: a block copied to the heap, anything else as it is.
id _Nullable XSLaunchHoldKeep(id _Nullable value);

@interface XSLaunchHold : NSObject
/// Calls held at most; one more is refused (the caller runs the launch and calls at once).
@property (class, readonly) NSUInteger capacity;
@property (readonly) NSUInteger count;
/// Keeps `call` for the replay. NO once replayed, or full: the caller calls it now.
- (BOOL)hold:(dispatch_block_t)call;
/// Runs the calls held, in the order they came, once; later holds are refused.
- (void)replay;
@end

NS_ASSUME_NONNULL_END
