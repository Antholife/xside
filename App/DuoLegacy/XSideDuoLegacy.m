// XSideDuoLegacy.dylib: the scene part of the "Add iPhone Duo compatibility" install option for an
// app that has no scene delegate of its own (see Sources/XSideCore/DuoCompatibility.swift). XSide
// raises such an app to SDK 27.1 so it fills the iPhone Duo's screens; iOS then stops any app that
// doesn't adopt scenes (_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption), so the
// Info.plist gets a UIApplicationSceneManifest naming XSDuoSceneDelegate (this library), which XSide
// copies into Frameworks/ and loads (weak load command). Independent of XSide's module
// (App/Welcome); added only to the installations that have the option, and only for such apps.
//
// What it does:
//  - on scene connect, adopts the app delegate's window (made in didFinishLaunching, which still runs
//    first under scenes) and any scene-less window: sets windowScene, sizes it to the scene, makes the
//    main one key and visible; windows shown later without a scene are attached too
//    (makeKeyAndVisible / setHidden:NO / setRootViewController:).
//  - until the scene connects, lists the windows the app made in UIApplication.windows (and the one
//    it made key in keyWindow): iOS lists none before then, and old apps read windows[0] in
//    didFinishLaunching (Plague Inc. crashed on it).
//  - forwards URL contexts -> application:openURL:options: (or the older forms), user activities ->
//    application:continueUserActivity:restorationHandler:, shortcut items ->
//    application:performActionForShortcutItem:completionHandler: (also those in the connection options).
//  - forwards the scene lifecycle -> applicationDidBecomeActive / WillResignActive /
//    DidEnterBackground / WillEnterForeground, skipping any UIKit already delivered to the app
//    delegate for that transition (counted by wrapping those methods) and the launch-time
//    willEnterForeground legacy apps never got.
//  - resizes the scene's full-size windows when its geometry changes (fold/unfold, a move between screens).
//
// It runs inside apps XSide doesn't know: it does nothing unless the Info.plist file on disk names
// XSDuoSceneDelegate; every hook checks the method exists; XSide's own work is wrapped so an
// exception never reaches the app. Logs: os_log, prefix "[XSDuoLegacy]".

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>

#define XSLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[XSDuoLegacy] " fmt, ##__VA_ARGS__)

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSString *const XSDelegateClassName = @"XSDuoSceneDelegate";

static BOOL gActive;                         // the manifest names our delegate: the hooks do their work
static NSHashTable<UIWindow *> *gWindows;    // every UIWindow created (weak)
static __weak UIWindowScene *gScene;         // the connected scene, once there is one
static NSPointerArray *gOrder;               // the same windows, in creation order (weak)
static __weak UIWindow *gKeyCandidate;       // the last window made key before the scene connected

static id<UIApplicationDelegate> XSAppDelegate(void) { return UIApplication.sharedApplication.delegate; }

static UIWindow *XSMainWindow(void) {
    id<UIApplicationDelegate> d = XSAppDelegate();
    if (![d respondsToSelector:@selector(window)]) return nil;
    id w = nil;
    @try { w = d.window; } @catch (__unused NSException *e) { return nil; }
    return [w isKindOfClass:UIWindow.class] ? w : nil;
}

// Size a window to the scene if it is meant to fill the screen (the app's main window, an empty
// frame, or one sized to the old screen or the old scene).
static void XSFit(UIWindow *w, UIWindowScene *s, CGSize oldSize, BOOL force) {
    if (!w || !s) return;
    CGRect b = s.coordinateSpace.bounds;
    if (CGRectIsEmpty(b) || CGRectEqualToRect(w.frame, b)) return;
    if (force || CGRectIsEmpty(w.frame) || CGSizeEqualToSize(w.frame.size, oldSize) ||
        CGSizeEqualToSize(w.frame.size, UIScreen.mainScreen.bounds.size)) {
        w.frame = b;
        XSLOG("fit %{public}@ to %{public}@", NSStringFromClass(w.class), NSStringFromCGRect(b));
    }
}

static void XSAttach(UIWindow *w, const char *why) {
    UIWindowScene *s = gScene;
    if (!gActive || !w || !s || w.windowScene) return;
    @try {
        CGSize old = w.frame.size;
        w.windowScene = s;
        XSFit(w, s, old, w == XSMainWindow());
        XSLOG("attached (%{public}s) %{public}@", why, NSStringFromClass(w.class));
    } @catch (NSException *e) {
        XSLOG("attach failed: %{public}@", e.reason);
    }
}

#pragma mark - UIWindow hooks: track windows, attach late scene-less ones

static IMP oInit, oInitWithFrame, oMakeKeyAndVisible, oSetHidden, oSetRoot;

static void XSTrack(UIWindow *w) {
    if (!w || !gWindows || [gWindows containsObject:w]) return;
    [gWindows addObject:w];
    [gOrder compact];
    [gOrder addPointer:(__bridge void *)w];
}
static id h_init(UIWindow *self, SEL _cmd) {
    self = ((id (*)(id, SEL))oInit)(self, _cmd);
    XSTrack(self);
    return self;
}
static id h_initWithFrame(UIWindow *self, SEL _cmd, CGRect f) {
    self = ((id (*)(id, SEL, CGRect))oInitWithFrame)(self, _cmd, f);
    XSTrack(self);
    return self;
}
static void h_makeKeyAndVisible(UIWindow *self, SEL _cmd) {
    if (!gScene) gKeyCandidate = self;
    XSAttach(self, "makeKeyAndVisible");
    ((void (*)(id, SEL))oMakeKeyAndVisible)(self, _cmd);
}
static void h_setHidden(UIWindow *self, SEL _cmd, BOOL hidden) {
    if (!hidden) XSAttach(self, "setHidden:NO");
    ((void (*)(id, SEL, BOOL))oSetHidden)(self, _cmd, hidden);
}
static void h_setRoot(UIWindow *self, SEL _cmd, UIViewController *vc) {
    ((void (*)(id, SEL, id))oSetRoot)(self, _cmd, vc);
    if (vc && !self.hidden) XSAttach(self, "setRootViewController");
}

#pragma mark - UIApplication hooks: the windows made before the scene connects

// Without scenes, the windows an app made in didFinishLaunching are already listed by
// UIApplication. With the scene manifest, iOS lists none until the scene connects (after
// didFinishLaunching): old apps reading `windows[0]` there crash (Plague Inc.), and `keyWindow` is
// nil. Until then, list the windows the app made, in creation order, as iOS did without scenes.
static IMP oAppWindows, oAppKeyWindow;

static NSArray<UIWindow *> *XSPendingWindows(void) {
    NSMutableArray<UIWindow *> *list = [NSMutableArray array];
    for (NSUInteger i = 0; i < gOrder.count; i++) {
        UIWindow *w = (__bridge UIWindow *)[gOrder pointerAtIndex:i];
        if (w && !w.windowScene) [list addObject:w];
    }
    return list;
}
static NSArray *h_appWindows(UIApplication *self, SEL _cmd) {
    NSArray *real = ((id (*)(id, SEL))oAppWindows)(self, _cmd);
    if (real.count || gScene || !gActive) return real;
    NSArray *pending = XSPendingWindows();
    if (pending.count) XSLOG("windows before the scene: %lu made by the app", (unsigned long)pending.count);
    return pending.count ? pending : real;
}
static UIWindow *h_appKeyWindow(UIApplication *self, SEL _cmd) {
    UIWindow *real = ((id (*)(id, SEL))oAppKeyWindow)(self, _cmd);
    if (real || gScene || !gActive) return real;
    UIWindow *k = gKeyCandidate;
    return (k && !k.windowScene) ? k : real;
}

// Replaces `sel` on `c` (added on `c` when inherited) and keeps the original. Returns NO, and
// changes nothing, when the method doesn't exist.
static BOOL XSHook(Class c, SEL sel, IMP repl, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { XSLOG("no method %{public}s on %{public}s", sel_getName(sel), class_getName(c)); return NO; }
    IMP current = method_getImplementation(m);
    if (class_addMethod(c, sel, repl, method_getTypeEncoding(m))) *orig = current;
    else *orig = method_setImplementation(m, repl);
    return YES;
}

#pragma mark - Legacy lifecycle forwarding without duplicates

typedef NS_ENUM(NSInteger, XSEvent) { XSDidBecomeActive, XSWillResignActive, XSDidEnterBackground, XSWillEnterForeground, XSEventCount };

static SEL XSEventSel(XSEvent e) {
    switch (e) {
        case XSDidBecomeActive:    return @selector(applicationDidBecomeActive:);
        case XSWillResignActive:   return @selector(applicationWillResignActive:);
        case XSDidEnterBackground: return @selector(applicationDidEnterBackground:);
        default:                   return @selector(applicationWillEnterForeground:);
    }
}
static NSInteger gAppCalls[XSEventCount];    // times the app delegate method ran (UIKit or us); main thread
static NSInteger gSceneEvents[XSEventCount]; // scene transitions we should have delivered; main thread

// Wraps the app delegate's lifecycle methods so we know when UIKit already called them.
static void XSWrapAppDelegate(void) {
    static BOOL done;
    id d = XSAppDelegate();
    if (done || !d) return;
    done = YES;
    Class c = object_getClass(d);
    for (XSEvent e = 0; e < XSEventCount; e++) {
        SEL sel = XSEventSel(e);
        Method m = class_getInstanceMethod(c, sel);
        if (!m) continue;
        IMP orig = method_getImplementation(m);
        IMP wrap = imp_implementationWithBlock(^(id me, UIApplication *app) {
            gAppCalls[e]++;
            ((void (*)(id, SEL, id))orig)(me, sel, app);
        });
        if (!class_addMethod(c, sel, wrap, method_getTypeEncoding(m))) method_setImplementation(m, wrap);
    }
    XSLOG("wrapped the lifecycle of %{public}s", class_getName(c));
}

static void XSForward(XSEvent e) {
    NSInteger expected = ++gSceneEvents[e];
    // Let UIKit finish this transition first: if it called the app delegate itself, don't call it again.
    dispatch_async(dispatch_get_main_queue(), ^{
        SEL sel = XSEventSel(e);
        if (gAppCalls[e] >= expected) return;
        id d = XSAppDelegate();
        if ([d respondsToSelector:sel]) {
            XSLOG("forward %{public}s", sel_getName(sel));
            ((void (*)(id, SEL, id))objc_msgSend)(d, sel, UIApplication.sharedApplication);
        }
        if (gAppCalls[e] < expected) gAppCalls[e] = expected;   // method missing: keep the counts in step
    });
}

#pragma mark - Scene delegate

@interface XSDuoSceneDelegate : UIResponder <UIWindowSceneDelegate>
@end

@implementation XSDuoSceneDelegate {
    UIWindow *_window;
    BOOL _connected;
}

- (UIWindow *)window { return _window ?: XSMainWindow(); }
- (void)setWindow:(UIWindow *)window { _window = window; }

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)opts {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    UIWindowScene *ws = (UIWindowScene *)scene;
    gScene = ws;
    @try {
        XSWrapAppDelegate();
        UIWindow *main = XSMainWindow();
        if (main) {
            XSAttach(main, "willConnect main");
            if (main.windowScene == ws) XSFit(main, ws, CGSizeZero, YES);
            _window = main;
        }
        for (UIWindow *w in gWindows.allObjects)
            if (w != main && !w.windowScene && (w.rootViewController || !w.hidden)) XSAttach(w, "willConnect other");
        if (main.windowScene == ws) [main makeKeyAndVisible];
        XSLOG("connected (%{public}s)", main ? "app window adopted" : "no app window yet");
    } @catch (NSException *e) {
        XSLOG("willConnect failed: %{public}@", e.reason);
    }

    NSSet<UIOpenURLContext *> *urls = opts.URLContexts;
    NSSet<NSUserActivity *> *acts = opts.userActivities;
    UIApplicationShortcutItem *sc = opts.shortcutItem;
    if (urls.count || acts.count || sc) {
        // Delivered after launch completes, as legacy apps expect (they got these after didFinishLaunching).
        dispatch_async(dispatch_get_main_queue(), ^{
            if (urls.count) [self scene:ws openURLContexts:urls];
            for (NSUserActivity *a in acts) [self scene:ws continueUserActivity:a];
            if (sc) [self windowScene:ws performActionForShortcutItem:sc completionHandler:^(BOOL ok) { (void)ok; }];
        });
    }
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    id<UIApplicationDelegate> d = XSAppDelegate();
    UIApplication *app = UIApplication.sharedApplication;
    for (UIOpenURLContext *c in contexts) {
        if (!c.URL) continue;
        NSMutableDictionary<UIApplicationOpenURLOptionsKey, id> *o = [NSMutableDictionary dictionary];
        if (c.options.sourceApplication) o[UIApplicationOpenURLOptionsSourceApplicationKey] = c.options.sourceApplication;
        if (c.options.annotation) o[UIApplicationOpenURLOptionsAnnotationKey] = c.options.annotation;
        o[UIApplicationOpenURLOptionsOpenInPlaceKey] = @(c.options.openInPlace);
        if ([d respondsToSelector:@selector(application:openURL:options:)])
            [d application:app openURL:c.URL options:o];
        else if ([d respondsToSelector:@selector(application:openURL:sourceApplication:annotation:)])
            [d application:app openURL:c.URL sourceApplication:c.options.sourceApplication annotation:c.options.annotation ?: @{}];
        else if ([d respondsToSelector:@selector(application:handleOpenURL:)])
            [d application:app handleOpenURL:c.URL];
    }
}

- (void)scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)activity {
    id<UIApplicationDelegate> d = XSAppDelegate();
    if ([d respondsToSelector:@selector(application:continueUserActivity:restorationHandler:)])
        [d application:UIApplication.sharedApplication continueUserActivity:activity
            restorationHandler:^(NSArray<id<UIUserActivityRestoring>> *objects) { (void)objects; }];
}

- (void)windowScene:(UIWindowScene *)ws performActionForShortcutItem:(UIApplicationShortcutItem *)item
  completionHandler:(void (^)(BOOL))done {
    id<UIApplicationDelegate> d = XSAppDelegate();
    if ([d respondsToSelector:@selector(application:performActionForShortcutItem:completionHandler:)])
        [d application:UIApplication.sharedApplication performActionForShortcutItem:item completionHandler:done];
    else if (done) done(NO);
}

- (void)sceneDidBecomeActive:(UIScene *)scene    { XSForward(XSDidBecomeActive); }
- (void)sceneWillResignActive:(UIScene *)scene   { XSForward(XSWillResignActive); }
- (void)sceneDidEnterBackground:(UIScene *)scene { XSForward(XSDidEnterBackground); }
- (void)sceneWillEnterForeground:(UIScene *)scene {
    if (!_connected) { _connected = YES; return; }   // legacy apps don't get willEnterForeground at launch
    XSForward(XSWillEnterForeground);
}

// Fold/unfold or a move between the Duo's screens: keep full-size windows matching the scene.
- (void)xsRefit:(UIWindowScene *)ws oldSize:(CGSize)oldSize {
    @try {
        UIWindow *main = XSMainWindow();
        for (UIWindow *w in ws.windows) XSFit(w, ws, oldSize, w == main);
    } @catch (NSException *e) {
        XSLOG("refit failed: %{public}@", e.reason);
    }
}

- (void)windowScene:(UIWindowScene *)ws didUpdateEffectiveGeometry:(UIWindowSceneGeometry *)previous API_AVAILABLE(ios(26.0)) {
    [self xsRefit:ws oldSize:previous.coordinateSpace.bounds.size];
}

- (void)windowScene:(UIWindowScene *)ws didUpdateCoordinateSpace:(id<UICoordinateSpace>)previous
  interfaceOrientation:(UIInterfaceOrientation)orientation traitCollection:(UITraitCollection *)traits {
    [self xsRefit:ws oldSize:previous.bounds.size];
}

@end

// The Info.plist file on disk (not NSBundle, which tweaks can fake) names our delegate.
static BOOL XSManifestNamesUs(void) {
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    id manifest = info[@"UIApplicationSceneManifest"];
    if (![manifest isKindOfClass:NSDictionary.class]) return NO;
    id configs = manifest[@"UISceneConfigurations"];
    if (![configs isKindOfClass:NSDictionary.class]) return NO;
    id roles = configs[@"UIWindowSceneSessionRoleApplication"];
    if (![roles isKindOfClass:NSArray.class] || [roles count] == 0) return NO;
    id first = [roles firstObject];
    if (![first isKindOfClass:NSDictionary.class]) return NO;
    id name = first[@"UISceneDelegateClassName"];
    return [name isKindOfClass:NSString.class] && [name isEqualToString:XSDelegateClassName];
}

__attribute__((constructor)) static void XSDuoLegacyInit(void) {
    @autoreleasepool {
        @try {
            if (!XSManifestNamesUs()) { XSLOG("inactive: the manifest doesn't name %{public}@", XSDelegateClassName); return; }
            gWindows = [NSHashTable weakObjectsHashTable];
            gOrder = [NSPointerArray weakObjectsPointerArray];
            Class W = UIWindow.class;
            // init/initWithFrame: only track windows; the others attach. A missing one is skipped.
            XSHook(W, @selector(init), (IMP)h_init, &oInit);
            XSHook(W, @selector(initWithFrame:), (IMP)h_initWithFrame, &oInitWithFrame);
            XSHook(W, @selector(makeKeyAndVisible), (IMP)h_makeKeyAndVisible, &oMakeKeyAndVisible);
            XSHook(W, @selector(setHidden:), (IMP)h_setHidden, &oSetHidden);
            XSHook(W, @selector(setRootViewController:), (IMP)h_setRoot, &oSetRoot);
            Class A = UIApplication.class;
            XSHook(A, @selector(windows), (IMP)h_appWindows, &oAppWindows);
            XSHook(A, @selector(keyWindow), (IMP)h_appKeyWindow, &oAppKeyWindow);
            gActive = YES;
            XSLOG("loaded");
        } @catch (NSException *e) {
            XSLOG("not loaded: %{public}@", e.reason);
        }
    }
}
