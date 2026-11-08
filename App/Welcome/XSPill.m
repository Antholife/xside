// See XSPill.h.

#import "XSPill.h"
#import "XSChannel.h"
#import "XSSettingsCore.h"

#ifdef XS_TEST_LATE
// Found by scripts/release.sh, which refuses to ship a test build.
__attribute__((used)) static const char XSTestLateMarker[] = "XSIDE_TEST_LATE_BUILD";
#endif

static const int XSPillMaxAttempts = 20;

@interface XSPillContent ()
/// Shown by XSShowPillWhenFree: the next such pill may replace it.
@property (nonatomic) BOOL whenFree;
@end

@implementation XSPillContent
@end

static UIColor *XSToneColor(XSPillTone tone) {
    switch (tone) {
        case XSPillToneOrange: return UIColor.systemOrangeColor;
        case XSPillToneRed: return UIColor.systemRedColor;
        default: return UIColor.labelColor;
    }
}

/// "XSide : valable encore …": every pill says who speaks (Anthony). The first word after the
/// prefix is lowercased, except names (Mac, iPhone, iPad); a text that already starts with
/// "XSide" is left as it is.
static NSString *XSPrefixed(NSString *lead) {
    if (lead.length == 0 || [lead hasPrefix:@"XSide"]) return lead ?: @"";
    NSString *first = [lead componentsSeparatedByString:@" "].firstObject;
    BOOL name = [@[@"Mac", @"iPhone", @"iPad"] containsObject:first];
    NSString *rest = name ? lead : [[lead substringToIndex:1].lowercaseString stringByAppendingString:[lead substringFromIndex:1]];
    return [XST(@"XSide : ", @"XSide: ") stringByAppendingString:rest];
}

@interface XSPillController : UIViewController
- (instancetype)initWithContent:(XSPillContent *)content;
- (void)dismiss;
@end

/// The pill's own window: passthrough, never key, under the install sheet's.
static UIWindow *XSPillWindow;
/// What it shows.
static XSPillContent *XSPillOnScreen;
/// The pill waiting for the screen to be free (XSShowPillWhenFree), and since when.
static XSPillContent *XSPillWaiting;
static NSDate *XSPillWaitingSince;

static void XSShowPillAttempt(XSPillContent *content, int attempt);

/// `gone`: dismissed (not replaced by a newer one): the pill waiting, if any, comes now.
static void XSHidePillWindow(UIWindow *window, BOOL gone) {
    window.hidden = YES;
    if (XSPillWindow != window) return;
    XSPillWindow = nil;
    XSPillOnScreen = nil;
    if (!gone || !XSPillWaiting) return;
    XSPillContent *next = XSPillWaiting;
    XSPillWaiting = nil;
    if (-XSPillWaitingSince.timeIntervalSinceNow > 30) return; // too late to be news
    XSShowPillAttempt(next, 0);
}

@implementation XSPillController {
    XSPillContent *_content;
    UIView *_holder;
    BOOL _closing;
}

- (instancetype)initWithContent:(XSPillContent *)content {
    if ((self = [super initWithNibName:nil bundle:nil])) _content = content;
    return self;
}

- (UILabel *)label:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *l = [UILabel new];
    l.font = XSScaledFont(size, weight);
    l.textColor = color;
    l.adjustsFontForContentSizeCategory = YES;
    l.numberOfLines = 0;
    return l;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    XSPillContent *c = _content;
    BOOL twoLines = c.hint.length > 0 || c.buttonTitle.length > 0;

    // The shadow lives on a holder: the blur view clips.
    UIView *holder = [UIView new];
    holder.layer.shadowColor = UIColor.blackColor.CGColor;
    holder.layer.shadowOpacity = 0.18;
    holder.layer.shadowRadius = 14;
    holder.layer.shadowOffset = CGSizeMake(0, 6);
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
                                [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]];
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.layer.cornerRadius = twoLines ? 20 : 25;
    blur.clipsToBounds = YES;

    UIImageView *icon = [[UIImageView alloc] initWithImage:XSIcon()];
    icon.layer.cornerRadius = 8;
    icon.layer.cornerCurve = kCACornerCurveContinuous;
    icon.clipsToBounds = YES;

    UILabel *title = [self label:14 weight:UIFontWeightSemibold color:UIColor.labelColor];
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:XSPrefixed(c.lead)];
    if (c.strong.length) {
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:c.strong attributes:@{
            NSFontAttributeName: XSScaledFont(14, UIFontWeightBold), NSForegroundColorAttributeName: XSToneColor(c.tone)}]];
    }
    if (c.tail.length) [text appendAttributedString:[[NSAttributedString alloc] initWithString:c.tail]];
    title.attributedText = text; // wraps on as many lines as it needs (device feedback round 1, B2)

    NSMutableArray<UIView *> *texts = [NSMutableArray arrayWithObject:title];
    if (c.hint.length) {
        UILabel *hint = [self label:12 weight:UIFontWeightMedium color:UIColor.secondaryLabelColor];
        hint.text = c.hint;
        [texts addObject:hint];
    }
    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:texts];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;

    // The text takes the whole width beside the icon (and the spinner) and wraps on as many lines
    // as it needs; a button goes on its own line under it, at the trailing edge, so it never
    // squeezes the text (device feedback round 2, P6).
    for (UIView *label in textStack.arrangedSubviews) {
        [label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    }
    NSMutableArray<UIView *> *row = [NSMutableArray arrayWithObjects:icon, textStack, nil];
    if (c.busy) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        [spinner setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [row addObject:spinner];
    }
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:row];
    top.spacing = 10;
    top.alignment = twoLines ? UIStackViewAlignmentTop : UIStackViewAlignmentCenter;
    NSMutableArray<UIView *> *lines = [NSMutableArray arrayWithObject:top];
    if (c.buttonTitle.length) {
        XSGradientButton *button = [XSGradientButton buttonWithType:UIButtonTypeCustom];
        ((CAGradientLayer *)button.layer).cornerRadius = 15;
        UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
        config.contentInsets = NSDirectionalEdgeInsetsMake(6, 14, 6, 14);
        config.baseForegroundColor = UIColor.whiteColor;
        config.attributedTitle = [[NSAttributedString alloc] initWithString:c.buttonTitle attributes:@{
            NSFontAttributeName: XSScaledFont(13, UIFontWeightSemibold)}];
        config.titleLineBreakMode = NSLineBreakByWordWrapping;
        button.configuration = config;
        [button addTarget:self action:@selector(tapButton) forControlEvents:UIControlEventTouchUpInside];
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:30].active = YES;
        // Trailing, under the text: a spacer on the leading side.
        UIView *spacer = [UIView new];
        [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[spacer, button]];
        [lines addObject:buttonRow];
    }
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:lines];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 8;

    for (UIView *v in @[holder, blur, content]) v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:holder];
    [holder addSubview:blur];
    [blur.contentView addSubview:content];
    // Every pill the same width: the screen's less 10 pt each side (in the safe area), capped on
    // iPad. The cap and the screen are required, so a long text wraps and the pill grows in height
    // instead of growing past the screen, where it was cut (device feedback round 2, P6): at the
    // same priority as the labels' resistance, Auto Layout could widen the pill instead.
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *wide = [holder.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-20];
    wide.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[
        [holder.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [holder.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [holder.widthAnchor constraintLessThanOrEqualToConstant:500],
        [holder.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-20],
        wide,
        [blur.topAnchor constraintEqualToAnchor:holder.topAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:holder.bottomAnchor],
        [blur.leadingAnchor constraintEqualToAnchor:holder.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:holder.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:blur.contentView.topAnchor constant:10],
        [content.bottomAnchor constraintEqualToAnchor:blur.contentView.bottomAnchor constant:-10],
        [content.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor constant:10],
        [content.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor constant:-14],
        [icon.widthAnchor constraintEqualToConstant:30],
        [icon.heightAnchor constraintEqualToConstant:30],
    ]];
    _holder = holder;

    // A tap (outside the button) or a swipe up dismisses it; the app stays usable around it. A
    // pill with a tap action runs it too.
    [holder addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapPill)]];
    UISwipeGestureRecognizer *up = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(dismiss)];
    up.direction = UISwipeGestureRecognizerDirectionUp;
    [holder addGestureRecognizer:up];
}

- (CGAffineTransform)hiddenTransform {
    return CGAffineTransformMakeTranslation(0, -(CGRectGetMaxY(_holder.frame) + 20));
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.view layoutIfNeeded];
    _holder.transform = [self hiddenTransform];
    [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_holder.transform = CGAffineTransformIdentity;
    } completion:nil];
    NSString *spoken = [NSString stringWithFormat:@"%@%@%@. %@", XSPrefixed(_content.lead), _content.strong ?: @"",
                        _content.tail ?: @"", _content.hint ?: @""];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, spoken);
    if (_content.duration > 0) {
        __weak XSPillController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_content.duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf dismiss];
        });
    }
}

- (void)dismiss {
    if (_closing) return;
    _closing = YES;
    UIWindow *window = self.view.window;
    [UIView animateWithDuration:0.3 animations:^{
        self->_holder.transform = [self hiddenTransform];
    } completion:^(BOOL finished) { XSHidePillWindow(window, YES); }];
}

- (void)tapPill {
    void (^action)(void) = _content.tapAction;
    [self dismiss];
    if (action) action();
}

- (void)tapButton {
    void (^action)(void) = _content.action;
    [self dismiss];
    if (action) action();
}
@end

/// An answer that came while the app was in the background, for its return (main queue).
static XSPillContent *XSKeptAnswer;
static NSDate *XSKeptAnswerAt;

static void XSShowPillAttempt(XSPillContent *content, int attempt) {
    UIWindowScene *scene = XSScene();
    if (!scene) {
        if (attempt + 1 >= XSPillMaxAttempts) {
            // Mega review minor 3: the result of an exchange whose busy pill ("Envoi de tes
            // réglages…", "En attente du Mac…") is still up, and no scene to show it in: the
            // spinner would stay until another pill. Hidden now; the result is kept for the return
            // like an answer (XSShowKeptAnswer), if it is a final one.
            if (XSPillWindow && XSPillOnScreen.busy) {
                XSHidePillWindow(XSPillWindow, NO);
                if (content.duration > 0) {
                    XSKeptAnswer = content;
                    XSKeptAnswerAt = NSDate.date;
                }
            }
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XSShowPillAttempt(content, attempt + 1);
        });
        return;
    }
    if (XSPillWindow) XSHidePillWindow(XSPillWindow, NO); // one pill at a time: the newest
    UIWindow *window = [[XSPassthroughWindow alloc] initWithWindowScene:scene];
    window.rootViewController = [[XSPillController alloc] initWithContent:content];
    window.windowLevel = UIWindowLevelAlert + 99;
    window.backgroundColor = UIColor.clearColor;
    XSPillWindow = window;
    XSPillOnScreen = content;
    window.hidden = NO; // never key: the app keeps its keyboard and focus
}

void XSShowPill(XSPillContent *content) {
    if (!XSShowsPill(XSCurrentSettings(), content.answer)) return; // "Aucun": only answers to the person
    dispatch_async(dispatch_get_main_queue(), ^{
        if (content.answer) {
            BOOL onScreen = UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
            if (XSKeepsAnswerForReturn(onScreen, content.duration)) {
                XSKeptAnswer = content;
                XSKeptAnswerAt = NSDate.date;
                return;
            }
            XSKeptAnswer = nil; // a newer answer replaces it
        }
        XSShowPillAttempt(content, 0);
    });
}

void XSShowKeptAnswer(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        XSPillContent *kept = XSKeptAnswer;
        BOOL fresh = XSKeptAnswerStillFresh(XSKeptAnswerAt, NSDate.date);
        XSKeptAnswer = nil;
        XSKeptAnswerAt = nil;
        if (kept && fresh) XSShowPill(kept);
    });
}

void XSShowPillWhenFree(XSPillContent *content) {
    if (!XSShowsPill(XSCurrentSettings(), content.answer)) return;
    content.whenFree = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!XSPillWindow || XSPillOnScreen.whenFree) {
            XSPillWaiting = nil;
            XSShowPillAttempt(content, 0);
            return;
        }
        XSPillWaiting = content;
        XSPillWaitingSince = NSDate.date;
    });
}

// MARK: - The launch pill

/// "Valable encore " + "N jours", or under a day "Expire dans " + "N h".
static void XSTimeLeft(NSTimeInterval left, XSPillContent *c) {
    BOOL fr = XSFrench();
    if (left >= 86400) {
        long days = (long)ceil(left / 86400);
        c.lead = fr ? @"Valable encore " : @"Valid for ";
        c.strong = days == 1 ? (fr ? @"1 jour" : @"1 more day")
                             : [NSString stringWithFormat:fr ? @"%ld jours" : @"%ld more days", days];
    } else {
        long hours = MAX(1, lround(left / 3600));
        c.lead = fr ? @"Expire dans " : @"Expires in ";
        c.strong = [NSString stringWithFormat:@"%ld h", hours];
    }
}

static XSPillContent *XSRefreshablePill(XSPillContent *c) {
    c.buttonTitle = XST(@"Rafraîchir", @"Refresh");
    c.action = ^{ XSRequestRefresh(); };
    return c;
}

XSPillContent *XSPendingPillContent(NSString *key) {
    BOOL fr = XSFrench();
    XSPillContent *c = [XSPillContent new];
    if ([key isEqualToString:XSNoOutcomeKey]) {
        c.lead = fr ? @"Le rafraîchissement demandé n'a pas donné de nouvelles" : @"No news of the refresh you asked for";
        c.hint = fr ? @"XSide n'a pas répondu à temps. Regarde XSide sur ton Mac, ou redemande."
                    : @"XSide didn't answer in time. Check XSide on your Mac, or ask again.";
    } else {
        c.lead = fr ? @"Le dernier rafraîchissement demandé a échoué" : @"The refresh you asked for failed";
        NSString *reason = XSReasonText(key, fr);
        c.hint = [[reason substringToIndex:1].uppercaseString stringByAppendingString:[reason substringFromIndex:1]];
    }
    c.tone = XSPillToneOrange;
    c.duration = 8;
    return XSRefreshablePill(c);
}

void XSShowPendingPill(void) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return; // next launch
    NSString *key = XSTakePendingFailure();
    if (!key) return;
    XSPillContent *c = XSPendingPillContent(key);
    c.answer = YES; // the outcome of a Refresh the person asked for
    XSShowPill(c);
}

static NSString *const XSNotificationsExplainedKey = @"io.github.xside.welcome.notificationsExplained";

void XSOfferNotificationsIfNeeded(void (^otherwise)(void)) {
    // The install sheet asks when it closes, but only once and only if the reminder was on then:
    // with the reminder on and iOS never asked, once, a pill says why and asks on OK. Never with
    // the reminder off, never twice, never when iOS already has an answer.
    NSDictionary *s = XSCurrentSettings();
    BOOL wanted = XSSchedulesReminder(s)
        && ![XSDefaults() boolForKey:XSNotificationsExplainedKey];
    if (!wanted) { otherwise(); return; }
    [XSCenter() getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        BOOL ask = settings.authorizationStatus == UNAuthorizationStatusNotDetermined;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ask) { otherwise(); return; }
            [XSDefaults() setBool:YES forKey:XSNotificationsExplainedKey];
            BOOL fr = XSFrench();
            XSPillContent *c = [XSPillContent new];
            c.lead = fr ? @"XSide te prévient avant l'expiration" : @"XSide reminds you before it expires";
            c.hint = fr ? @"Autorise les notifications pour recevoir ce rappel." : @"Allow notifications to get this reminder.";
            c.duration = 10;
            c.buttonTitle = @"OK";
            c.action = ^{
                [XSCenter() requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                                          completionHandler:^(BOOL granted, NSError *error) {
                    NSLog(@"[XSide] notifications: asked from the pill, granted %d, error %@", granted, error);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSDate *expiry = XSExpirationDate();
                        if (granted && expiry) XSScheduleReminder(expiry, NO);
                    });
                }];
            };
            XSShowPill(c);
        });
    }];
}

XSPillContent *XSLaunchPillContent(NSDate *expiry) {
    NSDictionary *s = XSCurrentSettings();
    NSTimeInterval left = expiry.timeIntervalSinceNow;
    if (left <= 0) return nil;
    NSInteger threshold = XSThresholdHours();
    BOOL late = XSIsLate(left, threshold);
    // Paused: no refresh is coming, so "late" starts at the threshold itself (no 6 h margin).
    BOOL pausedLate = left < threshold * 3600.0;
#ifdef XS_TEST_LATE
    late = pausedLate = YES; // test build (XSIDE_TEST_LATE=1 scripts/bundle.sh)
#endif
    BOOL fr = XSFrench();
    NSString *device = XSDeviceKind();
    XSPillContent *c = [XSPillContent new];

    // A refresh asked from this phone failed, or was never heard of, while the app was away (its
    // notification may have gone unseen). It answers the person's own request: shown even with "Aucun".
    NSString *failure = XSTakePendingFailure();
    if (failure) {
        XSPillContent *pending = XSPendingPillContent(failure);
        pending.answer = YES; // shown even with "Aucun" (ledger ruling)
        return pending;
    }

    if (!XSSettingBool(s, @"autoRefresh")) {
        // Spec "Late pill when paused": never "XSide couldn't refresh it", under the same switches.
        // Not news (the change had its own pill when it was made, device feedback round 2, P1):
        // the state, as part of the launch line ("valable encore 6 jours · rafraîchissement
        // automatique en pause"), and a warning only when it gets close to expiry.
        BOOL byDevice = [s[@"autoRefresh"][@"changedBy"] isEqual:@"device"];
        NSString *who = byDevice ? [NSString stringWithFormat:fr ? @"cet %@" : @"this %@", device]
                                 : (fr ? @"le Mac" : @"the Mac");
        if (XSShowsLatePill(s, pausedLate)) {
            c.lead = fr ? @"Rafraîchissement automatique en pause · expire le " : @"Automatic refresh paused · expires ";
            c.strong = XSDate(expiry);
            c.hint = [NSString stringWithFormat:fr ? @"En pause depuis %@. Réactive-le pour que XSide la rafraîchisse."
                                                   : @"Paused from %@. Turn it back on for XSide to refresh it.", who];
            c.tone = left < 86400 ? XSPillToneRed : XSPillToneOrange;
            c.duration = 8;
            return c;
        }
        if (!XSShowsValidityPill(s, pausedLate)) return nil;
        XSTimeLeft(left, c);
        c.tail = fr ? @" · rafraîchissement automatique en pause" : @" · automatic refresh paused";
        c.duration = 4;
        return c;
    }

    if (XSShowsLatePill(s, late)) {
        XSTimeLeft(left, c);
        if (left >= 86400) {
            c.tone = XSPillToneOrange;
            c.hint = fr ? @"XSide n'a pas encore pu la rafraîchir. Pense à ouvrir XSide sur ton Mac (même Wi-Fi ou câble USB)."
                        : @"XSide hasn't been able to refresh it yet. Remember to open XSide on your Mac (same Wi-Fi or USB cable).";
        } else {
            c.tone = XSPillToneRed;
            c.hint = [NSString stringWithFormat:fr
                ? @"XSide n'a pas pu la rafraîchir. Ouvre XSide sur ton Mac, %@ sur le même Wi-Fi ou branché, avant qu'elle expire."
                : @"XSide couldn't refresh it. Open XSide on your Mac, with your %@ on the same Wi-Fi or plugged in, before it expires.",
                device];
        }
        c.duration = 8;
        return XSRefreshablePill(c); // always offered (spec Q1); "Mac not found" comes after the tap
    }

    if (XSShowsValidityPill(s, late)) {
        XSTimeLeft(left, c);
        c.duration = 3;
        return c;
    }
    return nil;
}
