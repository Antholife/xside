// XSideWelcome: loaded by every app XSide installs. At each cold launch:
// - once per signature (each new provisioning profile), at the first launch after it: after an
//   install (no earlier signature known to the app), a sheet saying the app was installed with
//   XSide and until when it works; after a refresh or an update, a card at the bottom with OK;
// - otherwise the pill at the top (XSPill.m): validity, late or paused alerts;
// - the install sheet has pages: installed with XSide, then (when iOS will ask) why the local
//   network and why notifications, each prompt coming right after its page; nothing XSide asks
//   iOS for comes before (XSAfterSheet, XSExplainNetworkThen);
// - a local reminder before expiry when the app may notify (asked after the sheet's page);
// - the per-app "Réglages XSide" (XSSettings.m) decide what of this shows, and in which language;
// - once the person allowed the local network, a silent check-in with XSide (XSChannel.m).
// The quick actions on the icon are handled by XSShortcuts.m. It never throws, asserts or blocks:
// anything missing (no profile, no window, no network) and it silently does nothing.
//
// Built by scripts/bundle.sh for iOS arm64 (all App/Welcome/*.m) and shipped in
// XSide.app/Contents/Resources; XSide copies it into the app's Frameworks/ and signs it with the app.

#import "XSCommon.h"
#import "XSSettingsCore.h"
#import "XSPill.h"
#import "XSRunMarker.h"
#import "XSChannel.h"
#import "XSShortcuts.h"

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

/// The sheet's (or banner's) own window, above the app's (and its alerts): the app can present,
/// dismiss or replace its screens (sign-in, onboarding) without ever covering or closing it.
static UIWindow *XSWindow;
/// The app's key window before the sheet, given back when it closes.
static __weak UIWindow *XSPreviousKey;

// MARK: - The sheet (design "B": a card rising from the bottom over the dimmed app)

static void XSHideWindow(void) {
    XSWindow.hidden = YES;
    XSWindow = nil;
    [XSPreviousKey makeKeyWindow];
}

/// The sheet's pages (device feedback round 1, B1), in this order, those that apply
/// (XSSheetPages): "welcome" (installed with XSide, until when), "network" (why the local network,
/// before iOS asks), "notifications" (why the reminder, before iOS asks). The stand-alone version
/// shows "network" alone, before the first network access when the first-launch sheet is past.
@interface XSWelcomeController : UIViewController
/// `expiry`: nil for the stand-alone network page. `startsNetwork`: going past "network" starts
/// the first check-in (iOS asks then); the stand-alone page leaves that to `done`.
- (instancetype)initWithExpiry:(NSDate *)expiry pages:(NSArray<NSString *> *)pages
                 startsNetwork:(BOOL)startsNetwork done:(void (^)(void))done;
@end

@implementation XSWelcomeController {
    NSDate *_expiry;
    NSArray<NSString *> *_pages;
    NSUInteger _page;
    BOOL _startsNetwork;
    void (^_done)(void);
    BOOL _fr;
    UIView *_dim;
    UIView *_sheet;
    UIStackView *_body;
    UIPageControl *_dots;
    UIButton *_ok;
    UIButton *_github;
    BOOL _closing;
    /// The silent local network check before the "network" page is running, or was done
    /// (device feedback 3, E4).
    BOOL _probing, _probed;
}

- (instancetype)initWithExpiry:(NSDate *)expiry pages:(NSArray<NSString *> *)pages
                 startsNetwork:(BOOL)startsNetwork done:(void (^)(void))done {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _expiry = expiry;
        _pages = pages.count ? pages : @[@"welcome"];
        _startsNetwork = startsNetwork;
        _done = [done copy];
        _fr = XSFrench();
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    }
    return self;
}

- (NSString *)t:(NSString *)fr en:(NSString *)en { return _fr ? fr : en; }

- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = XSScaledFont(size, weight);
    l.textColor = color;
    l.numberOfLines = 0;
    l.adjustsFontForContentSizeCategory = YES;
    return l;
}

/// "Valable jusqu'au … | jeu. 12 nov., 14:30", with a hairline above. Both sides wrap (large
/// text) and the row grows with them.
- (UIView *)line:(NSString *)name value:(NSString *)value {
    UIView *row = [UIView new];
    UIView *rule = [UIView new];
    rule.backgroundColor = UIColor.separatorColor;
    UILabel *left = [self label:name size:14 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    UILabel *right = [self label:value size:14 weight:UIFontWeightSemibold color:UIColor.labelColor];
    right.textAlignment = NSTextAlignmentRight;
    [left setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    for (UIView *v in @[rule, left, right]) { v.translatesAutoresizingMaskIntoConstraints = NO; [row addSubview:v]; }
    NSLayoutConstraint *snug = [left.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-12];
    snug.priority = UILayoutPriorityDefaultLow; // the row is as tall as its taller side
    [NSLayoutConstraint activateConstraints:@[
        [rule.topAnchor constraintEqualToAnchor:row.topAnchor],
        [rule.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [rule.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [rule.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
        [left.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [left.topAnchor constraintEqualToAnchor:row.topAnchor constant:12],
        [left.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-12],
        [left.widthAnchor constraintLessThanOrEqualToAnchor:row.widthAnchor multiplier:0.5],
        [right.leadingAnchor constraintGreaterThanOrEqualToAnchor:left.trailingAnchor constant:12],
        [right.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [right.firstBaselineAnchor constraintEqualToAnchor:left.firstBaselineAnchor],
        [right.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-12],
        snug,
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

/// "⚙️ These details stay in Settings > Apps > <App> > XSide Settings": one label with the gear
/// inline, so it wraps like any other (it was cut to one line beside a separate gear: device
/// feedback round 1, B2).
- (UIView *)settingsHint {
    UIFont *font = XSScaledFont(13, UIFontWeightRegular);
    // XSide's page sits under the app's own (one row there opens it).
    NSString *path = [NSString stringWithFormat:@"%@ > %@", XSSettingsPath(), XSSettingsRowShown()];
    NSString *text = [NSString stringWithFormat:[self t:@"Ces infos restent dans %@" en:@"These details stay in %@"], path];
    if (XSHasShortcuts()) {
        text = [text stringByAppendingString:[self t:@", et à un appui long sur l'icône de l'app."
                                                  en:@", and a long press on the app's icon away."]];
    }
    NSMutableAttributedString *styled = [NSMutableAttributedString new];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithFont:font scale:UIImageSymbolScaleSmall];
    UIImage *gear = [[UIImage systemImageNamed:@"gearshape.fill" withConfiguration:config]
                     imageWithTintColor:XSViolet() renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (gear) {
        NSTextAttachment *attachment = [NSTextAttachment new];
        attachment.image = gear;
        [styled appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
        [styled appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "]];
    }
    NSUInteger offset = styled.length;
    [styled appendAttributedString:[[NSAttributedString alloc] initWithString:text]];
    [styled addAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.secondaryLabelColor}
                    range:NSMakeRange(0, styled.length)];
    NSRange strong = [text rangeOfString:path];
    if (strong.location != NSNotFound) {
        [styled addAttributes:@{NSFontAttributeName: XSScaledFont(13, UIFontWeightSemibold),
                                NSForegroundColorAttributeName: UIColor.labelColor}
                        range:NSMakeRange(offset + strong.location, strong.length)];
    }
    UILabel *label = [UILabel new];
    label.attributedText = styled;
    label.numberOfLines = 0;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    return label;
}

/// A tinted card with a symbol in the brand gradient: what iOS is about to ask.
- (UIView *)callout:(NSString *)symbol title:(NSString *)titleText body:(NSString *)bodyText {
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
    [badge setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    badge.tintColor = UIColor.whiteColor;

    UILabel *title = [self label:titleText size:15 weight:UIFontWeightSemibold color:UIColor.labelColor];
    UILabel *body = [self label:bodyText size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
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

/// Icon (XSide's, or a symbol in the gradient), title and subtitle.
- (UIView *)head:(NSString *)symbol title:(NSString *)titleText subtitle:(NSString *)subtitleText {
    UIView *icon;
    if (symbol) {
        XSGradientButton *badge = [XSGradientButton buttonWithType:UIButtonTypeCustom];
        badge.userInteractionEnabled = NO;
        ((CAGradientLayer *)badge.layer).cornerRadius = 13;
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
        [badge setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
        badge.tintColor = UIColor.whiteColor;
        icon = badge;
    } else {
        UIImageView *logo = [[UIImageView alloc] initWithImage:XSIcon()];
        logo.layer.cornerRadius = 13;
        logo.layer.cornerCurve = kCACornerCurveContinuous;
        logo.clipsToBounds = YES;
        icon = logo;
    }
    [icon.widthAnchor constraintEqualToConstant:54].active = YES;
    [icon.heightAnchor constraintEqualToConstant:54].active = YES;
    UILabel *title = [self label:titleText size:18 weight:UIFontWeightBold color:UIColor.labelColor];
    title.accessibilityTraits |= UIAccessibilityTraitHeader;
    UILabel *subtitle = [self label:subtitleText size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    UIStackView *titles = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    titles.axis = UILayoutConstraintAxisVertical;
    titles.spacing = 3;
    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[icon, titles]];
    head.spacing = 14;
    head.alignment = UIStackViewAlignmentCenter;
    return head;
}

- (UIStackView *)stackOf:(NSArray<UIView *> *)views {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    return stack;
}

- (NSArray<UIView *> *)welcomeViews {
    UIView *head = [self head:nil title:[self t:@"Installée avec XSide" en:@"Installed with XSide"]
                     subtitle:[self t:@"Rafraîchie automatiquement depuis ton Mac" en:@"Refreshed automatically from your Mac"]];
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:head];
    if (_expiry) {
        UIStackView *lines = [self stackOf:@[[self line:[self t:@"Valable jusqu'au" en:@"Valid until"] value:XSDate(_expiry)],
                                             [self line:[self t:@"Encore" en:@"Time left"] value:[self daysLeft]]]];
        lines.spacing = 0;
        [views addObject:lines];
    }
    // Where to find this again later.
    if (XSHasSettingsSection()) [views addObject:[self settingsHint]];
    return views;
}

- (NSArray<UIView *> *)networkViews {
    NSString *device = XSDeviceKind();
    UIView *head = [self head:@"wifi" title:[self t:@"Réseau local" en:@"Local network"]
                     subtitle:[self t:@"Pour parler à XSide sur ton Mac" en:@"To talk to XSide on your Mac"]];
    // The app by its name wherever it is the one using the network (device feedback 3, E4).
    NSString *app = XSAppName();
    UILabel *why = [self label:[NSString stringWithFormat:[self t:@"Depuis cet %1$@, XSide peut rafraîchir %2$@ ou mettre en pause son rafraîchissement, et garder ses Réglages XSide en accord avec ton Mac. Pour cela, %2$@ parle à XSide sur ton Mac par le réseau local (même Wi-Fi)."
                                                              en:@"From this %1$@, XSide can refresh %2$@ or pause its refresh, and keep its XSide Settings in step with your Mac. For that, %2$@ talks to XSide on your Mac over the local network (same Wi-Fi)."], device, app]
                          size:14 weight:UIFontWeightRegular color:UIColor.labelColor];
    UIView *ask = [self callout:@"checkmark.shield.fill"
                          title:[self t:@"iOS va te demander d'autoriser" en:@"iOS will ask you to allow it"]
                           body:[self t:@"« Trouver des appareils sur le réseau local » : touche Autoriser. XSide ne parle qu'à ton Mac."
                                    en:@"\"Find devices on local networks\": tap Allow. XSide only talks to your Mac."]];
    UILabel *refused = [self label:[NSString stringWithFormat:[self t:@"Si tu refuses : XSide continue de rafraîchir l'app depuis le Mac, mais rien ne peut se faire depuis l'%@. Tu pourras l'autoriser plus tard dans %@ > Réseau local."
                                                                  en:@"If you don't: XSide still refreshes the app from the Mac, but nothing can be done from the %@. You can allow it later in %@ > Local Network."], device, XSSettingsPath()]
                              size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    if (!XSAppUsesLocalNetwork()) return @[head, why, ask, refused];
    // The app may already have made iOS ask for itself (e.g. to find a TV): the same permission.
    UILabel *own = [self label:[NSString stringWithFormat:[self t:@"%@ se sert aussi du réseau local pour ses propres fonctions : iOS a pu déjà le demander pour elle. C'est la même autorisation."
                                                             en:@"%@ also uses the local network for its own features: iOS may already have asked for it. It's the same permission."], XSAppName()]
                          size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    return @[head, why, ask, own, refused];
}

/// iOS already asked for the app (it uses the local network itself) and it was refused: no
/// question to explain, only what that means and how to turn it back on (device feedback 3, E4).
- (NSArray<UIView *> *)networkDeniedViews {
    NSString *device = XSDeviceKind(), *app = XSAppName();
    UIView *head = [self head:@"wifi.slash" title:[self t:@"Réseau local refusé" en:@"Local network not allowed"]
                     subtitle:[NSString stringWithFormat:[self t:@"Déjà demandé par iOS pour %@" en:@"Already asked by iOS for %@"], app]];
    UILabel *what = [self label:[NSString stringWithFormat:[self t:@"%1$@ se sert aussi du réseau local pour ses propres fonctions, et iOS l'a déjà demandé pour elle : l'accès a été refusé. XSide continue de rafraîchir %1$@ depuis ton Mac, mais rien ne peut se faire depuis cet %2$@ (Rafraîchir, pause, réglages envoyés au Mac)."
                                                               en:@"%1$@ also uses the local network for its own features, and iOS already asked for it: access was refused. XSide still refreshes %1$@ from your Mac, but nothing can be done from this %2$@ (Refresh, pause, settings sent to the Mac)."], app, device]
                           size:14 weight:UIFontWeightRegular color:UIColor.labelColor];
    UIView *how = [self callout:@"gearshape.fill"
                          title:[self t:@"Pour l'autoriser" en:@"To allow it"]
                           body:[NSString stringWithFormat:[self t:@"%@ > Réseau local : active-le." en:@"%@ > Local Network: turn it on."], XSSettingsPath()]];
    return @[head, what, how];
}

- (NSArray<UIView *> *)notificationViews {
    UIView *head = [self head:@"bell.badge.fill" title:[self t:@"Notifications" en:@"Notifications"]
                     subtitle:[self t:@"Un rappel avant l'expiration" en:@"A reminder before it expires"]];
    UILabel *why = [self label:[self t:@"XSide te prévient avant l'expiration, au cas où ton Mac n'aurait pas pu rafraîchir l'app à temps. Il te dit aussi si un rafraîchissement demandé d'ici échoue."
                                    en:@"XSide reminds you before it expires, in case your Mac couldn't refresh the app in time. It also tells you if a refresh asked from here fails."]
                          size:14 weight:UIFontWeightRegular color:UIColor.labelColor];
    UIView *ask = [self callout:@"bell.fill"
                          title:[self t:@"iOS va te demander d'autoriser" en:@"iOS will ask you to allow it"]
                           body:[self t:@"Touche Autoriser pour recevoir ce rappel. Tu pourras changer d'avis dans Réglages > Notifications."
                                    en:@"Tap Allow to get this reminder. You can change your mind in Settings > Notifications."]];
    return @[head, why, ask];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    // The app behind, blurred and dimmed; a tap there does what the button does.
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
                                [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    blur.backgroundColor = [UIColor colorWithWhite:0 alpha:0.2];
    _dim = blur;
    _dim.alpha = 0;
    [_dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(next)]];

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

    _body = [self stackOf:@[]];
    _body.spacing = 16;

    _dots = [UIPageControl new];
    _dots.numberOfPages = (NSInteger)_pages.count;
    _dots.hidesForSinglePage = YES;
    _dots.userInteractionEnabled = NO;
    _dots.pageIndicatorTintColor = [XSViolet() colorWithAlphaComponent:0.25];
    _dots.currentPageIndicatorTintColor = XSViolet();

    XSGradientButton *ok = [XSGradientButton buttonWithType:UIButtonTypeCustom];
    [ok setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    ok.titleLabel.font = XSScaledFont(16, UIFontWeightSemibold);
    ok.titleLabel.adjustsFontForContentSizeCategory = YES;
    ok.titleLabel.numberOfLines = 0;
    ok.titleLabel.textAlignment = NSTextAlignmentCenter;
    [ok addTarget:self action:@selector(next) forControlEvents:UIControlEventTouchUpInside];
    _ok = ok;
    UIButton *github = [UIButton buttonWithType:UIButtonTypeSystem];
    [github setTitle:[self t:@"XSide sur GitHub" en:@"XSide on GitHub"] forState:UIControlStateNormal];
    github.tintColor = XSViolet();
    github.titleLabel.font = XSScaledFont(15, UIFontWeightSemibold);
    github.titleLabel.adjustsFontForContentSizeCategory = YES;
    [github addTarget:self action:@selector(openGitHub) forControlEvents:UIControlEventTouchUpInside];
    _github = github;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_body, _dots, ok, github]];
    stack.axis = UILayoutConstraintAxisVertical;
    [stack setCustomSpacing:12 afterView:_body];
    [stack setCustomSpacing:12 afterView:_dots];
    [stack setCustomSpacing:4 afterView:ok];

    // The content scrolls when it doesn't fit (landscape, large text); otherwise the sheet is its height.
    UIScrollView *scroll = [UIScrollView new];
    scroll.alwaysBounceVertical = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    for (UIView *v in @[_dim, _sheet]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:v]; }
    for (UIView *v in @[grab, scroll]) { v.translatesAutoresizingMaskIntoConstraints = NO; [_sheet addSubview:v]; }
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    NSLayoutConstraint *fitsContent = [scroll.heightAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.heightAnchor];
    // Below the labels' compression resistance (750): too tall, it scrolls rather than squashing them.
    fitsContent.priority = UILayoutPriorityDefaultHigh - 1;
    // Full width, capped on iPad. Never wider than the screen (required): with the full width at
    // the labels' own priority (750), Auto Layout could widen the sheet past the screen for a long
    // line instead of wrapping it, and the content then touched or crossed the edges (device
    // feedback round 2, P5).
    NSLayoutConstraint *fullWidth = [_sheet.widthAnchor constraintEqualToAnchor:self.view.widthAnchor];
    fullWidth.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[
        [_dim.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_dim.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_dim.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_dim.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_sheet.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_sheet.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_sheet.widthAnchor constraintLessThanOrEqualToConstant:500],
        [_sheet.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor],
        fullWidth,
        [grab.topAnchor constraintEqualToAnchor:_sheet.topAnchor constant:10],
        [grab.centerXAnchor constraintEqualToAnchor:_sheet.centerXAnchor],
        [grab.widthAnchor constraintEqualToConstant:38],
        [grab.heightAnchor constraintEqualToConstant:5],
        [_sheet.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [scroll.topAnchor constraintEqualToAnchor:grab.bottomAnchor constant:18],
        // At least 24 pt inside the safe area (landscape, rounded corners), as iOS's own sheets.
        [scroll.leadingAnchor constraintEqualToAnchor:_sheet.safeAreaLayoutGuide.leadingAnchor constant:24],
        [scroll.trailingAnchor constraintEqualToAnchor:_sheet.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [scroll.bottomAnchor constraintEqualToAnchor:_sheet.safeAreaLayoutGuide.bottomAnchor constant:-10],
        fitsContent,
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [ok.heightAnchor constraintGreaterThanOrEqualToConstant:50],
        [github.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];
    [self fillPage];
}

/// Puts the current page's content in the sheet, with its button.
- (void)fillPage {
    for (UIView *v in _body.arrangedSubviews) { [_body removeArrangedSubview:v]; [v removeFromSuperview]; }
    NSString *page = _pages[_page];
    NSArray<UIView *> *views = [page isEqual:@"network"] ? [self networkViews]
                             : [page isEqual:@"networkDenied"] ? [self networkDeniedViews]
                             : [page isEqual:@"notifications"] ? [self notificationViews] : [self welcomeViews];
    for (UIView *v in views) [_body addArrangedSubview:v];
    BOOL last = _page + 1 >= _pages.count;
    NSString *title = last && [page isEqual:@"welcome"] ? @"OK" : [self t:@"Continuer" en:@"Continue"];
    [_ok setTitle:title forState:UIControlStateNormal];
    _github.hidden = ![page isEqual:@"welcome"];
    _dots.currentPage = (NSInteger)_page;
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

// VoiceOver: the sheet is modal, and the two-finger scrub does what the button does.
- (BOOL)accessibilityPerformEscape {
    [self next];
    return YES;
}

/// The button (or a tap outside): the next page, or closing on the last. Going past "Réseau
/// local" is what lets XSide reach the network: iOS asks right after that page.
- (void)next {
    if (_closing || _probing) return;
    if ([_pages[_page] isEqual:@"network"]) {
        XSSetNetworkExplained();
        if (_startsNetwork) XSStartLocalNetwork();
    }
    if (_page + 1 >= _pages.count) { [self close]; return; }
    // Device feedback 3, E4: the app may have made iOS ask already (its own use of the local
    // network): checked silently first, the page then fits the answer.
    if (!_probed && [_pages[_page + 1] isEqual:@"network"]
        && XSProbesNetworkFirst(XSHasChannel(), XSChannelGranted(), XSNetworkExplained(), XSAppUsesLocalNetwork(), XSSystemAlertSeen())) {
        _probing = YES;
        _probed = YES;
        _ok.enabled = NO;
        XSProbeLocalNetwork(^(XSNetworkProbe probe) {
            self->_probing = NO;
            self->_ok.enabled = YES;
            NSString *page = XSNetworkPageAfterProbe(probe);
            NSMutableArray<NSString *> *pages = [self->_pages mutableCopy];
            if (page) pages[self->_page + 1] = page;
            else [pages removeObjectAtIndex:self->_page + 1];
            if (![page isEqual:@"network"]) XSSetNetworkExplained(); // decided: nothing left to explain
            self->_pages = pages;
            self->_dots.numberOfPages = (NSInteger)pages.count;
            [self next];
        });
        return;
    }
    _page++;
    [UIView animateWithDuration:0.15 animations:^{ self->_body.alpha = 0; } completion:^(BOOL finished) {
        [self fillPage];
        [UIView animateWithDuration:0.3 animations:^{
            self->_body.alpha = 1;
            [self.view layoutIfNeeded];
        }];
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self->_body);
    }];
}

- (void)close {
    if (_closing) return; // the button then the dimmed area: one close, one permission request
    _closing = YES;
    [UIView animateWithDuration:0.25 animations:^{
        self->_sheet.transform = CGAffineTransformMakeTranslation(0, self->_sheet.bounds.size.height + 40);
        self->_dim.alpha = 0;
    } completion:^(BOOL finished) {
        XSHideWindow();
        // The "Notifications" page said iOS would ask: now. Without it, iOS was not to be asked.
        if (self->_expiry) XSScheduleReminder(self->_expiry, [self->_pages containsObject:@"notifications"]);
        if (self->_done) self->_done();
    }];
}

- (void)openGitHub {
    NSURL *url = [NSURL URLWithString:XSRepoURL];
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
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
    title.font = XSScaledFont(17, UIFontWeightBold);
    title.adjustsFontForContentSizeCategory = YES;
    title.numberOfLines = 0;
    UILabel *subtitle = [UILabel new];
    NSString *until = [NSString stringWithFormat:fr ? @"Valable jusqu'au %@" : @"Valid until %@", XSDate(_expiry)];
    subtitle.text = updated
        ? [NSString stringWithFormat:fr ? @"Version %@ (avant : %@)\n%@" : @"Version %@ (was %@)\n%@", version, _previousVersion, until]
        : until;
    subtitle.font = XSScaledFont(14, UIFontWeightRegular);
    subtitle.adjustsFontForContentSizeCategory = YES;
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
    ok.titleLabel.font = XSScaledFont(16, UIFontWeightSemibold);
    ok.titleLabel.adjustsFontForContentSizeCategory = YES;
    [ok addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[head, ok]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;

    for (UIView *v in @[holder, card, stack]) v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:holder];
    [holder addSubview:card];
    [card.contentView addSubview:stack];
    // Capped on iPad; never wider than the screen (see the sheet: device feedback round 2, P5).
    NSLayoutConstraint *wide = [holder.widthAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor constant:-24];
    wide.priority = UILayoutPriorityRequired - 1;
    [title setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [subtitle setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [holder.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [holder.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [holder.widthAnchor constraintLessThanOrEqualToConstant:460],
        [holder.widthAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor constant:-24],
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

static void XSMarkAnnounced(NSDate *expiry) {
    [NSUserDefaults.standardUserDefaults setObject:expiry forKey:XSAnnouncedKey];
    NSString *version = XSAppVersion();
    if (version) [NSUserDefaults.standardUserDefaults setObject:version forKey:XSAnnouncedVersionKey];
}

/// The refresh/update card. `previousVersion`: set when that install was another version of the
/// app (an update).
static void XSShowBanner(NSDate *expiry, NSString *previousVersion, int attempt) {
    UIWindowScene *scene = XSScene();
    if (!scene) {
        if (attempt + 1 >= XSMaxAttempts) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XSShowBanner(expiry, previousVersion, attempt + 1);
        });
        return;
    }
    if (XSWindow) return;
    // Never key: the app keeps its keyboard and focus.
    UIWindow *window = [[XSPassthroughWindow alloc] initWithWindowScene:scene];
    window.rootViewController = [[XSBannerController alloc] initWithExpiry:expiry previousVersion:previousVersion];
    window.windowLevel = UIWindowLevelAlert + 100;
    window.backgroundColor = UIColor.clearColor;
    XSWindow = window;
    window.hidden = NO;
    // Announced once shown: a relaunch before tapping OK doesn't show it again.
    XSMarkAnnounced(expiry);
}

// MARK: - Nothing iOS asks for over the sheet, nor before its page (device feedback round 1, B1)

/// The first-launch sheet (or the stand-alone network page) is decided or on screen.
static BOOL XSSheetUp;
static NSMutableArray<void (^)(void)> *XSAfterSheetBlocks;

static void XSSheetEnded(void) {
    XSSheetUp = NO;
    NSArray<void (^)(void)> *blocks = XSAfterSheetBlocks;
    XSAfterSheetBlocks = nil;
    for (void (^block)(void) in blocks) block();
}

void XSAfterSheet(void (^block)(void)) {
    if (!XSSheetUp) { block(); return; }
    if (!XSAfterSheetBlocks) XSAfterSheetBlocks = [NSMutableArray array];
    [XSAfterSheetBlocks addObject:[block copy]];
}

/// The sheet with `pages` (XSSheetPages); `expiry` nil for the stand-alone network page. Ends the
/// sheet (XSSheetEnded) once closed, after `done`, or when no scene came.
static void XSShowSheet(NSDate *expiry, NSArray<NSString *> *pages, BOOL startsNetwork, void (^done)(void),
                        void (^dropped)(void), int attempt) {
    UIWindowScene *scene = XSScene();
    if (!scene) {
        if (attempt + 1 >= XSMaxAttempts) {
            // Never shown: what waited for it goes ahead, except a network access that was waiting
            // for the "Réseau local" page (device feedback round 2, P4: it used to run anyway, so
            // iOS asked with no page before). It is dropped, and told so (`dropped`: a Refresh
            // then stops waiting, mega review D4); the next access shows the page.
            if (done && ![pages containsObject:@"network"]) done();
            else if (done) {
                NSLog(@"XSide: local network: no screen for its page, access dropped");
                if (dropped) dropped();
            }
            XSSheetEnded();
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XSShowSheet(expiry, pages, startsNetwork, done, dropped, attempt + 1);
        });
        return;
    }
    if (XSWindow) XSHideWindow(); // the refresh card: the page that must be read wins
    for (UIWindow *w in scene.windows) if (w.isKeyWindow) XSPreviousKey = w;
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    // Hidden at first: the sheet slides up once on screen (see viewDidAppear).
    window.rootViewController = [[XSWelcomeController alloc] initWithExpiry:expiry pages:pages startsNetwork:startsNetwork done:^{
        if (done) done();
        XSSheetEnded();
    }];
    window.windowLevel = UIWindowLevelAlert + 100;
    window.backgroundColor = UIColor.clearColor;
    XSWindow = window;
    [window makeKeyAndVisible];
    // Announced once shown: a relaunch before the last page doesn't show it again.
    if (expiry) XSMarkAnnounced(expiry);
}

/// The first-launch sheet: its pages depend on whether iOS will be asked for notifications.
static void XSShowFirstSheet(NSDate *expiry) {
    XSSheetUp = YES; // from now: what would ask iOS for something waits for the sheet
    BOOL wantsReminder = XSSchedulesReminder(XSCurrentSettings());
    [XSCenter() getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        BOOL ask = wantsReminder && settings.authorizationStatus == UNAuthorizationStatusNotDetermined;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *pages = XSSheetPages(XSHasChannel(), XSChannelGranted(), XSNetworkExplained(), ask);
            XSShowSheet(expiry, pages, YES, nil, nil, 0);
        });
    }];
}

void XSExplainNetworkThen(void (^block)(void)) { XSExplainNetworkThenOr(block, nil); }

void XSExplainNetworkThenOr(void (^block)(void), void (^dropped)(void)) {
    XSAfterSheet(^{
        if (!XSNeedsNetworkExplanation(XSHasChannel(), XSChannelGranted(), XSNetworkExplained())) {
            block();
            return;
        }
        // Device feedback 3, E4: iOS may already have asked for the app itself: checked silently.
        if (XSProbesNetworkFirst(XSHasChannel(), XSChannelGranted(), XSNetworkExplained(), XSAppUsesLocalNetwork(), XSSystemAlertSeen())) {
            XSSheetUp = YES;
            XSProbeLocalNetwork(^(XSNetworkProbe probe) {
                NSString *page = XSNetworkPageAfterProbe(probe);
                NSLog(@"XSide: local network: checked before its page: %ld, page %@", (long)probe, page ?: @"none");
                if (!page) {
                    XSSetNetworkExplained();
                    XSSheetEnded();
                    block();
                    return;
                }
                if ([page isEqual:@"networkDenied"]) XSSetNetworkExplained();
                XSShowSheet(nil, @[page], NO, block, dropped, 0);
            });
            return;
        }
        // The first network access after the first-launch sheet (an app installed before 1.1, or a
        // sheet left before its page): the "Réseau local" page on its own, then the access.
        NSLog(@"XSide: local network: its page first, then XSide's first access");
        XSSheetUp = YES;
        XSShowSheet(nil, @[@"network"], NO, block, dropped, 0);
    });
}

/// XSide's logo as a notification thumbnail. iOS moves the file into its own store, so a fresh
/// copy is written each time. Nil without the logo or when the file can't be written.
static UNNotificationAttachment *XSLogoAttachment(void) {
    NSData *png = XSIconPNG();
    if (!png) return nil;
    NSString *name = [NSString stringWithFormat:@"xside-logo-%@.png", NSUUID.UUID.UUIDString];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    if (![png writeToURL:url atomically:YES]) return nil;
    return [UNNotificationAttachment attachmentWithIdentifier:@"xside-logo" URL:url options:nil error:NULL];
}

/// A local reminder 24 h before expiry, replaced at each launch (so a refresh followed by a
/// launch moves it), when the app may notify. `askIfNeeded`: the app never asked for that
/// permission, so it's asked now (once: iOS never asks again after an answer).
void XSScheduleReminder(NSDate *expiry, BOOL askIfNeeded) {
#ifdef XS_TEST_REMINDER
    NSTimeInterval wait = 60; // test build (XSIDE_TEST_REMINDER=1 scripts/bundle.sh): a minute after launch
#else
    NSTimeInterval wait = [expiry timeIntervalSinceNow] - XSReminderLead();
#endif
    UNUserNotificationCenter *center = XSCenter();
    if (wait < 60 || !XSSchedulesReminder(XSCurrentSettings())) {
        [center removePendingNotificationRequestsWithIdentifiers:@[XSReminderID]];
        return;
    }
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        UNAuthorizationStatus status = settings.authorizationStatus;
        NSLog(@"XSide: notifications: status %ld, ask %d, reminder in %.0f s", (long)status, askIfNeeded, wait);
        if (status == UNAuthorizationStatusNotDetermined && askIfNeeded) {
            [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                                  completionHandler:^(BOOL granted, NSError *error) {
                NSLog(@"XSide: notifications: asked, granted %d, error %@", granted, error);
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
                 withCompletionHandler:^(NSError *error) { NSLog(@"XSide: reminder scheduled, error %@", error); }];
    }];
}

// MARK: - Each launch

/// The launch pill, or the one pill of news when there is some (device feedback round 2, P1/P2):
/// news (a change, from the Mac or sent to it) replaces the plain validity line, which says nothing
/// urgent; an urgent launch pill (late, paused and close to expiry, a failed Refresh) shows first
/// and the news after it.
static void XSShowLaunchPill(NSDate *expiry, XSPillContent *news) {
    XSPillContent *content = XSLaunchPillContent(expiry);
    BOOL urgent = content && (content.tone != XSPillToneNeutral || content.answer);
    if (news && !urgent) { XSShowPill(news); return; }
    if (content) XSShowPill(content);
    if (news) XSShowPillWhenFree(news);
    else if (!content) XSOfferNotificationsIfNeeded(^{});
}

/// What this cold launch shows: the sheet or the card for a new signature (when the settings
/// allow it), else the pill; never both (spec §1).
static void XSLaunch(void) {
    XSLoadSettings(); // what the person changed in iOS Settings applies from this launch on
    XSRemoveLeftoverShortcuts(); // XSide's are static now (device feedback 3, E1)
    BOOL tellAutoRefresh = XSTakeAutoRefreshChangedOnPhone();
    NSArray<NSString *> *sendFields = XSTakeSettingsChangedOnPhone();
    // Asked from iOS Settings: the same as the Refresh quick action, once the app is on screen
    // (its pills replace the launch pill). After this launch decided on the sheet: it waits for it.
    if (XSTakeRefreshOnLaunch()) dispatch_async(dispatch_get_main_queue(), ^{ XSWhenForeground(1.0, ^{ XSRequestRefresh(); }); });
    NSDate *expiry = XSExpirationDate();
    if (!expiry) return;
    XSNoteSignature(expiry);
    XSWriteStatusRows(expiry);
    XSScheduleReminder(expiry, NO); // asked only after the sheet's "Notifications" page
    NSDictionary *settings = XSCurrentSettings();

    id announced = [NSUserDefaults.standardUserDefaults objectForKey:XSAnnouncedKey];
    // Known since 1.0.6: before, an update reads as a refresh. "21.37.04" and "21.37.4" are the same.
    id seen = [NSUserDefaults.standardUserDefaults objectForKey:XSAnnouncedVersionKey];
    NSString *version = XSAppVersion();
    NSString *previous = [seen isKindOfClass:NSString.class] && version
        && [version compare:seen options:NSNumericSearch] != NSOrderedSame ? seen : nil;
    // New: another signature, or another version (a new version with the same profile still shows).
    BOOL isNew = !([announced isKindOfClass:NSDate.class] && [announced isEqualToDate:expiry] && !previous);
    BOOL refreshed = [announced isKindOfClass:NSDate.class];
    if (isNew && (refreshed ? XSShowsRefreshCard(settings) : XSShowsInstallSheet(settings))) {
        if (refreshed) XSShowBanner(expiry, previous, 0);
        else XSShowFirstSheet(expiry);
        // Off the launch's way; silent, and only once the local network was allowed. Automatic
        // refresh changed in iOS Settings: told now, patiently (the Mac must act on it).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (tellAutoRefresh) XSWhenForeground(0, ^{ XSTellAutoRefreshChange(); });
            else if (sendFields) XSAfterSheet(^{ XSSendSettings(sendFields, ^(XSPillContent *result) { if (result) XSShowPillWhenFree(result); }); });
            else XSCheckIn(^(XSPillContent *news) { if (news) XSShowPillWhenFree(news); });
        });
        return;
    }
    // Turned off: counted as announced all the same, so it doesn't come back later.
    if (isNew) XSMarkAnnounced(expiry);
    if (tellAutoRefresh) {
        // The change's own pill says it (device feedback round 2, P1): the launch pill only when
        // urgent, not a second "automatic refresh off" line.
        XSPillContent *content = XSLaunchPillContent(expiry);
        if (content && (content.tone != XSPillToneNeutral || content.answer)) XSShowPill(content);
        XSWhenForeground(0, ^{ XSTellAutoRefreshChange(); });
        return;
    }
    if (sendFields) {
        // Sent first (≤ 5 s), then one pill: the send's, or the launch pill when nothing was sent.
        XSSendSettings(sendFields, ^(XSPillContent *result) { XSShowLaunchPill(expiry, result); });
        return;
    }
    // XSide is asked first (≤ 3 s, once the local network was allowed), so the pill tells how
    // things stand now: a change made on the Mac meanwhile (one pill saying which), how a Refresh
    // asked from here went, the pause as it is now (device feedback round 2, P2: the pill used to
    // say "automatic refresh off" just before the check-in turned it back on).
    if (XSChannelGranted() && XSHasChannel()) {
        XSCheckIn(^(XSPillContent *news) { XSShowLaunchPill(expiry, news); });
        return;
    }
    XSShowLaunchPill(expiry, nil);
}

/// Back from the background (not a launch: no validity pill): changes made meanwhile in iOS
/// Settings apply now, and XSide hears of them when it can be reached. XSide is asked even when
/// nothing changed here: a change made on the Mac meanwhile (e.g. automatic refresh turned back on
/// from the panel) must reach an app that was only in the background, not only a cold launch
/// (device feedback 2026-11-08). Not again within a few seconds of the last check-in.
static void XSReturn(void) {
    // Coming back from iOS Settings right after turning it on is the usual way to use it.
    if (XSTakeRefreshOnLaunch()) XSWhenForeground(0.5, ^{ XSRequestRefresh(); });
    BOOL changed = XSLoadSettings();
    // The answer to a Refresh that came while the person was away (final review minor 6).
    XSWhenForeground(0.3, ^{ XSShowKeptAnswer(); });
    if (changed) {
        NSDate *expiry = XSExpirationDate();
        if (expiry) XSScheduleReminder(expiry, NO);
    }
    // A refresh asked from here that failed or went unheard while the app was away: said now,
    // after asking XSide how it went.
    BOOL pending = XSPendingFailure() != nil;
    NSArray<NSString *> *sendFields = XSTakeSettingsChangedOnPhone();
    if (XSTakeAutoRefreshChangedOnPhone()) {
        XSWhenForeground(0.5, ^{ XSTellAutoRefreshChange(); });
        return;
    }
    if (sendFields && XSChannelGranted()) {
        XSWhenForeground(0.5, ^{ XSAfterSheet(^{
            XSSendSettings(sendFields, ^(XSPillContent *result) {
                if (pending) XSShowPendingPill();
                if (result) XSShowPillWhenFree(result);
            });
        }); });
        return;
    }
    if (!XSShouldCheckInOnReturn(changed, pending, XSLastCheckIn(), NSDate.date)) return;
    XSCheckIn(^(XSPillContent *news) {
        if (changed || pending) XSShowPendingPill();
        if (news) XSShowPillWhenFree(news);
    });
}

/// Seconds after its launch an app still in the background was launched there (see the run marker).
static const NSTimeInterval XSBackgroundLaunchCheck = 3;

__attribute__((constructor)) static void XSideWelcomeInit(void) {
    // How the previous run ended, then this one marked running (off the main thread).
    XSRunMarkerLaunched();
    XSNoteStartDefaultsDate(); // before the app writes its own preferences at launch
    XSInstallShortcuts(); // before UIApplicationMain sets the app's delegates
    XSWatchSystemAlerts();
    __block id observer = nil;
    observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                               object:nil queue:NSOperationQueue.mainQueue
                                                           usingBlock:^(NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        observer = nil;
        XSLaunch();
        // In front: XSide is asked every few seconds; not while away (device feedback round 2, P3).
        XSStartForegroundUpdates();
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *n) { XSStartForegroundUpdates(); }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *n) { XSStopForegroundUpdates(); }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *n) { XSReturn(); }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *n) { XSNoteLeaving(); }];
    }];
    // The run marker: in front, or left cleanly (a kill in the background is no crash of interest).
    // A launch in the background (a silent push, a fetch...) was marked running by the constructor:
    // still in the background a moment after its launch, it is clean, so a later kill there isn't
    // reported as a crash (mega review D3). Not at once: with scenes, the app reads as in the
    // background during its launch even when it opens in front; a crash in those first seconds
    // stays reported.
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(XSBackgroundLaunchCheck * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) return;
            NSLog(@"XSide: run marker: launched in the background, clean");
            XSRunMarkerInFront(NO, NO);
        });
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { XSRunMarkerInFront(YES, NO); }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { XSRunMarkerInFront(YES, NO); }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { XSRunMarkerInFront(NO, NO); }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillTerminateNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { XSRunMarkerInFront(NO, YES); }];
}
