// The UIActionSheet stand-in's bookkeeping (button indexes, which one is cancel or destructive,
// one dismissal per showing, where its popover points), Foundation only so
// scripts/test-duo-action-sheet.sh checks it on the Mac. XSideDuoLegacy.m shows the sheet itself.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XSSheetButtonKind) {
    XSSheetButtonDefault,
    XSSheetButtonCancel,
    XSSheetButtonDestructive,
};

@interface XSSheetButtons : NSObject
/// UIActionSheet's init order: the destructive button first, then the others, the cancel one
/// last; each index set to where it went (-1 when there is none).
- (void)setUpWithCancel:(nullable NSString *)cancel destructive:(nullable NSString *)destructive
                 others:(NSArray<NSString *> *)others;
/// Adds a button at the end and returns its index (a nil title is an empty one).
- (NSInteger)add:(nullable NSString *)title;
@property (readonly) NSArray<NSString *> *titles;
@property (readonly) NSInteger count;
/// NO when there is no button: on iPhone an action sheet with none has nothing to dismiss it,
/// so the stand-in doesn't show it (an app with no buttons gets nothing).
@property (readonly) BOOL presentable;
/// -1: none. Any value is kept, as UIActionSheet does; only an index in range counts.
@property (nonatomic) NSInteger cancelIndex, destructiveIndex;
/// The first button that is neither cancel nor destructive, -1 when there is none.
@property (readonly) NSInteger firstOtherIndex;
- (nullable NSString *)titleAt:(NSInteger)index;
/// Cancel wins when both indexes name the same button (an alert controller has one cancel action).
- (XSSheetButtonKind)kindAt:(NSInteger)index;

/// The sheet is on screen (from `didShow` to the first `finish`).
@property (readonly) BOOL showing;
- (void)didShow;
/// UIKit declined the present after `didShow` (it was already presenting, or the view was detached):
/// undo it, as if the sheet never showed. No dismissal ran, so a later `didShow` shows and finishes
/// normally. Distinct from `finish`, which is the one dismissal of a sheet that did show.
- (void)showDeclined;
/// YES the first time after `didShow`: the dismissal runs once whatever ends it (a button, the
/// app's dismiss call, a tap outside the popover).
- (BOOL)finish;
@end

typedef NS_ENUM(NSInteger, XSSheetShow) {
    XSSheetShowInView,      // showInView:
    XSSheetShowFromRect,    // showFromRect:inView:animated:
    XSSheetShowFromBar,     // showFromTabBar: / showFromToolbar:
};

/// Where the popover (iPad, the Duo's wide screen) points in the source view: a point at the
/// view's centre without an arrow for showInView:, the rect given, or the bar's bounds. `arrows`:
/// NO when the popover should have none.
CGRect XSSheetSourceRect(XSSheetShow how, CGRect viewBounds, CGRect rect, BOOL *_Nullable arrows);

NS_ASSUME_NONNULL_END
