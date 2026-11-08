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
@end

/// Shows `content`, replacing any pill on screen. Waits a few seconds for a foreground scene.
void XSShowPill(XSPillContent *content);

/// The pill for this cold launch (validity, late, paused, last requested refresh failed), or
/// nil when the settings say nothing should show.
XSPillContent *_Nullable XSLaunchPillContent(NSDate *expiry);

NS_ASSUME_NONNULL_END
