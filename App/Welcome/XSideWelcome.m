// XSideWelcome: loaded by apps XSide installs with "Show an XSide message when it opens".
// Once after each install or refresh (each new provisioning profile), it shows an alert saying
// the app was installed with XSide and until when it works. It never throws, asserts or blocks:
// anything missing (no profile, no window) and it silently does nothing.
//
// Built by scripts/bundle.sh for iOS arm64 and shipped in XSide.app/Contents/Resources; XSide
// copies it into the app's Frameworks/ and signs it with the app.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString *const XSAnnouncedKey = @"io.github.xside.welcome.announcedExpiry";
static NSString *const XSRepoURL = @"https://github.com/Antholife/xside";
static const int XSMaxAttempts = 10;

/// ExpirationDate of the app's own embedded.mobileprovision (a CMS blob around an XML plist).
static NSDate *XSExpirationDate(void) {
    NSString *path = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"];
    NSData *blob = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (blob.length == 0) return nil;
    NSData *open = [@"<?xml" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *close = [@"</plist>" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange start = [blob rangeOfData:open options:0 range:NSMakeRange(0, blob.length)];
    if (start.location == NSNotFound) return nil;
    NSRange rest = NSMakeRange(start.location, blob.length - start.location);
    NSRange end = [blob rangeOfData:close options:0 range:rest];
    if (end.location == NSNotFound) return nil;
    NSData *xml = [blob subdataWithRange:NSMakeRange(start.location, NSMaxRange(end) - start.location)];
    id plist = [NSPropertyListSerialization propertyListWithData:xml options:NSPropertyListImmutable
                                                          format:NULL error:NULL];
    if (![plist isKindOfClass:NSDictionary.class]) return nil;
    id date = ((NSDictionary *)plist)[@"ExpirationDate"];
    return [date isKindOfClass:NSDate.class] ? date : nil;
}

static BOOL XSFrench(void) {
    NSString *first = NSLocale.preferredLanguages.firstObject ?: @"";
    return [first.lowercaseString hasPrefix:@"fr"];
}

/// The view controller on top of the foreground scene's key window, nil while there's none.
static UIViewController *XSPresenter(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { window = w; break; }
            if (!window) window = w;
        }
        if (window) break;
    }
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    return top.viewIfLoaded.window ? top : nil;
}

static void XSShow(NSDate *expiry, int attempt) {
    UIViewController *presenter = XSPresenter();
    if (!presenter) {
        if (attempt + 1 >= XSMaxAttempts) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XSShow(expiry, attempt + 1);
        });
        return;
    }
    BOOL fr = XSFrench();
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = NSLocale.currentLocale;
    formatter.dateStyle = NSDateFormatterFullStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    NSString *when = [formatter stringFromDate:expiry];
    NSString *title = fr ? @"Installée avec XSide" : @"Installed with XSide";
    NSString *message = fr
        ? [NSString stringWithFormat:@"Valable jusqu'au %@. XSide la rafraîchit automatiquement tant qu'il tourne sur ton Mac.", when]
        : [NSString stringWithFormat:@"Valid until %@. XSide refreshes it automatically as long as it runs on your Mac.", when];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:(fr ? @"XSide sur GitHub" : @"XSide on GitHub")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:XSRepoURL];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }]];
    UIAlertAction *ok = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:ok];
    alert.preferredAction = ok;
    [presenter presentViewController:alert animated:YES completion:nil];
    // Announced once presented: a relaunch before tapping OK doesn't show it again.
    [NSUserDefaults.standardUserDefaults setObject:expiry forKey:XSAnnouncedKey];
}

__attribute__((constructor)) static void XSideWelcomeInit(void) {
    __block id observer = nil;
    observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                               object:nil queue:NSOperationQueue.mainQueue
                                                           usingBlock:^(NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        observer = nil;
        NSDate *expiry = XSExpirationDate();
        if (!expiry) return;
        id announced = [NSUserDefaults.standardUserDefaults objectForKey:XSAnnouncedKey];
        if ([announced isKindOfClass:NSDate.class] && [announced isEqualToDate:expiry]) return;
        XSShow(expiry, 0);
    }];
}
