// The iPhone Duo module's held notification callbacks (App/DuoLegacy/XSLaunchHoldCore.m),
// compiled for the Mac by scripts/test-duo-launch-hold.sh. Exits non-zero on a failure.

#import <Foundation/Foundation.h>
#import "XSLaunchHoldCore.h"

static int failures = 0;

static void check(BOOL ok, NSString *what) {
    if (!ok) { failures++; fprintf(stderr, "FAIL: %s\n", what.UTF8String); }
    else printf("ok: %s\n", what.UTF8String);
}

static XSLaunchHold *holdTwo(NSMutableArray<NSString *> *log) {
    XSLaunchHold *h = [XSLaunchHold new];
    // A completion handler made here and held past this scope, as UIKit hands it.
    id handler = XSLaunchHoldKeep(^(NSUInteger r) { [log addObject:[NSString stringWithFormat:@"handler %lu", (unsigned long)r]]; });
    NSDictionary *info = @{@"aps": @{@"alert": @"hi"}};
    check([h hold:^{ [log addObject:[NSString stringWithFormat:@"remote %@", info[@"aps"][@"alert"]]]; ((void (^)(NSUInteger))handler)(1); }],
          @"a notification is held while the launch waits");
    check([h hold:^{ [log addObject:@"local"]; }], @"a second one too");
    return h;
}

int main(void) {
    @autoreleasepool {
        check(XSLaunchHoldWaits("application:didReceiveRemoteNotification:fetchCompletionHandler:"), @"remote with handler waits");
        check(XSLaunchHoldWaits("application:didReceiveRemoteNotification:"), @"remote waits");
        check(XSLaunchHoldWaits("application:didReceiveLocalNotification:"), @"local waits");
        for (NSString *s in @[@"application:performFetchWithCompletionHandler:",
                              @"application:handleEventsForBackgroundURLSession:completionHandler:",
                              @"application:didRegisterForRemoteNotificationsWithDeviceToken:",
                              @"application:didFailToRegisterForRemoteNotificationsWithError:", @"", @"application:"])
            check(!XSLaunchHoldWaits(s.UTF8String), [NSString stringWithFormat:@"%@ runs the launch first", s]);

        NSMutableArray<NSString *> *log = [NSMutableArray array];
        XSLaunchHold *h = holdTwo(log);
        check(h.count == 2 && log.count == 0, @"nothing runs before the replay");
        [h replay];
        check([log isEqual:@[@"remote hi", @"handler 1", @"local"]], [NSString stringWithFormat:@"replayed in order, handler called: %@", log]);
        check(h.count == 0, @"none left after the replay");
        [h replay];
        check(log.count == 3, @"a second replay runs nothing again");
        __block BOOL late = NO;
        check(![h hold:^{ late = YES; }] && !late, @"after the replay a call is refused (the caller calls it now)");

        XSLaunchHold *full = [XSLaunchHold new];
        __block NSUInteger ran = 0;
        for (NSUInteger i = 0; i < XSLaunchHold.capacity; i++) [full hold:^{ ran++; }];
        check(![full hold:^{ ran++; }], @"one past the capacity is refused");
        [full replay];
        check(ran == XSLaunchHold.capacity, @"the held ones all ran");

        check(XSLaunchHoldKeep(nil) == nil, @"nil kept as nil");
        NSString *s = @"x";
        check(XSLaunchHoldKeep(s) == s, @"an object kept as it is");
    }
    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("all ok\n");
    return 0;
}
