// The pill at the top of the screen (spec §1, mockup pill.html): validity at launch, late and
// paused alerts, and the answers to a Refresh asked from the phone.

#import "XSCommon.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XSPillTone) { XSPillToneNeutral, XSPillToneOrange, XSPillToneRed };

@interface XSPillContent : NSObject
/// First line: `lead`, then `strong` in bold (orange or red with the tone), then `tail`.
@property (nonatomic, copy) NSString *lead;
@property (nonatomic, copy, nullable) NSString *strong;
@property (nonatomic, copy, nullable) NSString *tail;
/// Smaller lines under it.
@property (nonatomic, copy, nullable) NSString *hint;
@property (nonatomic) XSPillTone tone;
/// Seconds on screen; 0 keeps it until another pill replaces it (work in progress).
@property (nonatomic) NSTimeInterval duration;
/// A spinner on the right (work in progress).
@property (nonatomic) BOOL busy;
@property (nonatomic, copy, nullable) NSString *buttonTitle;
@property (nonatomic, copy, nullable) void (^action)(void);
/// A tap on the pill itself (outside the button) runs this instead of only dismissing it.
@property (nonatomic, copy, nullable) void (^tapAction)(void);
/// The answer to something the person just asked (a Refresh and its outcome, a pill's button):
/// shown even with every message off (XSShowsPill).
@property (nonatomic) BOOL answer;
@end

/// Shows `content`, replacing any pill on screen. Waits a few seconds for a foreground scene.
/// Nothing with every message off ("Aucun"), unless it is an answer (XSShowsPill).
void XSShowPill(XSPillContent *content);
/// An answer to a Refresh that came while the app was in the background (XSShowPill keeps it):
/// shown now, if still recent. On return from the background.
void XSShowKeptAnswer(void);
/// The same, without cutting short a pill already on screen (the launch pill, a refresh's): it
/// waits until that one is gone (30 s at most, then it is dropped). Only one waits, the newest; a
/// pill shown this way replaces another shown this way at once (sending → sent).
void XSShowPillWhenFree(XSPillContent *content);

/// The pill for this cold launch (validity, late, paused, last requested refresh failed), or
/// nil when the settings say nothing should show.
XSPillContent *_Nullable XSLaunchPillContent(NSDate *expiry);

/// The pill for a pending state (a failure reason key, or XSNoOutcomeKey), with Rafraîchir.
XSPillContent *XSPendingPillContent(NSString *key);
/// Shows (and clears) the pending state now, if the app is on screen. It answers a Refresh the
/// person asked for, so "Aucun" doesn't hide it.
void XSShowPendingPill(void);

/// With the reminder on and notifications never asked (the install sheet didn't): once, a pill
/// that says why and asks on OK. Otherwise runs `otherwise` (main queue).
void XSOfferNotificationsIfNeeded(void (^otherwise)(void));

NS_ASSUME_NONNULL_END
