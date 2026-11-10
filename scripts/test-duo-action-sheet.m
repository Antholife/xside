// The iPhone Duo module's UIActionSheet stand-in bookkeeping (App/DuoLegacy/XSActionSheetCore.m),
// compiled for the Mac by scripts/test-duo-action-sheet.sh. Exits non-zero on a failure.

#import <Foundation/Foundation.h>
#import "XSActionSheetCore.h"

static int failures = 0;

static void check(BOOL ok, NSString *what) {
    if (!ok) { failures++; fprintf(stderr, "FAIL: %s\n", what.UTF8String); }
    else printf("ok: %s\n", what.UTF8String);
}

int main(void) {
    @autoreleasepool {
        XSSheetButtons *b = [XSSheetButtons new];
        check(b.count == 0 && b.cancelIndex == -1 && b.destructiveIndex == -1 && b.firstOtherIndex == -1, @"empty at first");
        [b setUpWithCancel:@"Cancel" destructive:@"Delete" others:@[@"Share", @"Copy"]];
        check([b.titles isEqual:@[@"Delete", @"Share", @"Copy", @"Cancel"]], @"destructive, others, cancel last");
        check(b.destructiveIndex == 0 && b.cancelIndex == 3 && b.firstOtherIndex == 1, @"indexes as UIActionSheet sets them");
        check([b kindAt:0] == XSSheetButtonDestructive && [b kindAt:1] == XSSheetButtonDefault && [b kindAt:3] == XSSheetButtonCancel,
              @"kinds");
        check([b add:@"More"] == 4 && b.cancelIndex == 3, @"a button added later goes after the cancel one, which stays");
        check([b titleAt:4].length == 4 && [b titleAt:5] == nil && [b titleAt:-1] == nil, @"titles out of range are nil");
        check([b kindAt:-1] == XSSheetButtonDefault && [b kindAt:99] == XSSheetButtonDefault, @"kinds out of range are default");

        XSSheetButtons *c = [XSSheetButtons new];
        [c setUpWithCancel:nil destructive:nil others:@[]];
        check(c.count == 0 && c.cancelIndex == -1 && c.destructiveIndex == -1, @"all nil: no button");
        // The common pattern: buttons added one by one, cancel set from the last add.
        [c add:@"One"];
        c.cancelIndex = [c add:@"Cancel"];
        check(c.cancelIndex == 1 && c.firstOtherIndex == 0 && [c kindAt:1] == XSSheetButtonCancel, @"cancel from addButtonWithTitle:");
        c.destructiveIndex = 1;
        check([c kindAt:1] == XSSheetButtonCancel, @"cancel wins over destructive on the same button");
        c.cancelIndex = 7;
        check(c.cancelIndex == 7 && [c kindAt:1] == XSSheetButtonDestructive, @"an index out of range is kept but names nothing");
        check([c add:nil] == 2 && [[c titleAt:2] isEqualToString:@""], @"a nil title is an empty one");

        XSSheetButtons *d = [XSSheetButtons new];
        [d setUpWithCancel:@"Cancel" destructive:nil others:@[]];
        check(d.firstOtherIndex == -1 && d.cancelIndex == 0, @"only a cancel button: no other");

        check(!d.showing && ![d finish], @"nothing to finish before it shows");
        [d didShow];
        check(d.showing, @"showing");
        check([d finish] && !d.showing, @"the first dismissal runs");
        check(![d finish], @"a second one (the popover's own) doesn't");
        [d didShow];
        check([d finish], @"shown again: dismissed again");

        // A present UIKit declines (P1): the sheet must not stay stuck "showing".
        XSSheetButtons *e = [XSSheetButtons new];
        [e didShow];
        [e showDeclined];
        check(!e.showing, @"a declined present leaves it not showing");
        check(![e finish], @"nothing to finish: it never really showed");
        [e didShow];
        check([e finish] && !e.showing, @"shown for real after a decline: dismissed once");

        // A sheet with no button can't be dismissed on iPhone, so it isn't presented (P2).
        XSSheetButtons *f = [XSSheetButtons new];
        check(!f.presentable, @"no button: not presentable");
        [f add:@"OK"];
        check(f.presentable, @"one button: presentable");
        XSSheetButtons *g = [XSSheetButtons new];
        [g setUpWithCancel:@"Cancel" destructive:nil others:@[]];
        check(g.presentable, @"a lone cancel button: presentable");

        BOOL arrows = YES;
        CGRect r = XSSheetSourceRect(XSSheetShowInView, CGRectMake(0, 0, 400, 800), CGRectZero, &arrows);
        check(CGRectEqualToRect(r, CGRectMake(200, 400, 0, 0)) && !arrows, @"in a view: its centre, no arrow");
        r = XSSheetSourceRect(XSSheetShowFromRect, CGRectMake(0, 0, 400, 800), CGRectMake(10, 20, 30, 40), &arrows);
        check(CGRectEqualToRect(r, CGRectMake(10, 20, 30, 40)) && arrows, @"from a rect: that rect");
        r = XSSheetSourceRect(XSSheetShowFromBar, CGRectMake(0, 0, 400, 49), CGRectMake(1, 2, 3, 4), &arrows);
        check(CGRectEqualToRect(r, CGRectMake(0, 0, 400, 49)) && arrows, @"from a bar: its bounds");
        r = XSSheetSourceRect(XSSheetShowFromRect, CGRectMake(0, 0, 400, 800), CGRectMake(NAN, 0, INFINITY, 1), &arrows);
        check(CGRectEqualToRect(r, CGRectMake(200, 400, 0, 0)) && !arrows, @"a rect that isn't finite: the centre");
        r = XSSheetSourceRect(XSSheetShowInView, CGRectNull, CGRectZero, NULL);
        check(CGRectEqualToRect(r, CGRectZero), @"no bounds, no arrows pointer: zero, no crash");
    }
    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("all ok\n");
    return 0;
}
