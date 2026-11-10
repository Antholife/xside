// The UIActionSheet stand-in's bookkeeping; see XSActionSheetCore.h.

#import "XSActionSheetCore.h"

@implementation XSSheetButtons {
    NSMutableArray<NSString *> *_titles;
}

- (instancetype)init {
    if ((self = [super init])) {
        _titles = [NSMutableArray array];
        _cancelIndex = -1;
        _destructiveIndex = -1;
    }
    return self;
}

- (void)setUpWithCancel:(NSString *)cancel destructive:(NSString *)destructive others:(NSArray<NSString *> *)others {
    if (destructive) _destructiveIndex = [self add:destructive];
    for (id title in others) if ([title isKindOfClass:NSString.class]) [self add:title];
    if (cancel) _cancelIndex = [self add:cancel];
}

- (NSInteger)add:(NSString *)title {
    [_titles addObject:[title isKindOfClass:NSString.class] ? [title copy] : @""];
    return (NSInteger)_titles.count - 1;
}

- (NSArray<NSString *> *)titles { return [_titles copy]; }
- (NSInteger)count { return (NSInteger)_titles.count; }
- (BOOL)presentable { return _titles.count > 0; }

- (NSInteger)firstOtherIndex {
    for (NSInteger i = 0; i < (NSInteger)_titles.count; i++) if ([self kindAt:i] == XSSheetButtonDefault) return i;
    return -1;
}

- (NSString *)titleAt:(NSInteger)index {
    return index >= 0 && index < (NSInteger)_titles.count ? _titles[(NSUInteger)index] : nil;
}

- (XSSheetButtonKind)kindAt:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_titles.count) return XSSheetButtonDefault;
    if (index == _cancelIndex) return XSSheetButtonCancel;
    if (index == _destructiveIndex) return XSSheetButtonDestructive;
    return XSSheetButtonDefault;
}

- (void)didShow { _showing = YES; }

- (void)showDeclined { _showing = NO; }

- (BOOL)finish {
    if (!_showing) return NO;
    _showing = NO;
    return YES;
}

@end

static BOOL XSFinite(CGRect r) {
    return !CGRectIsNull(r) && isfinite(r.origin.x) && isfinite(r.origin.y) && isfinite(r.size.width) && isfinite(r.size.height);
}

CGRect XSSheetSourceRect(XSSheetShow how, CGRect viewBounds, CGRect rect, BOOL *arrows) {
    BOOL withArrows = YES;
    CGRect out;
    if (how == XSSheetShowFromRect && XSFinite(rect)) {
        out = rect;
    } else if (how == XSSheetShowFromBar && XSFinite(viewBounds)) {
        out = viewBounds;
    } else if (XSFinite(viewBounds)) {
        out = CGRectMake(CGRectGetMidX(viewBounds), CGRectGetMidY(viewBounds), 0, 0);
        withArrows = NO;
    } else {
        out = CGRectZero;
        withArrows = NO;
    }
    if (arrows) *arrows = withArrows;
    return out;
}
