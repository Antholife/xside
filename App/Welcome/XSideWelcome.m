// XSideWelcome: loaded by every app XSide installs. Once per signature (each new provisioning
// profile), at the first launch after it:
// - after an install (no earlier signature known to the app), a sheet saying the app was
//   installed with XSide and until when it works;
// - after a refresh, a card at the bottom with an OK button.
// At each launch it also schedules a local reminder 24 h before expiry when the app may notify.
// If the app never asked for that permission, it's asked once, when the sheet is closed. It never throws, asserts or blocks: anything
// missing (no profile, no window) and it silently does nothing.
//
// Built by scripts/bundle.sh for iOS arm64 and shipped in XSide.app/Contents/Resources; XSide
// copies it into the app's Frameworks/ and signs it with the app.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

static NSString *const XSAnnouncedKey = @"io.github.xside.welcome.announcedExpiry";
/// The app's version when it was last announced: a different one means XSide installed an update.
static NSString *const XSAnnouncedVersionKey = @"io.github.xside.welcome.announcedVersion";
static NSString *const XSRepoURL = @"https://github.com/Antholife/xside";
static NSString *const XSReminderID = @"io.github.xside.welcome.expiryReminder";
#ifdef XS_TEST_REMINDER
// Found by scripts/release.sh, which refuses to ship a test build.
__attribute__((used)) static const char XSTestBuildMarker[] = "XSIDE_TEST_REMINDER_BUILD";
#endif
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

/// The notification center of the app as installed. Some tweaked apps make NSBundle report
/// another bundle id (e.g. "com.google.ios.youtube", for Google sign-in); iOS then refuses
/// notifications to that app, which isn't installed (UNErrorDomain 1, seen 2026-11-05). The
/// real id is read from the Info.plist file itself.
/// The app's Info.plist as written by XSide, read from the file itself: tweaks may fake
/// NSBundle's copy.
static NSDictionary *XSInfo(void) {
    static NSDictionary *info;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Info.plist"];
        NSData *data = [NSData dataWithContentsOfFile:path];
        id plist = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
        info = [plist isKindOfClass:NSDictionary.class] ? plist : @{};
    });
    return info;
}

/// The on-device reminder, unless turned off in XSide's Settings (`XSideWelcome.reminder`).
static BOOL XSReminderOn(void) {
    id options = XSInfo()[@"XSideWelcome"];
    id on = [options isKindOfClass:NSDictionary.class] ? options[@"reminder"] : nil;
    return [on isKindOfClass:NSNumber.class] ? [on boolValue] : YES;
}

/// How long before expiry the reminder fires (`XSideWelcome.reminderLeadHours`), 24 h by default.
static NSTimeInterval XSReminderLead(void) {
    id options = XSInfo()[@"XSideWelcome"];
    id hours = [options isKindOfClass:NSDictionary.class] ? options[@"reminderLeadHours"] : nil;
    NSInteger h = [hours isKindOfClass:NSNumber.class] ? [hours integerValue] : 24;
    return (h > 0 && h <= 48 ? h : 24) * 3600.0;
}

/// The app's version (CFBundleShortVersionString), as installed.
static NSString *XSAppVersion(void) {
    id v = XSInfo()[@"CFBundleShortVersionString"];
    return [v isKindOfClass:NSString.class] && [v length] ? v : nil;
}

static UNUserNotificationCenter *XSCenter(void) {
    static UNUserNotificationCenter *center;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *real = XSInfo()[@"CFBundleIdentifier"];
        NSString *reported = NSBundle.mainBundle.bundleIdentifier;
        NSLog(@"[XSide] bundle id: reported %@, real %@", reported, real);
        SEL init = NSSelectorFromString(@"initWithBundleIdentifier:");
        if ([real isKindOfClass:NSString.class] && real.length && ![real isEqualToString:reported]
            && [UNUserNotificationCenter instancesRespondToSelector:init]) {
            UNUserNotificationCenter *own = [UNUserNotificationCenter alloc];
            center = ((UNUserNotificationCenter *(*)(id, SEL, NSString *))[own methodForSelector:init])(own, init, real);
        }
        if (!center) center = UNUserNotificationCenter.currentNotificationCenter;
    });
    return center;
}

static BOOL XSFrench(void) {
    NSString *first = NSLocale.preferredLanguages.firstObject ?: @"";
    return [first.lowercaseString hasPrefix:@"fr"];
}

/// The foreground scene, with a window on screen; nil while there's none.
static UIWindowScene *XSScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) if (!w.hidden && w.rootViewController) return ws;
    }
    return nil;
}

/// The sheet's (or banner's) own window, above the app's (and its alerts): the app can present,
/// dismiss or replace its screens (sign-in, onboarding) without ever covering or closing it.
static UIWindow *XSWindow;
/// The app's key window before the sheet, given back when it closes.
static __weak UIWindow *XSPreviousKey;

// MARK: - The sheet (design "B": a card rising from the bottom over the dimmed app)

#if __has_include("XSideWelcomeIcon.h")
#include "XSideWelcomeIcon.h" // XSWelcomeIcon / XSWelcomeIcon_len, generated by scripts/bundle.sh
#define XS_HAS_ICON 1
#endif

static UIColor *XSViolet(void) { return [UIColor colorWithRed:0x7B / 255.0 green:0x5C / 255.0 blue:0xFF / 255.0 alpha:1]; }
static UIColor *XSPink(void) { return [UIColor colorWithRed:0xC9 / 255.0 green:0x6F / 255.0 blue:0xAD / 255.0 alpha:1]; }

/// The primary button: XSide's violet-to-pink gradient.
@interface XSGradientButton : UIButton
@end
@implementation XSGradientButton
+ (Class)layerClass { return CAGradientLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        CAGradientLayer *g = (CAGradientLayer *)self.layer;
        g.colors = @[(id)XSViolet().CGColor, (id)XSPink().CGColor];
        g.startPoint = CGPointMake(0, 0);
        g.endPoint = CGPointMake(1, 1);
        g.cornerRadius = 14;
    }
    return self;
}
@end

static NSString *XSDate(NSDate *date) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = NSLocale.currentLocale;
    [formatter setLocalizedDateFormatFromTemplate:@"EEEdMMMjmm"];
    return [formatter stringFromDate:date];
}

static NSString *XSAppName(void) {
    // The name shown on the home screen and in Settings: the localized one first.
    NSDictionary *localized = NSBundle.mainBundle.localizedInfoDictionary;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *name = localized[@"CFBundleDisplayName"] ?: info[@"CFBundleDisplayName"] ?: localized[@"CFBundleName"] ?: info[@"CFBundleName"];
    if ([name isKindOfClass:NSString.class] && name.length) return name;
    return XSFrench() ? @"L'app" : @"The app";
}

/// XSide added its section to the app's page in the iOS Settings app (keys "io.github.xside.settings.*").
static BOOL XSHasSettingsSection(void) {
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Settings.bundle/Root.plist"];
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:path];
    id items = root[@"PreferenceSpecifiers"];
    if (![items isKindOfClass:NSArray.class]) return NO;
    for (id item in items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        id key = item[@"Key"];
        if ([key isKindOfClass:NSString.class] && [key hasPrefix:@"io.github.xside.settings."]) return YES;
    }
    return NO;
}

static UIImage *XSIcon(void) {
#ifdef XS_HAS_ICON
    return [UIImage imageWithData:[NSData dataWithBytesNoCopy:(void *)XSWelcomeIcon
                                                         length:XSWelcomeIcon_len freeWhenDone:NO]];
#else
    return nil;
#endif
}

static void XSHideWindow(void) {
    XSWindow.hidden = YES;
    XSWindow = nil;
    [XSPreviousKey makeKeyWindow];
}

static void XSScheduleReminder(NSDate *expiry, BOOL askIfNeeded);

@interface XSWelcomeController : UIViewController
- (instancetype)initWithExpiry:(NSDate *)expiry;
@end

@implementation XSWelcomeController {
    NSDate *_expiry;
    BOOL _fr;
    UIView *_dim;
    UIView *_sheet;
    BOOL _closing;
}

- (instancetype)initWithExpiry:(NSDate *)expiry {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _expiry = expiry;
        _fr = XSFrench();
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    }
    return self;
}

- (NSString *)t:(NSString *)fr en:(NSString *)en { return _fr ? fr : en; }

- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.numberOfLines = 0;
    l.adjustsFontForContentSizeCategory = YES;
    return l;
}

/// "Valable jusqu'au … | jeu. 12 nov., 14:30", with a hairline above.
- (UIView *)line:(NSString *)name value:(NSString *)value {
    UIView *row = [UIView new];
    UIView *rule = [UIView new];
    rule.backgroundColor = UIColor.separatorColor;
    UILabel *left = [self label:name size:14 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    UILabel *right = [self label:value size:14 weight:UIFontWeightSemibold color:UIColor.labelColor];
    right.textAlignment = NSTextAlignmentRight;
    [left setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    for (UIView *v in @[rule, left, right]) { v.translatesAutoresizingMaskIntoConstraints = NO; [row addSubview:v]; }
    [NSLayoutConstraint activateConstraints:@[
        [rule.topAnchor constraintEqualToAnchor:row.topAnchor],
        [rule.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [rule.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [rule.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
        [left.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [left.topAnchor constraintEqualToAnchor:row.topAnchor constant:12],
        [left.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-12],
        [right.leadingAnchor constraintGreaterThanOrEqualToAnchor:left.trailingAnchor constant:12],
        [right.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [right.firstBaselineAnchor constraintEqualToAnchor:left.firstBaselineAnchor],
    ]];
    return row;
}

- (NSString *)daysLeft {
    NSTimeInterval left = [_expiry timeIntervalSinceNow];
    if (left < 86400) return [self t:@"moins d'un jour" en:@"less than a day"];
    NSInteger days = (NSInteger)ceil(left / 86400);
    if (days == 1) return [self t:@"1 jour" en:@"1 day"];
    return [NSString stringWithFormat:[self t:@"%ld jours" en:@"%ld days"], (long)days];
}

/// "⚙️ These details stay in Settings > <App>".
- (UIView *)settingsHint {
    UIImageView *gear = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"gearshape.fill"]];
    gear.tintColor = XSViolet();
    gear.contentMode = UIViewContentModeScaleAspectFit;
    // iOS 18 moved apps' pages under Settings > Apps.
    BOOL apps = [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){18, 0, 0}];
    NSString *path = apps ? [NSString stringWithFormat:[self t:@"Réglages > Apps > %@" en:@"Settings > Apps > %@"], XSAppName()]
                          : [NSString stringWithFormat:[self t:@"Réglages > %@" en:@"Settings > %@"], XSAppName()];
    NSString *text = [NSString stringWithFormat:[self t:@"Ces infos restent dans %@" en:@"These details stay in %@"], path];
    NSMutableAttributedString *styled = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: UIColor.secondaryLabelColor}];
    [styled addAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold],
                            NSForegroundColorAttributeName: UIColor.labelColor}
                    range:[text rangeOfString:path]];
    UILabel *label = [UILabel new];
    label.attributedText = styled;
    label.numberOfLines = 0;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[gear, label]];
    row.spacing = 8;
    row.alignment = UIStackViewAlignmentCenter;
    [gear.widthAnchor constraintEqualToConstant:16].active = YES;
    [gear.heightAnchor constraintEqualToConstant:16].active = YES;
    return row;
}

/// "Get a reminder before it expires": a tinted card with a bell in the brand gradient.
- (UIView *)notificationCard {
    UIView *card = [UIView new];
    card.backgroundColor = [XSViolet() colorWithAlphaComponent:0.12];
    card.layer.cornerRadius = 16;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [XSViolet() colorWithAlphaComponent:0.25].CGColor;

    XSGradientButton *badge = [XSGradientButton buttonWithType:UIButtonTypeCustom];
    badge.userInteractionEnabled = NO;
    ((CAGradientLayer *)badge.layer).cornerRadius = 19;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    [badge setImage:[UIImage systemImageNamed:@"bell.badge.fill" withConfiguration:config] forState:UIControlStateNormal];
    badge.tintColor = UIColor.whiteColor;

    UILabel *title = [self label:[self t:@"Te prévenir avant l'expiration" en:@"Get a reminder before it expires"]
                            size:15 weight:UIFontWeightSemibold color:UIColor.labelColor];
    UILabel *body = [self label:[self t:@"En touchant OK, iOS va te demander d'autoriser les notifications. XSide s'en sert uniquement pour te prévenir la veille de l'expiration."
                                     en:@"When you tap OK, iOS will ask to allow notifications. XSide only uses them to remind you the day before it expires."]
                           size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[title, body]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 3;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[badge, texts]];
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentTop;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [badge.widthAnchor constraintEqualToConstant:38],
        [badge.heightAnchor constraintEqualToConstant:38],
        [row.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [row.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
    ]];
    return card;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    // The app behind, blurred and dimmed; a tap there closes, like OK.
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
                                [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    blur.backgroundColor = [UIColor colorWithWhite:0 alpha:0.2];
    _dim = blur;
    _dim.alpha = 0;
    [_dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];

    _sheet = [UIView new];
    _sheet.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    _sheet.layer.cornerRadius = 28;
    _sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    _sheet.layer.shadowColor = UIColor.blackColor.CGColor;
    _sheet.layer.shadowOpacity = 0.2;
    _sheet.layer.shadowRadius = 20;
    _sheet.layer.shadowOffset = CGSizeMake(0, -6);
    _sheet.accessibilityViewIsModal = YES;

    UIView *grab = [UIView new];
    grab.backgroundColor = UIColor.tertiaryLabelColor;
    grab.layer.cornerRadius = 2.5;

    UIImageView *icon = [[UIImageView alloc] initWithImage:XSIcon()];
    icon.layer.cornerRadius = 13;
    icon.layer.cornerCurve = kCACornerCurveContinuous;
    icon.clipsToBounds = YES;
    UILabel *title = [self label:[self t:@"Installée avec XSide" en:@"Installed with XSide"]
                            size:18 weight:UIFontWeightBold color:UIColor.labelColor];
    UILabel *subtitle = [self label:[self t:@"Rafraîchie automatiquement depuis ton Mac" en:@"Refreshed automatically from your Mac"]
                               size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    UIStackView *titles = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    titles.axis = UILayoutConstraintAxisVertical;
    titles.spacing = 3;
    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[icon, titles]];
    head.spacing = 14;
    head.alignment = UIStackViewAlignmentCenter;

    UIView *until = [self line:[self t:@"Valable jusqu'au" en:@"Valid until"] value:XSDate(_expiry)];
    UIView *left = [self line:[self t:@"Encore" en:@"Time left"] value:[self daysLeft]];
    // Where to find this again later.
    UIView *where = [self settingsHint];
    where.hidden = !XSHasSettingsSection();

    XSGradientButton *ok = [XSGradientButton buttonWithType:UIButtonTypeCustom];
    [ok setTitle:@"OK" forState:UIControlStateNormal];
    [ok setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    ok.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [ok addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    UIButton *github = [UIButton buttonWithType:UIButtonTypeSystem];
    [github setTitle:[self t:@"XSide sur GitHub" en:@"XSide on GitHub"] forState:UIControlStateNormal];
    github.tintColor = XSViolet();
    github.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [github addTarget:self action:@selector(openGitHub) forControlEvents:UIControlEventTouchUpInside];

    // Only when iOS will ask on OK (see `close`): its prompt can't say why, so this card does.
    UIView *notice = [self notificationCard];
    notice.hidden = YES;
    __weak UIButton *weakOK = ok;
    if (XSReminderOn()) [XSCenter() getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        if (settings.authorizationStatus != UNAuthorizationStatusNotDetermined) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            notice.hidden = NO;
            [weakOK setTitle:[self t:@"OK, autoriser les rappels" en:@"OK, allow reminders"] forState:UIControlStateNormal];
        });
    }];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[head, until, left, where, notice, ok, github]];
    stack.axis = UILayoutConstraintAxisVertical;
    [stack setCustomSpacing:16 afterView:head];
    [stack setCustomSpacing:10 afterView:left];
    [stack setCustomSpacing:12 afterView:where];
    [stack setCustomSpacing:14 afterView:notice];
    [stack setCustomSpacing:4 afterView:ok];

    for (UIView *v in @[_dim, _sheet]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:v]; }
    for (UIView *v in @[grab, stack]) { v.translatesAutoresizingMaskIntoConstraints = NO; [_sheet addSubview:v]; }
    NSLayoutConstraint *fullWidth = [_sheet.widthAnchor constraintEqualToAnchor:self.view.widthAnchor];
    fullWidth.priority = UILayoutPriorityDefaultHigh; // capped on iPad
    [NSLayoutConstraint activateConstraints:@[
        [_dim.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_dim.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_dim.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_dim.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_sheet.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_sheet.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_sheet.widthAnchor constraintLessThanOrEqualToConstant:500],
        fullWidth,
        [grab.topAnchor constraintEqualToAnchor:_sheet.topAnchor constant:10],
        [grab.centerXAnchor constraintEqualToAnchor:_sheet.centerXAnchor],
        [grab.widthAnchor constraintEqualToConstant:38],
        [grab.heightAnchor constraintEqualToConstant:5],
        [stack.topAnchor constraintEqualToAnchor:grab.bottomAnchor constant:18],
        [stack.leadingAnchor constraintEqualToAnchor:_sheet.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:_sheet.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:_sheet.safeAreaLayoutGuide.bottomAnchor constant:-10],
        [icon.widthAnchor constraintEqualToConstant:54],
        [icon.heightAnchor constraintEqualToConstant:54],
        [ok.heightAnchor constraintEqualToConstant:50],
        [github.heightAnchor constraintEqualToConstant:44],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.view layoutIfNeeded];
    _sheet.transform = CGAffineTransformMakeTranslation(0, _sheet.bounds.size.height + 40);
    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.4
                        options:0 animations:^{
        self->_sheet.transform = CGAffineTransformIdentity;
        self->_dim.alpha = 1;
    } completion:nil];
}

// VoiceOver: the sheet is modal, and the two-finger scrub closes it like OK.
- (BOOL)accessibilityPerformEscape {
    [self close];
    return YES;
}

- (void)close {
    if (_closing) return; // OK then the dimmed area: one close, one permission request
    _closing = YES;
    [UIView animateWithDuration:0.25 animations:^{
        self->_sheet.transform = CGAffineTransformMakeTranslation(0, self->_sheet.bounds.size.height + 40);
        self->_dim.alpha = 0;
    } completion:^(BOOL finished) {
        XSHideWindow();
        // The moment the reminder makes sense: the person just read until when the app works.
        XSScheduleReminder(self->_expiry, YES);
    }];
}

- (void)openGitHub {
    NSURL *url = [NSURL URLWithString:XSRepoURL];
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    [self close];
}
@end

// MARK: - The banner (after a refresh): a card rising at the bottom, closed with OK

/// Touches outside the banner go to the app.
@interface XSPassthroughWindow : UIWindow
@end
@implementation XSPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
@end

@interface XSBannerController : UIViewController
/// `previousVersion`: the version the app had before XSide installed this one (an update), nil
/// for a refresh of the same version.
- (instancetype)initWithExpiry:(NSDate *)expiry previousVersion:(NSString *)previousVersion;
@end

@implementation XSBannerController {
    NSDate *_expiry;
    NSString *_previousVersion;
    UIView *_card;
    BOOL _closing;
}

- (instancetype)initWithExpiry:(NSDate *)expiry previousVersion:(NSString *)previousVersion {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _expiry = expiry;
        _previousVersion = previousVersion;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    BOOL fr = XSFrench();
    self.view.backgroundColor = UIColor.clearColor;

    // The shadow lives on a holder: the blur view clips.
    UIView *holder = [UIView new];
    holder.layer.shadowColor = UIColor.blackColor.CGColor;
    holder.layer.shadowOpacity = 0.22;
    holder.layer.shadowRadius = 22;
    holder.layer.shadowOffset = CGSizeMake(0, 8);
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:
                                [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]];
    card.layer.cornerRadius = 26;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;

    UIImageView *icon = [[UIImageView alloc] initWithImage:XSIcon()];
    icon.layer.cornerRadius = 11;
    icon.layer.cornerCurve = kCACornerCurveContinuous;
    icon.clipsToBounds = YES;
    UILabel *title = [UILabel new];
    NSString *version = XSAppVersion();
    BOOL updated = _previousVersion != nil && version != nil;
    // An older version installed over a newer one: said as such, not as an update.
    BOOL older = updated && [version compare:_previousVersion options:NSNumericSearch] == NSOrderedAscending;
    title.text = older ? (fr ? @"Version antérieure installée par XSide" : @"Older version installed by XSide")
               : updated ? (fr ? @"Mise à jour par XSide" : @"Updated by XSide")
                         : (fr ? @"Rafraîchie par XSide" : @"Refreshed by XSide");
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    UILabel *subtitle = [UILabel new];
    NSString *until = [NSString stringWithFormat:fr ? @"Valable jusqu'au %@" : @"Valid until %@", XSDate(_expiry)];
    subtitle.text = updated
        ? [NSString stringWithFormat:fr ? @"Version %@ (avant : %@)\n%@" : @"Version %@ (was %@)\n%@", version, _previousVersion, until]
        : until;
    subtitle.font = [UIFont systemFontOfSize:14];
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.numberOfLines = 0;
    UIStackView *titles = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    titles.axis = UILayoutConstraintAxisVertical;
    titles.spacing = 2;
    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[icon, titles]];
    head.spacing = 14;
    head.alignment = UIStackViewAlignmentCenter;

    XSGradientButton *ok = [XSGradientButton buttonWithType:UIButtonTypeCustom];
    [ok setTitle:@"OK" forState:UIControlStateNormal];
    [ok setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    ok.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [ok addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[head, ok]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;

    for (UIView *v in @[holder, card, stack]) v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:holder];
    [holder addSubview:card];
    [card.contentView addSubview:stack];
    NSLayoutConstraint *wide = [holder.widthAnchor constraintEqualToAnchor:self.view.widthAnchor constant:-24];
    wide.priority = UILayoutPriorityDefaultHigh; // capped on iPad
    [NSLayoutConstraint activateConstraints:@[
        [holder.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [holder.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [holder.widthAnchor constraintLessThanOrEqualToConstant:460],
        wide,
        [card.topAnchor constraintEqualToAnchor:holder.topAnchor],
        [card.bottomAnchor constraintEqualToAnchor:holder.bottomAnchor],
        [card.leadingAnchor constraintEqualToAnchor:holder.leadingAnchor],
        [card.trailingAnchor constraintEqualToAnchor:holder.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:18],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-18],
        [icon.widthAnchor constraintEqualToConstant:48],
        [icon.heightAnchor constraintEqualToConstant:48],
        [ok.heightAnchor constraintEqualToConstant:48],
    ]];
    _card = holder;
    // Stays until OK (or a swipe down); the app stays usable around it.
    UISwipeGestureRecognizer *down = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
    down.direction = UISwipeGestureRecognizerDirectionDown;
    [holder addGestureRecognizer:down];
}

- (CGAffineTransform)hidden {
    return CGAffineTransformMakeTranslation(0, self.view.bounds.size.height - CGRectGetMinY(_card.frame) + 20);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.view layoutIfNeeded];
    _card.transform = [self hidden];
    [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)close {
    if (_closing) return;
    _closing = YES;
    [UIView animateWithDuration:0.3 animations:^{
        self->_card.transform = [self hidden];
    } completion:^(BOOL finished) { XSHideWindow(); }];
}
@end

// MARK: - Showing them

/// `refreshed`: the app already knew an earlier signature (an install over it): the banner.
/// `previousVersion`: set when that install was another version of the app (an update).
static void XSShow(NSDate *expiry, BOOL refreshed, NSString *previousVersion, int attempt) {
    UIWindowScene *scene = XSScene();
    if (!scene) {
        if (attempt + 1 >= XSMaxAttempts) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XSShow(expiry, refreshed, previousVersion, attempt + 1);
        });
        return;
    }
    if (XSWindow) return;
    UIWindow *window;
    if (refreshed) {
        // Never key: the app keeps its keyboard and focus.
        window = [[XSPassthroughWindow alloc] initWithWindowScene:scene];
        window.rootViewController = [[XSBannerController alloc] initWithExpiry:expiry previousVersion:previousVersion];
    } else {
        for (UIWindow *w in scene.windows) if (w.isKeyWindow) XSPreviousKey = w;
        window = [[UIWindow alloc] initWithWindowScene:scene];
        // Hidden at first: the sheet slides up once on screen (see viewDidAppear).
        window.rootViewController = [[XSWelcomeController alloc] initWithExpiry:expiry];
    }
    window.windowLevel = UIWindowLevelAlert + 100;
    window.backgroundColor = UIColor.clearColor;
    XSWindow = window;
    if (refreshed) window.hidden = NO; else [window makeKeyAndVisible];
    // Announced once shown: a relaunch before tapping OK doesn't show it again.
    [NSUserDefaults.standardUserDefaults setObject:expiry forKey:XSAnnouncedKey];
    NSString *version = XSAppVersion();
    if (version) [NSUserDefaults.standardUserDefaults setObject:version forKey:XSAnnouncedVersionKey];
}

/// XSide's logo as a notification thumbnail. iOS moves the file into its own store, so a fresh
/// copy is written each time. Nil without the logo or when the file can't be written.
static UNNotificationAttachment *XSLogoAttachment(void) {
#ifdef XS_HAS_ICON
    NSString *name = [NSString stringWithFormat:@"xside-logo-%@.png", NSUUID.UUID.UUIDString];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    NSData *png = [NSData dataWithBytesNoCopy:(void *)XSWelcomeIcon length:XSWelcomeIcon_len freeWhenDone:NO];
    if (![png writeToURL:url atomically:YES]) return nil;
    return [UNNotificationAttachment attachmentWithIdentifier:@"xside-logo" URL:url options:nil error:NULL];
#else
    return nil;
#endif
}

/// A local reminder 24 h before expiry, replaced at each launch (so a refresh followed by a
/// launch moves it), when the app may notify. `askIfNeeded`: the app never asked for that
/// permission, so it's asked now (once: iOS never asks again after an answer).
static void XSScheduleReminder(NSDate *expiry, BOOL askIfNeeded) {
#ifdef XS_TEST_REMINDER
    NSTimeInterval wait = 60; // test build (XSIDE_TEST_REMINDER=1 scripts/bundle.sh): a minute after launch
#else
    NSTimeInterval wait = [expiry timeIntervalSinceNow] - XSReminderLead();
#endif
    UNUserNotificationCenter *center = XSCenter();
    if (wait < 60 || !XSReminderOn()) {
        [center removePendingNotificationRequestsWithIdentifiers:@[XSReminderID]];
        return;
    }
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        UNAuthorizationStatus status = settings.authorizationStatus;
        NSLog(@"[XSide] notifications: status %ld, ask %d, reminder in %.0f s", (long)status, askIfNeeded, wait);
        if (status == UNAuthorizationStatusNotDetermined && askIfNeeded) {
            [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                                  completionHandler:^(BOOL granted, NSError *error) {
                NSLog(@"[XSide] notifications: asked, granted %d, error %@", granted, error);
                if (granted) dispatch_async(dispatch_get_main_queue(), ^{ XSScheduleReminder(expiry, NO); });
            }];
            return;
        }
        if (status != UNAuthorizationStatusAuthorized && status != UNAuthorizationStatusProvisional) return;
        BOOL fr = XSFrench();
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        NSInteger hours = (NSInteger)(XSReminderLead() / 3600);
        content.title = hours >= 20
            ? [NSString stringWithFormat:fr ? @"%@ expire demain" : @"%@ expires tomorrow", XSAppName()]
            : [NSString stringWithFormat:fr ? @"%@ expire dans %ld h" : @"%@ expires in %ld hours", XSAppName(), (long)hours];
        // A refresh only moves the reminder at the next launch: worded so it stays true.
        content.body = fr ? @"Sauf si XSide l'a rafraîchie entre-temps. Il lui faut ton Mac allumé avec XSide ouvert, et l'appareil sur le même Wi-Fi ou branché en USB. Ouvre l'app pour vérifier."
                          : @"Unless XSide refreshed it meanwhile. It needs your Mac on with XSide open, and the device on the same Wi-Fi or plugged in over USB. Open the app to check.";
        content.sound = UNNotificationSound.defaultSound;
        // The icon on the left is always the app's (iOS); XSide's logo goes on the right.
        UNNotificationAttachment *logo = XSLogoAttachment();
        if (logo) content.attachments = @[logo];
        UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:wait repeats:NO];
        [center addNotificationRequest:[UNNotificationRequest requestWithIdentifier:XSReminderID content:content trigger:trigger]
                 withCompletionHandler:^(NSError *error) { NSLog(@"[XSide] reminder scheduled, error %@", error); }];
    }];
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
        XSScheduleReminder(expiry, NO); // asked only when the sheet closes, as it says

        id announced = [NSUserDefaults.standardUserDefaults objectForKey:XSAnnouncedKey];
        if ([announced isKindOfClass:NSDate.class] && [announced isEqualToDate:expiry]) return;
        // Known since 1.0.6: before, an update reads as a refresh.
        id seen = [NSUserDefaults.standardUserDefaults objectForKey:XSAnnouncedVersionKey];
        NSString *version = XSAppVersion();
        NSString *previous = [seen isKindOfClass:NSString.class] && version && ![seen isEqualToString:version] ? seen : nil;
        XSShow(expiry, [announced isKindOfClass:NSDate.class], previous, 0);
    }];
}
