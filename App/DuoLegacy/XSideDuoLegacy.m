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
//  - runs the app delegate's didFinishLaunching when the scene connects instead of before: legacy
//    apps size their window and views there from UIScreen.mainScreen / their window (games: Plague
//    Inc., Geometry Dash), and before the scene connects iOS reports another size than the scene's,
//    so their layout covered part of the screen. When no scene comes within XSLaunchDeferLimit
//    seconds (a background launch), it runs then; at once for a launch whose options only a
//    background launch carries (location, Bluetooth), and before any background entry
//    point UIKit calls first (fetch, URL session, push token...). A notification callback (remote
//    or local: maybe the tap that opens the app) is held instead and replayed once it ran.
//  - a storyboard app: iOS loads the storyboard the manifest names into the scene delegate's
//    window, handed to the app delegate when it has none (where it was without scenes).
//  - until the scene connects, lists the windows the app made in UIApplication.windows (and the one
//    it made key in keyWindow): iOS lists none before then, and old apps read windows[0] in
//    didFinishLaunching (Plague Inc. crashed on it).
//  - gives back two APIs that iOS 27 turns off for apps built with its SDK (the SDK raise): UIApplication
//    statusBarOrientation (a no-op: now the scene's orientation, which old games lay out from) and
//    UIAccelerometer ("no longer available": now fed by CoreMotion, same values in g, to the delegate's
//    accelerometer:didAccelerate:). Boost 2 needed both. UIAlertView too ("no longer available" on
//    init): a stand-in with the same API and delegate calls shows a UIAlertController on the scene.
//    UIActionSheet likewise: an action-sheet UIAlertController, a popover on a wide screen pointed
//    where the show call says (bookkeeping in XSActionSheetCore.m).
//  - UIScreen.mainScreen is the scene's screen once it connects: on the Duo it otherwise stays the
//    outer screen while the app shows on the inner one (Boost 2 sized itself to it: a small picture).
//    Off the main thread, the last screen the main thread saw (UIKit is read on the main one only).
//  - on a screen other than iOS's main one (the Duo's inner screen), accelerometer x/y are turned a
//    quarter to that screen's axes (the outer screen's are the sensor's).
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
#import <CoreMotion/CoreMotion.h>
#import <os/lock.h>
#import "XSLaunchHoldCore.h"
#import "XSActionSheetCore.h"

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

#pragma mark - APIs iOS 27 turns off for its SDK: statusBarOrientation, UIAccelerometer

static IMP oStatusBarOrientation;
static UIInterfaceOrientation h_statusBarOrientation(UIApplication *self, SEL _cmd) {
    UIWindowScene *s = gScene;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (s && s.interfaceOrientation != UIInterfaceOrientationUnknown) return s.interfaceOrientation;
#pragma clang diagnostic pop
    return ((UIInterfaceOrientation (*)(id, SEL))oStatusBarOrientation)(self, _cmd);
}

// What the delegate gets in place of a UIAcceleration (the class itself can't be made any more):
// the same readers.
@interface XSAcceleration : NSObject
@property (nonatomic) double x, y, z;
@property (nonatomic) NSTimeInterval timestamp;
@end
@implementation XSAcceleration
@end

static IMP oMainScreen;

// The sensor's x/y, turned to the axes of the screen the app shows on. On the Duo the sensor's
// axes are the outer screen's (iOS's own main screen); on the inner one they are a quarter turn
// off for the app: at rest, held in landscape, y read -0.5 instead of x (Boost 2 steered by itself).
static void XSAccelAxes(double *x, double *y) {
    UIScreen *shown = gScene.screen;
    UIScreen *main = oMainScreen ? ((id (*)(id, SEL))oMainScreen)(UIScreen.class, @selector(mainScreen)) : nil;
    BOOL turned = shown && main && shown != main;
    static int logged = -1;
    if (logged != turned) {
        logged = turned;
        XSLOG("accelerometer axes: %{public}s", turned ? "inner screen, turned a quarter" : "main screen, as is");
    }
    if (!turned) return;
    double sx = *x;
    *x = -*y;
    *y = sx;
}

static CMMotionManager *gMotion;
static NSTimeInterval gAccelInterval = 0.1;       // UIAccelerometer's default
static __weak id gAccelDelegate;
static NSInteger gAccelLogged;                    // samples logged, the first seconds only

static void XSAccelStart(id accelerometer) {
    if (!gMotion) gMotion = [CMMotionManager new];
    if (!gMotion.accelerometerAvailable) { XSLOG("accelerometer: not available"); return; }
    gMotion.accelerometerUpdateInterval = gAccelInterval;
    if (gMotion.accelerometerActive) return;
    __weak id weakAccelerometer = accelerometer;
    [gMotion startAccelerometerUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMAccelerometerData *data, NSError *error) {
        id d = gAccelDelegate;
        SEL sel = NSSelectorFromString(@"accelerometer:didAccelerate:");
        if (!data || ![d respondsToSelector:sel]) return;
        XSAcceleration *a = [XSAcceleration new];
        double x = data.acceleration.x, y = data.acceleration.y;
        XSAccelAxes(&x, &y);
        a.x = x; a.y = y; a.z = data.acceleration.z;
        a.timestamp = data.timestamp;
        NSInteger every = MAX(1, (NSInteger)lround(1 / MAX(gAccelInterval, 0.01)));
        if (gAccelLogged < 20 * every && gAccelLogged++ % every == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            long o = (long)gScene.interfaceOrientation;
#pragma clang diagnostic pop
            XSLOG("accelerometer x %.2f y %.2f z %.2f (orientation %ld)", a.x, a.y, a.z, o);
        }
        ((void (*)(id, SEL, id, id))objc_msgSend)(d, sel, weakAccelerometer, a);
    }];
    XSLOG("accelerometer: CoreMotion every %.3f s", gAccelInterval);
}

static IMP oAccelSetDelegate, oAccelSetInterval;
static void h_accelSetDelegate(id self, SEL _cmd, id delegate) {
    ((void (*)(id, SEL, id))oAccelSetDelegate)(self, _cmd, delegate);
    gAccelDelegate = delegate;
    @try {
        if (delegate) XSAccelStart(self);
        else if (gMotion.accelerometerActive) { [gMotion stopAccelerometerUpdates]; XSLOG("accelerometer: stopped"); }
    } @catch (NSException *e) {
        XSLOG("accelerometer failed: %{public}@", e.reason);
    }
}
static void h_accelSetInterval(id self, SEL _cmd, NSTimeInterval interval) {
    ((void (*)(id, SEL, NSTimeInterval))oAccelSetInterval)(self, _cmd, interval);
    if (interval > 0) gAccelInterval = MAX(interval, 0.01);
    if (gMotion) gMotion.accelerometerUpdateInterval = gAccelInterval;
}

// The scene's screen, kept for the threads other than the main one: UIWindowScene.screen is read
// on the main thread only (written in XSNoteSceneScreen, read under the lock).
static os_unfair_lock gScreenLock = OS_UNFAIR_LOCK_INIT;
static UIScreen *gSceneScreen;

static UIScreen *XSNoteSceneScreen(void) {
    UIScreen *screen = gScene.screen;
    os_unfair_lock_lock(&gScreenLock);
    gSceneScreen = screen;
    os_unfair_lock_unlock(&gScreenLock);
    return screen;
}

// The scene's screen, once there is one: on the main thread read from the scene as it is now,
// elsewhere the last one seen there (mega review D6).
static UIScreen *h_mainScreen(id self, SEL _cmd) {
    UIScreen *real = ((id (*)(id, SEL))oMainScreen)(self, _cmd);
    UIScreen *scene;
    if (NSThread.isMainThread) {
        scene = XSNoteSceneScreen();
    } else {
        os_unfair_lock_lock(&gScreenLock);
        scene = gSceneScreen;
        os_unfair_lock_unlock(&gScreenLock);
    }
    return scene ?: real;
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

#pragma mark - UIAlertView, which iOS 27 also turns off for its SDK

// UIAlertView throws on init for an app built with SDK 27 ("no longer available"; Boost 2's
// calibrate button). Its methods are replaced by a stand-in that keeps the same API and delegate
// calls and shows a UIAlertController on the scene: title, message, buttons in order (the cancel
// one with the cancel style), text fields for the input styles.
@interface XSAlertState : NSObject
@property (nonatomic, copy) NSString *title, *message;
@property (nonatomic, weak) id delegate;
@property (nonatomic, strong) NSMutableArray<NSString *> *buttons;
@property (nonatomic) NSInteger cancelIndex;
@property (nonatomic) NSInteger style;            // UIAlertViewStyle
@property (nonatomic, strong) NSMutableArray<UITextField *> *fields;
@property (nonatomic, strong) UIAlertController *shown;
@end
@implementation XSAlertState
@end

static const void *XSAlertKey = &XSAlertKey;
static NSMutableSet *gAlertsShown;                // kept alive while on screen, like UIAlertView did

static XSAlertState *XSAlert(id self) {
    XSAlertState *s = objc_getAssociatedObject(self, XSAlertKey);
    if (!s) {
        s = [XSAlertState new];
        s.buttons = [NSMutableArray array];
        s.fields = [NSMutableArray array];
        s.cancelIndex = -1;
        objc_setAssociatedObject(self, XSAlertKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

static void XSAlertTell(id alert, NSString *selName, NSInteger index, BOOL withIndex) {
    id d = XSAlert(alert).delegate;
    SEL sel = NSSelectorFromString(selName);
    if (![d respondsToSelector:sel]) return;
    if (withIndex) ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(d, sel, alert, index);
    else ((void (*)(id, SEL, id))objc_msgSend)(d, sel, alert);
}

static id h_alertInitWithFrame(id self, SEL _cmd, CGRect frame) {
    IMP viewInit = class_getMethodImplementation(UIView.class, @selector(initWithFrame:));
    self = ((id (*)(id, SEL, CGRect))viewInit)(self, _cmd, frame);
    if (self) XSAlert(self);
    return self;
}
static id h_alertInit(id self, SEL _cmd) { return h_alertInitWithFrame(self, @selector(initWithFrame:), CGRectZero); }

static NSInteger h_alertAddButton(id self, SEL _cmd, NSString *title) {
    XSAlertState *s = XSAlert(self);
    [s.buttons addObject:title ?: @""];
    return (NSInteger)s.buttons.count - 1;
}

// Declared variadic like UIAlertView's: callers pass otherButtonTitles... as variadic arguments.
static id h_alertInitWithTitle(id self, SEL _cmd, NSString *title, NSString *message, id delegate, NSString *cancel, NSString *other, ...) {
    self = h_alertInitWithFrame(self, @selector(initWithFrame:), CGRectZero);
    if (!self) return nil;
    XSAlertState *s = XSAlert(self);
    s.title = title; s.message = message; s.delegate = delegate;
    if (cancel) s.cancelIndex = h_alertAddButton(self, NULL, cancel);
    if (other) {
        h_alertAddButton(self, NULL, other);
        va_list ap;
        va_start(ap, other);
        NSString *more;
        while ((more = va_arg(ap, NSString *))) h_alertAddButton(self, NULL, more);
        va_end(ap);
    }
    return self;
}

static NSString *h_alertTitle(id self, SEL _cmd) { return XSAlert(self).title; }
static void h_alertSetTitle(id self, SEL _cmd, NSString *v) { XSAlert(self).title = v; }
static NSString *h_alertMessage(id self, SEL _cmd) { return XSAlert(self).message; }
static void h_alertSetMessage(id self, SEL _cmd, NSString *v) { XSAlert(self).message = v; }
static id h_alertDelegate(id self, SEL _cmd) { return XSAlert(self).delegate; }
static void h_alertSetDelegate(id self, SEL _cmd, id v) { XSAlert(self).delegate = v; }
static NSInteger h_alertNumberOfButtons(id self, SEL _cmd) { return (NSInteger)XSAlert(self).buttons.count; }
static NSString *h_alertButtonTitle(id self, SEL _cmd, NSInteger i) {
    NSArray *b = XSAlert(self).buttons;
    return i >= 0 && i < (NSInteger)b.count ? b[i] : nil;
}
static NSInteger h_alertCancelIndex(id self, SEL _cmd) { return XSAlert(self).cancelIndex; }
static void h_alertSetCancelIndex(id self, SEL _cmd, NSInteger i) { XSAlert(self).cancelIndex = i; }
static NSInteger h_alertFirstOther(id self, SEL _cmd) {
    XSAlertState *s = XSAlert(self);
    for (NSInteger i = 0; i < (NSInteger)s.buttons.count; i++) if (i != s.cancelIndex) return i;
    return -1;
}
static BOOL h_alertVisible(id self, SEL _cmd) { return XSAlert(self).shown != nil; }
static NSInteger h_alertStyle(id self, SEL _cmd) { return XSAlert(self).style; }
static void h_alertSetStyle(id self, SEL _cmd, NSInteger style) {
    XSAlertState *s = XSAlert(self);
    s.style = style;
    [s.fields removeAllObjects];
    NSInteger count = style == 3 ? 2 : (style == 1 || style == 2) ? 1 : 0;   // login+password / secure / plain
    for (NSInteger i = 0; i < count; i++) {
        UITextField *f = [UITextField new];
        f.secureTextEntry = style == 1 || (style == 3 && i == 1);
        [s.fields addObject:f];
    }
}
static UITextField *h_alertTextField(id self, SEL _cmd, NSInteger i) {
    NSArray *f = XSAlert(self).fields;
    UIAlertController *shown = XSAlert(self).shown;
    if (shown && i >= 0 && i < (NSInteger)shown.textFields.count) return shown.textFields[i];
    if (i >= 0 && i < (NSInteger)f.count) return f[i];
    [NSException raise:NSRangeException format:@"textFieldAtIndex:%ld is outside the alert's text fields", (long)i];
    return nil;
}

static void XSAlertFinish(id alert, NSInteger index) {
    XSAlertTell(alert, @"alertView:willDismissWithButtonIndex:", index, YES);
    XSAlert(alert).shown = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        XSAlertTell(alert, @"alertView:didDismissWithButtonIndex:", index, YES);
        [gAlertsShown removeObject:alert];
    });
}

static UIViewController *XSTopController(void) {
    UIWindowScene *scene = gScene;
    UIWindow *win = nil;
    for (UIWindow *w in scene.windows) if (w.isKeyWindow) { win = w; break; }
    if (!win) win = scene.windows.firstObject;
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    return vc;
}

static void h_alertShow(id self, SEL _cmd) {
    XSAlertState *s = XSAlert(self);
    if (s.shown) return;
    UIViewController *top = XSTopController();
    if (!top) { XSLOG("alert: nowhere to show it"); return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:s.title message:s.message preferredStyle:UIAlertControllerStyleAlert];
    for (UITextField *model in s.fields) {
        [ac addTextFieldWithConfigurationHandler:^(UITextField *f) {
            f.text = model.text;
            f.placeholder = model.placeholder;
            f.secureTextEntry = model.secureTextEntry;
            f.keyboardType = model.keyboardType;
            f.autocapitalizationType = model.autocapitalizationType;
            f.autocorrectionType = model.autocorrectionType;
        }];
    }
    __weak id weakSelf = self;
    [s.buttons enumerateObjectsUsingBlock:^(NSString *title, NSUInteger i, BOOL *stop) {
        UIAlertActionStyle style = (NSInteger)i == s.cancelIndex ? UIAlertActionStyleCancel : UIAlertActionStyleDefault;
        [ac addAction:[UIAlertAction actionWithTitle:title style:style handler:^(UIAlertAction *a) {
            id alert = weakSelf;
            if (!alert) return;
            XSAlertTell(alert, @"alertView:clickedButtonAtIndex:", (NSInteger)i, YES);
            XSAlertFinish(alert, (NSInteger)i);
        }]];
    }];
    if (s.buttons.count == 0) XSLOG("alert: shown without buttons");
    if (!gAlertsShown) gAlertsShown = [NSMutableSet set];
    [gAlertsShown addObject:self];
    s.shown = ac;
    XSAlertTell(self, @"willPresentAlertView:", 0, NO);
    [top presentViewController:ac animated:YES completion:^{
        id alert = weakSelf;
        if (alert) XSAlertTell(alert, @"didPresentAlertView:", 0, NO);
    }];
    XSLOG("alert shown (UIAlertView stand-in, %lu buttons)", (unsigned long)s.buttons.count);
}

static void h_alertDismiss(id self, SEL _cmd, NSInteger index, BOOL animated) {
    UIAlertController *ac = XSAlert(self).shown;
    if (!ac) return;
    XSAlertFinish(self, index);
    [ac.presentingViewController dismissViewControllerAnimated:animated completion:nil];
}

static void XSAlertViewInstall(Class c) {
    struct { const char *sel; IMP imp; const char *types; } m[] = {
        {"init", (IMP)h_alertInit, "@@:"},
        {"initWithFrame:", (IMP)h_alertInitWithFrame, "@@:{CGRect={CGPoint=dd}{CGSize=dd}}"},
        {"initWithTitle:message:delegate:cancelButtonTitle:otherButtonTitles:", (IMP)h_alertInitWithTitle, "@@:@@@@@"},
        {"title", (IMP)h_alertTitle, "@@:"}, {"setTitle:", (IMP)h_alertSetTitle, "v@:@"},
        {"message", (IMP)h_alertMessage, "@@:"}, {"setMessage:", (IMP)h_alertSetMessage, "v@:@"},
        {"delegate", (IMP)h_alertDelegate, "@@:"}, {"setDelegate:", (IMP)h_alertSetDelegate, "v@:@"},
        {"addButtonWithTitle:", (IMP)h_alertAddButton, "q@:@"},
        {"numberOfButtons", (IMP)h_alertNumberOfButtons, "q@:"},
        {"buttonTitleAtIndex:", (IMP)h_alertButtonTitle, "@@:q"},
        {"cancelButtonIndex", (IMP)h_alertCancelIndex, "q@:"}, {"setCancelButtonIndex:", (IMP)h_alertSetCancelIndex, "v@:q"},
        {"firstOtherButtonIndex", (IMP)h_alertFirstOther, "q@:"},
        {"isVisible", (IMP)h_alertVisible, "B@:"}, {"visible", (IMP)h_alertVisible, "B@:"},
        {"alertViewStyle", (IMP)h_alertStyle, "q@:"}, {"setAlertViewStyle:", (IMP)h_alertSetStyle, "v@:q"},
        {"textFieldAtIndex:", (IMP)h_alertTextField, "@@:q"},
        {"show", (IMP)h_alertShow, "v@:"},
        {"dismissWithClickedButtonIndex:animated:", (IMP)h_alertDismiss, "v@:qB"},
    };
    for (size_t i = 0; i < sizeof m / sizeof m[0]; i++) class_replaceMethod(c, sel_registerName(m[i].sel), m[i].imp, m[i].types);
    XSLOG("UIAlertView: stand-in installed");
}

#pragma mark - UIActionSheet, turned off with UIAlertView

// The same way as UIAlertView: UIActionSheet's methods are replaced by a stand-in with the same
// API and delegate calls that shows a UIAlertController with the action-sheet style on the scene:
// title, buttons in index order (cancel and destructive with their styles). On a wide screen
// (iPad, the Duo's inner screen) iOS shows it as a popover, pointed where the show call says.
// The index bookkeeping is XSActionSheetCore.m (tested on the Mac).
@interface XSSheetState : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, weak) id delegate;
@property (nonatomic) NSInteger style;            // UIActionSheetStyle: kept, not shown
@property (nonatomic, strong) XSSheetButtons *buttons;
@property (nonatomic, strong) UIAlertController *shown;
@property (nonatomic, strong) id popoverDelegate; // the popover holds its delegate weakly
@end
@implementation XSSheetState
@end

static const void *XSSheetKey = &XSSheetKey;
static NSMutableSet *gSheetsShown;                // kept alive while on screen, like UIActionSheet did

static XSSheetState *XSSheet(id self) {
    XSSheetState *s = objc_getAssociatedObject(self, XSSheetKey);
    if (!s) {
        s = [XSSheetState new];
        s.buttons = [XSSheetButtons new];
        objc_setAssociatedObject(self, XSSheetKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

static void XSSheetTell(id sheet, NSString *selName, NSInteger index, BOOL withIndex) {
    id d = XSSheet(sheet).delegate;
    SEL sel = NSSelectorFromString(selName);
    if (![d respondsToSelector:sel]) return;
    if (withIndex) ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(d, sel, sheet, index);
    else ((void (*)(id, SEL, id))objc_msgSend)(d, sel, sheet);
}

// Once per showing, whatever ends it (a button, the app's dismiss call, a tap outside the popover).
static void XSSheetFinish(id sheet, NSInteger index) {
    XSSheetState *s = XSSheet(sheet);
    if (![s.buttons finish]) return;
    XSSheetTell(sheet, @"actionSheet:willDismissWithButtonIndex:", index, YES);
    s.shown = nil;
    s.popoverDelegate = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        XSSheetTell(sheet, @"actionSheet:didDismissWithButtonIndex:", index, YES);
        [gSheetsShown removeObject:sheet];
    });
}

// The popover went away without a button (a tap outside it): UIActionSheet told
// actionSheetCancel: when the delegate has it, and otherwise acted as a click on the cancel button.
@interface XSSheetPopoverDelegate : NSObject <UIPopoverPresentationControllerDelegate>
@property (nonatomic, weak) id sheet;
@end
@implementation XSSheetPopoverDelegate
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    id sheet = self.sheet;
    if (!sheet || !XSSheet(sheet).buttons.showing) return;
    NSInteger cancel = XSSheet(sheet).buttons.cancelIndex;
    if ([XSSheet(sheet).delegate respondsToSelector:@selector(actionSheetCancel:)]) XSSheetTell(sheet, @"actionSheetCancel:", 0, NO);
    else XSSheetTell(sheet, @"actionSheet:clickedButtonAtIndex:", cancel, YES);
    XSSheetFinish(sheet, cancel);
}
@end

static id h_sheetInitWithFrame(id self, SEL _cmd, CGRect frame) {
    IMP viewInit = class_getMethodImplementation(UIView.class, @selector(initWithFrame:));
    self = ((id (*)(id, SEL, CGRect))viewInit)(self, @selector(initWithFrame:), frame);
    if (self) XSSheet(self);
    return self;
}
static id h_sheetInit(id self, SEL _cmd) { return h_sheetInitWithFrame(self, @selector(initWithFrame:), CGRectZero); }

// Declared variadic like UIActionSheet's: callers pass otherButtonTitles... as variadic arguments.
static id h_sheetInitWithTitle(id self, SEL _cmd, NSString *title, id delegate, NSString *cancel, NSString *destructive,
                               NSString *other, ...) {
    self = h_sheetInitWithFrame(self, @selector(initWithFrame:), CGRectZero);
    if (!self) return nil;
    XSSheetState *s = XSSheet(self);
    s.title = title; s.delegate = delegate;
    NSMutableArray<NSString *> *others = [NSMutableArray array];
    if (other) {
        [others addObject:other];
        va_list ap;
        va_start(ap, other);
        NSString *more;
        while ((more = va_arg(ap, NSString *))) [others addObject:more];
        va_end(ap);
    }
    [s.buttons setUpWithCancel:cancel destructive:destructive others:others];
    return self;
}

static NSString *h_sheetTitle(id self, SEL _cmd) { return XSSheet(self).title; }
static void h_sheetSetTitle(id self, SEL _cmd, NSString *v) { XSSheet(self).title = v; }
static id h_sheetDelegate(id self, SEL _cmd) { return XSSheet(self).delegate; }
static void h_sheetSetDelegate(id self, SEL _cmd, id v) { XSSheet(self).delegate = v; }
static NSInteger h_sheetStyle(id self, SEL _cmd) { return XSSheet(self).style; }
static void h_sheetSetStyle(id self, SEL _cmd, NSInteger v) { XSSheet(self).style = v; }
static NSInteger h_sheetAddButton(id self, SEL _cmd, NSString *title) { return [XSSheet(self).buttons add:title]; }
static NSInteger h_sheetNumberOfButtons(id self, SEL _cmd) { return XSSheet(self).buttons.count; }
static NSString *h_sheetButtonTitle(id self, SEL _cmd, NSInteger i) { return [XSSheet(self).buttons titleAt:i]; }
static NSInteger h_sheetCancelIndex(id self, SEL _cmd) { return XSSheet(self).buttons.cancelIndex; }
static void h_sheetSetCancelIndex(id self, SEL _cmd, NSInteger i) { XSSheet(self).buttons.cancelIndex = i; }
static NSInteger h_sheetDestructiveIndex(id self, SEL _cmd) { return XSSheet(self).buttons.destructiveIndex; }
static void h_sheetSetDestructiveIndex(id self, SEL _cmd, NSInteger i) { XSSheet(self).buttons.destructiveIndex = i; }
static NSInteger h_sheetFirstOther(id self, SEL _cmd) { return XSSheet(self).buttons.firstOtherIndex; }
static BOOL h_sheetVisible(id self, SEL _cmd) { return XSSheet(self).shown != nil; }

static UIViewController *XSTopControllerOf(UIWindow *win) {
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    return vc;
}

// `view`: where the show call put it (nil: the scene's key window); `item`: showFromBarButtonItem:.
static void XSSheetPresent(id self, XSSheetShow how, UIView *view, CGRect rect, UIBarButtonItem *item) {
    XSSheetState *s = XSSheet(self);
    if (s.shown) return;
    UIViewController *top = (view.window ? XSTopControllerOf(view.window) : nil) ?: XSTopController();
    if (!top) { XSLOG("action sheet: nowhere to show it"); return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:s.title.length ? s.title : nil message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    __weak id weakSelf = self;
    XSSheetButtons *buttons = s.buttons;
    [buttons.titles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger i, BOOL *stop) {
        XSSheetButtonKind kind = [buttons kindAt:(NSInteger)i];
        UIAlertActionStyle style = kind == XSSheetButtonCancel ? UIAlertActionStyleCancel
            : kind == XSSheetButtonDestructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault;
        [ac addAction:[UIAlertAction actionWithTitle:title style:style handler:^(UIAlertAction *a) {
            id sheet = weakSelf;
            if (!sheet || !XSSheet(sheet).buttons.showing) return;
            XSSheetTell(sheet, @"actionSheet:clickedButtonAtIndex:", (NSInteger)i, YES);
            XSSheetFinish(sheet, (NSInteger)i);
        }]];
    }];
    UIPopoverPresentationController *pop = ac.popoverPresentationController;
    if (pop) {
        if (item) {
            pop.barButtonItem = item;
        } else {
            UIView *source = view ?: top.view;
            BOOL arrows = YES;
            pop.sourceView = source;
            pop.sourceRect = XSSheetSourceRect(how, source.bounds, rect, &arrows);
            pop.permittedArrowDirections = arrows ? UIPopoverArrowDirectionAny : 0;
        }
        XSSheetPopoverDelegate *pd = [XSSheetPopoverDelegate new];
        pd.sheet = self;
        s.popoverDelegate = pd;
        pop.delegate = pd;
    }
    if (buttons.count == 0) XSLOG("action sheet: shown without buttons");
    if (!gSheetsShown) gSheetsShown = [NSMutableSet set];
    [gSheetsShown addObject:self];
    s.shown = ac;
    [buttons didShow];
    XSSheetTell(self, @"willPresentActionSheet:", 0, NO);
    [top presentViewController:ac animated:YES completion:^{
        id sheet = weakSelf;
        if (sheet) XSSheetTell(sheet, @"didPresentActionSheet:", 0, NO);
    }];
    XSLOG("action sheet shown (UIActionSheet stand-in, %ld buttons, %{public}s)", (long)buttons.count,
          item ? "bar button" : how == XSSheetShowFromRect ? "rect" : how == XSSheetShowFromBar ? "bar" : "view");
}

static void h_sheetShowInView(id self, SEL _cmd, UIView *view) { XSSheetPresent(self, XSSheetShowInView, view, CGRectZero, nil); }
static void h_sheetShowFromRect(id self, SEL _cmd, CGRect rect, UIView *view, BOOL animated) {
    XSSheetPresent(self, XSSheetShowFromRect, view, rect, nil);
}
static void h_sheetShowFromItem(id self, SEL _cmd, UIBarButtonItem *item, BOOL animated) {
    XSSheetPresent(self, XSSheetShowInView, nil, CGRectZero, [item isKindOfClass:UIBarButtonItem.class] ? item : nil);
}
static void h_sheetShowFromBar(id self, SEL _cmd, UIView *bar) { XSSheetPresent(self, XSSheetShowFromBar, bar, CGRectZero, nil); }

static void h_sheetDismiss(id self, SEL _cmd, NSInteger index, BOOL animated) {
    UIAlertController *ac = XSSheet(self).shown;
    if (!ac) return;
    XSSheetFinish(self, index);
    [ac.presentingViewController dismissViewControllerAnimated:animated completion:nil];
}

static void XSActionSheetInstall(Class c) {
    struct { const char *sel; IMP imp; const char *types; } m[] = {
        {"init", (IMP)h_sheetInit, "@@:"},
        {"initWithFrame:", (IMP)h_sheetInitWithFrame, "@@:{CGRect={CGPoint=dd}{CGSize=dd}}"},
        {"initWithTitle:delegate:cancelButtonTitle:destructiveButtonTitle:otherButtonTitles:", (IMP)h_sheetInitWithTitle, "@@:@@@@@"},
        {"title", (IMP)h_sheetTitle, "@@:"}, {"setTitle:", (IMP)h_sheetSetTitle, "v@:@"},
        {"delegate", (IMP)h_sheetDelegate, "@@:"}, {"setDelegate:", (IMP)h_sheetSetDelegate, "v@:@"},
        {"actionSheetStyle", (IMP)h_sheetStyle, "q@:"}, {"setActionSheetStyle:", (IMP)h_sheetSetStyle, "v@:q"},
        {"addButtonWithTitle:", (IMP)h_sheetAddButton, "q@:@"},
        {"numberOfButtons", (IMP)h_sheetNumberOfButtons, "q@:"},
        {"buttonTitleAtIndex:", (IMP)h_sheetButtonTitle, "@@:q"},
        {"cancelButtonIndex", (IMP)h_sheetCancelIndex, "q@:"}, {"setCancelButtonIndex:", (IMP)h_sheetSetCancelIndex, "v@:q"},
        {"destructiveButtonIndex", (IMP)h_sheetDestructiveIndex, "q@:"},
        {"setDestructiveButtonIndex:", (IMP)h_sheetSetDestructiveIndex, "v@:q"},
        {"firstOtherButtonIndex", (IMP)h_sheetFirstOther, "q@:"},
        {"isVisible", (IMP)h_sheetVisible, "B@:"}, {"visible", (IMP)h_sheetVisible, "B@:"},
        {"showInView:", (IMP)h_sheetShowInView, "v@:@"},
        {"showFromRect:inView:animated:", (IMP)h_sheetShowFromRect, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}@B"},
        {"showFromBarButtonItem:animated:", (IMP)h_sheetShowFromItem, "v@:@B"},
        {"showFromTabBar:", (IMP)h_sheetShowFromBar, "v@:@"},
        {"showFromToolbar:", (IMP)h_sheetShowFromBar, "v@:@"},
        {"dismissWithClickedButtonIndex:animated:", (IMP)h_sheetDismiss, "v@:qB"},
    };
    for (size_t i = 0; i < sizeof m / sizeof m[0]; i++) class_replaceMethod(c, sel_registerName(m[i].sel), m[i].imp, m[i].types);
    XSLOG("UIActionSheet: stand-in installed");
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

#pragma mark - didFinishLaunching, deferred to the scene connection

static const NSTimeInterval XSLaunchDeferLimit = 3;
static BOOL gLaunchDeferred, gLaunchRan;
static NSDictionary *gLaunchOptions;
static IMP oDidFinishWithOptions, oDidFinish;

static void XSLogGeometry(const char *when) {
    UIWindowScene *s = gScene;
    XSLOG("%{public}s: screen %{public}@, scene %{public}@", when, NSStringFromCGRect(UIScreen.mainScreen.bounds),
          s ? NSStringFromCGRect(s.coordinateSpace.bounds) : @"none");
}

// The notification callbacks UIKit made while the launch waited for the scene (re-review N1).
static XSLaunchHold *gHeldCalls;

// Runs the app's launch method it skipped, once. Its held notification callbacks come after
// (XSReplayHeldCalls): at once here, after the window is adopted on scene connect.
static void XSRunDeferredLaunchOnly(const char *why) {
    if (!gLaunchDeferred || gLaunchRan) return;
    gLaunchRan = YES;
    XSLogGeometry(why);
    id d = XSAppDelegate();
    UIApplication *app = UIApplication.sharedApplication;
    if (oDidFinishWithOptions) ((BOOL (*)(id, SEL, id, id))oDidFinishWithOptions)(d, @selector(application:didFinishLaunchingWithOptions:), app, gLaunchOptions);
    else if (oDidFinish) ((void (*)(id, SEL, id))oDidFinish)(d, @selector(applicationDidFinishLaunching:), app);
    gLaunchOptions = nil;
}

// The notification callbacks held for the launch, in the order UIKit made them, once it ran.
static void XSReplayHeldCalls(void) {
    if (!gLaunchRan || !gHeldCalls) return;
    XSLaunchHold *held = gHeldCalls;
    gHeldCalls = nil;
    if (held.count) XSLOG("replaying %lu notification callback(s) held for the launch", (unsigned long)held.count);
    [held replay];
}

static void XSRunDeferredLaunch(const char *why) {
    XSRunDeferredLaunchOnly(why);
    XSReplayHeldCalls();
}

// A notification callback while the launch still waits for its scene: the person may have tapped
// the notification to open the app, and the app's handler (and its launch, if it ran now) would
// lay out at the size iOS reports before the scene. Held for after the launch; NO when it runs now.
static BOOL XSHoldForLaunch(SEL sel, dispatch_block_t call) {
    if (!gLaunchDeferred || gLaunchRan || !XSLaunchHoldWaits(sel_getName(sel))) return NO;
    if (!gHeldCalls) gHeldCalls = [XSLaunchHold new];
    if (![gHeldCalls hold:call]) return NO;
    XSLOG("%{public}s held until the deferred launch", sel_getName(sel));
    return YES;
}

// Launch options only a background launch carries (location, Bluetooth restoration): no scene is
// coming, the app's launch runs at once (mega review D2). A remote notification can also be a tap
// that opens the app: still deferred, its callback held for after the launch
// (XSWrapBackgroundEntries).
static BOOL XSIsBackgroundLaunch(NSDictionary *options) {
    if (![options isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[UIApplicationLaunchOptionsLocationKey, UIApplicationLaunchOptionsBluetoothCentralsKey,
                            UIApplicationLaunchOptionsBluetoothPeripheralsKey])
        if (options[key]) return YES;
    return NO;
}

// No scene yet: wait for it. The app state can't tell a background launch apart here (without a
// connected scene it reads as background either way), so a launch with no scene coming runs after
// XSLaunchDeferLimit seconds instead, or as soon as UIKit calls one of its background entry points.
static BOOL XSShouldDefer(UIApplication *app) {
    return gActive && !gScene && !gLaunchRan;
}
static BOOL h_didFinishWithOptions(id self, SEL _cmd, UIApplication *app, NSDictionary *options) {
    if (XSShouldDefer(app) && XSIsBackgroundLaunch(options)) XSLOG("background launch: didFinishLaunching not deferred");
    if (!XSShouldDefer(app) || XSIsBackgroundLaunch(options)) { gLaunchRan = YES; return ((BOOL (*)(id, SEL, id, id))oDidFinishWithOptions)(self, _cmd, app, options); }
    gLaunchDeferred = YES;
    gLaunchOptions = options;
    XSLogGeometry("didFinishLaunching deferred");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(XSLaunchDeferLimit * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XSRunDeferredLaunch("no scene in time: didFinishLaunching now");
    });
    return YES;
}
static void h_didFinish(id self, SEL _cmd, UIApplication *app) {
    if (!XSShouldDefer(app)) { gLaunchRan = YES; ((void (*)(id, SEL, id))oDidFinish)(self, _cmd, app); return; }
    gLaunchDeferred = YES;
    XSLogGeometry("applicationDidFinishLaunching deferred");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(XSLaunchDeferLimit * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XSRunDeferredLaunch("no scene in time: applicationDidFinishLaunching now");
    });
}

// The app delegate's entry points UIKit calls in the background, maybe before the scene (a silent
// push, a background fetch, a URL session's events, the push token): the deferred launch runs
// first, so the app is set up as it expects (mega review D2). A notification (remote or local)
// may instead be the tap that opens the app, its scene coming: held, with its arguments and
// completion handler, and replayed once the launch ran, on scene connect or at the
// XSLaunchDeferLimit fallback (re-review N1). All take objects and return nothing.
static void XSWrapBackgroundEntries(Class c) {
    const char *sels[] = {
        "application:didReceiveRemoteNotification:fetchCompletionHandler:",
        "application:didReceiveRemoteNotification:",
        "application:performFetchWithCompletionHandler:",
        "application:handleEventsForBackgroundURLSession:completionHandler:",
        "application:didRegisterForRemoteNotificationsWithDeviceToken:",
        "application:didFailToRegisterForRemoteNotificationsWithError:",
        "application:didReceiveLocalNotification:",
    };
    for (size_t i = 0; i < sizeof sels / sizeof sels[0]; i++) {
        SEL sel = sel_registerName(sels[i]);
        Method m = class_getInstanceMethod(c, sel);
        if (!m) continue;
        const char *types = method_getTypeEncoding(m);
        if (!types || types[0] != 'v') continue;   // not the shape expected: left alone
        IMP orig = method_getImplementation(m);
        NSUInteger args = method_getNumberOfArguments(m);   // self, _cmd and the objects
        IMP wrap = nil;
        if (args == 3) {
            wrap = imp_implementationWithBlock(^(id me, id a) {
                id ka = XSLaunchHoldKeep(a);
                if (XSHoldForLaunch(sel, ^{ ((void (*)(id, SEL, id))orig)(me, sel, ka); })) return;
                XSRunDeferredLaunch("background callback: didFinishLaunching now");
                ((void (*)(id, SEL, id))orig)(me, sel, a);
            });
        } else if (args == 4) {
            wrap = imp_implementationWithBlock(^(id me, id a, id b) {
                id ka = XSLaunchHoldKeep(a), kb = XSLaunchHoldKeep(b);
                if (XSHoldForLaunch(sel, ^{ ((void (*)(id, SEL, id, id))orig)(me, sel, ka, kb); })) return;
                XSRunDeferredLaunch("background callback: didFinishLaunching now");
                ((void (*)(id, SEL, id, id))orig)(me, sel, a, b);
            });
        } else if (args == 5) {
            wrap = imp_implementationWithBlock(^(id me, id a, id b, id c3) {
                id ka = XSLaunchHoldKeep(a), kb = XSLaunchHoldKeep(b), kc = XSLaunchHoldKeep(c3);
                if (XSHoldForLaunch(sel, ^{ ((void (*)(id, SEL, id, id, id))orig)(me, sel, ka, kb, kc); })) return;
                XSRunDeferredLaunch("background callback: didFinishLaunching now");
                ((void (*)(id, SEL, id, id, id))orig)(me, sel, a, b, c3);
            });
        }
        if (!wrap) continue;
        if (!class_addMethod(c, sel, wrap, types)) method_setImplementation(m, wrap);
    }
}

// The app delegate is set in UIApplicationMain, before UIKit calls its launch methods: wrap them then.
static IMP oSetDelegate;
static void h_setDelegate(UIApplication *self, SEL _cmd, id delegate) {
    static BOOL wrapped;
    if (gActive && delegate && !wrapped) {
        wrapped = YES;
        @try {
            Class c = object_getClass(delegate);
            SEL withOptions = @selector(application:didFinishLaunchingWithOptions:);
            if (class_getInstanceMethod(c, withOptions)) XSHook(c, withOptions, (IMP)h_didFinishWithOptions, &oDidFinishWithOptions);
            else if (class_getInstanceMethod(c, @selector(applicationDidFinishLaunching:)))
                XSHook(c, @selector(applicationDidFinishLaunching:), (IMP)h_didFinish, &oDidFinish);
            XSWrapBackgroundEntries(c);
            XSLOG("launch deferred to the scene for %{public}s", class_getName(c));
        } @catch (NSException *e) {
            XSLOG("launch wrap failed: %{public}@", e.reason);
        }
    }
    ((void (*)(id, SEL, id))oSetDelegate)(self, _cmd, delegate);
}

#pragma mark - Scene delegate

@interface XSDuoSceneDelegate : UIResponder <UIWindowSceneDelegate>
@end

@implementation XSDuoSceneDelegate {
    UIWindow *_window;
    BOOL _connected;
}

- (UIWindow *)window { return _window ?: XSMainWindow(); }

// A storyboard app (the manifest names its UIMainStoryboardFile as the scene's): iOS loads the
// storyboard into a window it gives the scene delegate, where the app delegate had it without
// scenes. Handed over to the app delegate when it has none yet, before its deferred launch reads it.
- (void)setWindow:(UIWindow *)window {
    _window = window;
    if (!gActive || !window) return;
    @try {
        id<UIApplicationDelegate> d = XSAppDelegate();
        if ([d respondsToSelector:@selector(setWindow:)] && !XSMainWindow()) {
            d.window = window;
            XSLOG("storyboard window handed to the app delegate");
        }
    } @catch (NSException *e) {
        XSLOG("window handover failed: %{public}@", e.reason);
    }
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)opts {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    UIWindowScene *ws = (UIWindowScene *)scene;
    gScene = ws;
    XSNoteSceneScreen();
    // The storyboard window iOS gave us (if any) is the app delegate's before its launch runs.
    if (_window) [self setWindow:_window];
    // Outside XSide's @try: an exception from the app's own launch stays the app's, as without XSide.
    XSRunDeferredLaunchOnly("scene connected: didFinishLaunching now");
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
    // The notification tapped to open the app, held for the launch: now its window is the scene's,
    // as without scenes (UIKit called it after didFinishLaunching made the window visible). Outside
    // the @try too: the app's handler is the app's.
    XSReplayHeldCalls();

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
    XSNoteSceneScreen();
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
            XSHook(A, @selector(setDelegate:), (IMP)h_setDelegate, &oSetDelegate);
            XSHook(object_getClass(UIScreen.class), @selector(mainScreen), (IMP)h_mainScreen, &oMainScreen);
            XSHook(A, NSSelectorFromString(@"statusBarOrientation"), (IMP)h_statusBarOrientation, &oStatusBarOrientation);
            Class accel = NSClassFromString(@"UIAccelerometer");
            if (accel && NSClassFromString(@"CMMotionManager")) {
                XSHook(accel, @selector(setDelegate:), (IMP)h_accelSetDelegate, &oAccelSetDelegate);
                XSHook(accel, NSSelectorFromString(@"setUpdateInterval:"), (IMP)h_accelSetInterval, &oAccelSetInterval);
            }
            Class alertView = NSClassFromString(@"UIAlertView");
            if (alertView) XSAlertViewInstall(alertView);
            Class actionSheet = NSClassFromString(@"UIActionSheet");
            if (actionSheet) XSActionSheetInstall(actionSheet);
            gActive = YES;
            XSLOG("loaded");
        } @catch (NSException *e) {
            XSLOG("not loaded: %{public}@", e.reason);
        }
    }
}
