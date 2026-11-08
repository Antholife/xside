// The quick actions XSide adds to the app's icon (spec §3): XSide Settings, Refresh now, Report
// a problem. They are dynamic items (UIApplication.shortcutItems), set by the library and placed
// only in the slots the app leaves: iOS shows 4 at most, the app's static items first, then its
// dynamic ones (final review Important 1: static items of XSide's pushed the app's dynamic ones
// out). The library wraps -[UIApplication setShortcutItems:] so whatever the app sets comes first,
// XSide's being re-added after it in the slots left. The getter is left alone (UIKit may use it
// itself): an app reading the items sees XSide's too, and setting them back changes nothing.
// iOS delivers a pressed item to the app's own delegates, so the library wraps the delegates'
// entry points: it handles only XSide's types (io.github.xside.shortcut.*) and passes everything
// else to the app's implementation untouched. A delegate without such a method gets XSide's.

#import "XSShortcuts.h"
#import "XSChannel.h"
#import "XSSettingsCore.h"
#import <objc/runtime.h>

static NSString *const XSShortcutPrefix = @"io.github.xside.shortcut.";
static NSString *const XSIssueURL = @"https://github.com/Antholife/xside/issues/new";

// MARK: - The items

static IMP XSOriginalSetItems;

/// What iOS holds, XSide's items included.
static NSArray<UIApplicationShortcutItem *> *XSAllItems(void) {
    NSArray *items = UIApplication.sharedApplication.shortcutItems;
    return [items isKindOfClass:NSArray.class] ? items : @[];
}

static NSArray<UIApplicationShortcutItem *> *XSAppItemsOf(NSArray *items) {
    NSMutableArray *own = [NSMutableArray array];
    for (id item in items) {
        if (![item isKindOfClass:UIApplicationShortcutItem.class]) continue;
        if (!XSIsXSideShortcutType(((UIApplicationShortcutItem *)item).type)) [own addObject:item];
    }
    return own;
}

static UIApplicationShortcutItem *XSItem(NSString *name) {
    NSString *title = [name isEqualToString:@"settings"] ? XST(@"Réglages XSide", @"XSide Settings")
        : [name isEqualToString:@"refresh"] ? XST(@"Rafraîchir maintenant", @"Refresh now")
        : XST(@"Signaler un problème", @"Report a problem");
    NSString *symbol = [name isEqualToString:@"settings"] ? @"gearshape"
        : [name isEqualToString:@"refresh"] ? @"arrow.clockwise" : @"ladybug";
    return [[UIApplicationShortcutItem alloc] initWithType:[XSShortcutPrefix stringByAppendingString:name]
                                            localizedTitle:title localizedSubtitle:nil
                                                      icon:[UIApplicationShortcutIcon iconWithSystemImageName:symbol]
                                                  userInfo:nil];
}

/// The app's `items` (XSide's dropped), then XSide's in the slots they leave.
static NSArray<UIApplicationShortcutItem *> *XSWithXSideItems(NSArray *items) {
    NSArray *own = XSAppItemsOf(items);
    NSMutableArray *all = [own mutableCopy];
    for (NSString *name in XSShortcutNamesFitting(XSAppStaticShortcutCount(XSInfo()[@"UIApplicationShortcutItems"]), own.count)) {
        [all addObject:XSItem(name)];
    }
    return all;
}

static void XSSetAllItems(NSArray *items) {
    if (XSOriginalSetItems) {
        ((void (*)(id, SEL, NSArray *))XSOriginalSetItems)(UIApplication.sharedApplication, @selector(setShortcutItems:), items);
    }
}

void XSUpdateShortcuts(void) {
    if (!XSOriginalSetItems) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ XSUpdateShortcuts(); });
        return;
    }
    NSArray *current = XSAllItems();
    NSArray *wanted = XSWithXSideItems(current);
    if (![wanted isEqualToArray:current]) XSSetAllItems(wanted);
}

BOOL XSHasShortcuts(void) {
    if (!XSOriginalSetItems) return NO;
    for (UIApplicationShortcutItem *item in XSAllItems()) if (XSIsXSideShortcutType(item.type)) return YES;
    return NO;
}

/// The app's items first; XSide's follow in the slots left.
static void XSWrapShortcutItemsSetter(void) {
    Method set = class_getInstanceMethod(UIApplication.class, @selector(setShortcutItems:));
    if (!set) return;
    XSOriginalSetItems = method_getImplementation(set);
    IMP wrappedSet = imp_implementationWithBlock(^(id me, NSArray *items) {
        NSArray *all = items;
        @try { all = XSWithXSideItems(items ?: @[]); } @catch (NSException *e) { NSLog(@"[XSide] quick actions: %@", e); }
        ((void (*)(id, SEL, NSArray *))XSOriginalSetItems)(me, @selector(setShortcutItems:), all);
    });
    method_setImplementation(set, wrappedSet);
}

/// XSide's bug form, prefilled: app name and version, device model, iOS, expiry. No identifiers.
static void XSOpenReport(void) {
    NSDate *expiry = XSExpirationDate();
    NSString *app = [NSString stringWithFormat:@"%@ %@", XSAppName(), XSAppVersion() ?: @""];
    NSString *device = [NSString stringWithFormat:@"%@, iOS %@", XSDeviceModel(), UIDevice.currentDevice.systemVersion];
    NSString *until = @"?";
    if (expiry) {
        NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
        until = [iso stringFromDate:expiry];
    }
    NSString *what = [NSString stringWithFormat:@"\n\n---\nSent from the app's quick action on the %@.\nApp: %@\nValid until: %@",
                      XSDeviceKind(), app, until];
    NSURLComponents *components = [NSURLComponents componentsWithString:XSIssueURL];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"template" value:@"bug_report.yml"],
                              [NSURLQueryItem queryItemWithName:@"what" value:what],
                              [NSURLQueryItem queryItemWithName:@"device" value:device],
                              [NSURLQueryItem queryItemWithName:@"ipa" value:app]];
    // "+" must not read as a space (as IssueReport does on the Mac).
    components.percentEncodedQuery = [components.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    NSURL *url = components.URL;
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

static NSString *XSLastHandledType;
static NSDate *XSLastHandledAt;

/// YES for XSide's own items (handled here), NO for the app's.
static BOOL XSHandleShortcut(UIApplicationShortcutItem *item) {
    NSString *type = [item isKindOfClass:UIApplicationShortcutItem.class] ? item.type : nil;
    if (![type isKindOfClass:NSString.class] || ![type hasPrefix:XSShortcutPrefix]) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        // A cold launch can deliver one press twice (launch options, then the delegate).
        if ([type isEqualToString:XSLastHandledType] && XSLastHandledAt && -XSLastHandledAt.timeIntervalSinceNow < 3) return;
        XSLastHandledType = type;
        XSLastHandledAt = NSDate.date;
        NSString *name = [type substringFromIndex:XSShortcutPrefix.length];
        NSLog(@"[XSide] quick action %@", name);
        XSWhenForeground(0.3, ^{
            if ([name isEqualToString:@"refresh"]) XSRequestRefresh();
            else if ([name isEqualToString:@"settings"]) XSOpenAppSettings();
            else if ([name isEqualToString:@"report"]) XSOpenReport();
        });
    });
    return YES;
}

// MARK: - Wrapping the delegates

static NSMutableSet<NSString *> *XSPatched;

/// Proxies (NSProxy) forward to another object: adding methods to them would hide the target's.
static BOOL XSIsProxy(id object) {
    for (Class c = object_getClass(object); c; c = class_getSuperclass(c)) if (c == NSProxy.class) return YES;
    return NO;
}

/// Wraps `sel` on `delegate`'s class with `make(original)` (original may be NULL: the method is
/// added). Each class once. Leaves alone proxies and methods answered by message forwarding.
static void XSWrap(id delegate, SEL sel, Protocol *protocol, IMP (^make)(IMP original)) {
    if (!delegate || XSIsProxy(delegate)) return;
    Class cls = object_getClass(delegate);
    NSString *key = [NSString stringWithFormat:@"%s %s", class_getName(cls), sel_getName(sel)];
    @synchronized (XSPatched) {
        if ([XSPatched containsObject:key]) return;
        Method method = class_getInstanceMethod(cls, sel);
        if (!method && [delegate respondsToSelector:sel]) return;
        const char *types = method ? method_getTypeEncoding(method) : protocol_getMethodDescription(protocol, sel, NO, YES).types;
        if (!types) return;
        [XSPatched addObject:key];
        IMP original = method ? method_getImplementation(method) : NULL;
        IMP wrapped = make(original);
        // Added on the class itself when inherited (the superclass keeps its own), else replaced.
        if (!class_addMethod(cls, sel, wrapped, types) && method) method_setImplementation(method, wrapped);
    }
}

typedef void (^XSShortcutCompletion)(BOOL);

/// application:performActionForShortcutItem:completionHandler: and
/// windowScene:performActionForShortcutItem:completionHandler: (same shape).
static void XSWrapPerformAction(id delegate, SEL sel, Protocol *protocol) {
    XSWrap(delegate, sel, protocol, ^IMP(IMP original) {
        return imp_implementationWithBlock(^(id me, id sender, UIApplicationShortcutItem *item, XSShortcutCompletion completion) {
            if (XSHandleShortcut(item)) {
                if (completion) completion(YES);
                return;
            }
            if (original) ((void (*)(id, SEL, id, id, XSShortcutCompletion))original)(me, sel, sender, item, completion);
            else if (completion) completion(NO);
        });
    });
}

/// scene:willConnectToSession:options:, where a cold launch from a quick action brings its item.
static void XSWrapWillConnect(id delegate) {
    SEL sel = @selector(scene:willConnectToSession:options:);
    XSWrap(delegate, sel, @protocol(UISceneDelegate), ^IMP(IMP original) {
        return imp_implementationWithBlock(^(id me, UIScene *scene, UISceneSession *session, UISceneConnectionOptions *options) {
            if (original) ((void (*)(id, SEL, id, id, id))original)(me, sel, scene, session, options);
            UIApplicationShortcutItem *item = options.shortcutItem;
            if (item) XSHandleShortcut(item);
        });
    });
}

static void XSPatchAppDelegate(id delegate) {
    XSWrapPerformAction(delegate, @selector(application:performActionForShortcutItem:completionHandler:),
                        @protocol(UIApplicationDelegate));
}

static void XSPatchSceneDelegate(id delegate) {
    XSWrapPerformAction(delegate, @selector(windowScene:performActionForShortcutItem:completionHandler:),
                        @protocol(UIWindowSceneDelegate));
    XSWrapWillConnect(delegate);
}

/// Wraps `cls`'s setDelegate: so the delegate is patched before UIKit looks at what it implements.
static void XSHookDelegateSetter(Class cls, void (^patch)(id delegate)) {
    SEL sel = @selector(setDelegate:);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    IMP original = method_getImplementation(method);
    IMP wrapped = imp_implementationWithBlock(^(id me, id delegate) {
        if (delegate) {
            @try { patch(delegate); } @catch (NSException *e) { NSLog(@"[XSide] quick actions: %@", e); }
        }
        ((void (*)(id, SEL, id))original)(me, sel, delegate);
    });
    if (!class_addMethod(cls, sel, wrapped, method_getTypeEncoding(method))) method_setImplementation(method, wrapped);
}

void XSInstallShortcuts(void) {
    // Only in an app XSide signed with its features (the payload is there).
    if (XSPayload().count == 0) return;
    XSPatched = [NSMutableSet set];
    XSWrapShortcutItemsSetter();
    XSHookDelegateSetter(UIApplication.class, ^(id delegate) { XSPatchAppDelegate(delegate); });
    XSHookDelegateSetter(UIScene.class, ^(id delegate) { XSPatchSceneDelegate(delegate); });
    // Fallbacks when a delegate was set some other way, and the cold launch of an app without
    // scenes (its item is in the launch options).
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        XSPatchAppDelegate(UIApplication.sharedApplication.delegate);
        id item = note.userInfo[UIApplicationLaunchOptionsShortcutItemKey];
        if ([item isKindOfClass:UIApplicationShortcutItem.class]) XSHandleShortcut(item);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillConnectNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:UIScene.class]) XSPatchSceneDelegate(((UIScene *)note.object).delegate);
    }];
}
