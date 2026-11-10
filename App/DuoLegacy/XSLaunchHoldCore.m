// See XSLaunchHoldCore.h.

#import "XSLaunchHoldCore.h"

BOOL XSLaunchHoldWaits(const char *selName) {
    if (!selName) return NO;
    static const char *const waiting[] = {
        "application:didReceiveRemoteNotification:fetchCompletionHandler:",
        "application:didReceiveRemoteNotification:",
        "application:didReceiveLocalNotification:",
    };
    for (size_t i = 0; i < sizeof waiting / sizeof waiting[0]; i++)
        if (strcmp(selName, waiting[i]) == 0) return YES;
    return NO;
}

id XSLaunchHoldKeep(id value) {
    static Class blockClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ blockClass = NSClassFromString(@"NSBlock"); });
    if (value && blockClass && [value isKindOfClass:blockClass]) return [value copy];
    return value;
}

@implementation XSLaunchHold {
    NSMutableArray<dispatch_block_t> *_calls;
    BOOL _replayed;
}

+ (NSUInteger)capacity { return 32; }

- (instancetype)init {
    if ((self = [super init])) _calls = [NSMutableArray array];
    return self;
}

- (NSUInteger)count { return _calls.count; }

- (BOOL)hold:(dispatch_block_t)call {
    if (_replayed || !call || _calls.count >= XSLaunchHold.capacity) return NO;
    [_calls addObject:[call copy]];
    return YES;
}

- (void)replay {
    if (_replayed) return;
    _replayed = YES;
    NSArray<dispatch_block_t> *calls = [_calls copy];
    [_calls removeAllObjects];
    for (dispatch_block_t call in calls) call();
}

@end
