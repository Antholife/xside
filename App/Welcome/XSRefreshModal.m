// See XSRefreshModal.h. A full-screen, system-themed modal driven by a tiny C API. Built with
// UIKit + CoreAnimation; degrades to nothing when there is no scene. Never blocks or crashes.

#import "XSRefreshModal.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - Controller

@interface XSRefreshModalController : UIViewController
@property (nonatomic) BOOL willBackUp;
@property (nonatomic, copy, nullable) void (^retry)(void);
@end

@implementation XSRefreshModalController {
    // hero
    UIView *_macNode, *_iphNode, *_link;
    CAShapeLayer *_baseLine;
    NSArray<CALayer *> *_dots; // 0,1 forward (violet) ; 2,3 backward (pink)
    UIView *_macBadge; UILabel *_macBadgeMark;
    // ring
    UIView *_ringBox; CAShapeLayer *_ringTrack, *_ringMask; CAGradientLayer *_ringFill;
    UIActivityIndicatorView *_spinner; CAShapeLayer *_mark; // check / cross
    // text
    UILabel *_title, *_lead, *_stepTitle, *_stepSub;
    UIStackView *_acts;
    double _fraction;
}

static CGFloat const kRing = 150, kRingW = 8, kNode = 54, kLink = 118;

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    BOOL fr = XSFrench();

    UILabel *kicker = [UILabel new];
    kicker.text = @"XSIDE"; kicker.font = XSScaledFont(11, UIFontWeightHeavy);
    kicker.textColor = XSViolet(); kicker.textAlignment = NSTextAlignmentCenter;

    _title = [UILabel new];
    _title.text = fr ? @"Tu as demandé un rafraîchissement" : @"You asked for a refresh";
    _title.font = XSScaledFont(20, UIFontWeightBold); _title.numberOfLines = 0;
    _title.textAlignment = NSTextAlignmentCenter; _title.adjustsFontForContentSizeCategory = YES;

    _lead = [UILabel new];
    _lead.text = fr ? @"Ton Mac s’en occupe" : @"Your Mac is on it";
    _lead.font = XSScaledFont(13, UIFontWeightRegular); _lead.textColor = UIColor.secondaryLabelColor;
    _lead.textAlignment = NSTextAlignmentCenter; _lead.numberOfLines = 0;

    UIView *hero = [self buildHero];
    _ringBox = [self buildRing];

    _stepTitle = [UILabel new];
    _stepTitle.font = XSScaledFont(16, UIFontWeightSemibold); _stepTitle.textAlignment = NSTextAlignmentCenter;
    _stepTitle.numberOfLines = 0; _stepTitle.text = fr ? @"Connexion à ton Mac" : @"Connecting to your Mac";
    _stepSub = [UILabel new];
    _stepSub.font = XSScaledFont(12.5, UIFontWeightRegular); _stepSub.textColor = UIColor.secondaryLabelColor;
    _stepSub.textAlignment = NSTextAlignmentCenter; _stepSub.numberOfLines = 0;
    _stepSub.text = fr ? @"Réseau local…" : @"Local network…";

    _acts = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    _acts.axis = UILayoutConstraintAxisHorizontal; _acts.spacing = 9; _acts.distribution = UIStackViewDistributionFillEqually;
    _acts.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[kicker, _title, _lead, hero, _ringBox, _stepTitle, _stepSub, _acts]];
    stack.axis = UILayoutConstraintAxisVertical; stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:6 afterView:kicker];
    [stack setCustomSpacing:2 afterView:_title];
    [stack setCustomSpacing:24 afterView:_lead];
    [stack setCustomSpacing:22 afterView:hero];
    [stack setCustomSpacing:12 afterView:_ringBox];
    [stack setCustomSpacing:2 afterView:_stepTitle];
    [stack setCustomSpacing:22 afterView:_stepSub];
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:28],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-28],
        [_acts.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
}

- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self startConnecting]; }

#pragma mark build

- (UIView *)nodeWithSymbol:(NSString *)name {
    UIView *v = [UIView new];
    v.backgroundColor = UIColor.secondarySystemBackgroundColor;
    v.layer.cornerRadius = 15; v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.borderWidth = 1; v.layer.borderColor = UIColor.separatorColor.CGColor;
    UIImageView *img = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:name withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular]]];
    img.tintColor = UIColor.labelColor; img.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:img];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [v.widthAnchor constraintEqualToConstant:kNode], [v.heightAnchor constraintEqualToConstant:kNode],
        [img.centerXAnchor constraintEqualToAnchor:v.centerXAnchor], [img.centerYAnchor constraintEqualToAnchor:v.centerYAnchor]]];
    return v;
}

- (UIView *)buildHero {
    _iphNode = [self nodeWithSymbol:@"iphone"];
    _macNode = [self nodeWithSymbol:@"laptopcomputer"];

    // badge on the Mac node (hidden until connected / error)
    _macBadge = [UIView new]; _macBadge.layer.cornerRadius = 9.5; _macBadge.hidden = YES;
    _macBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _macBadgeMark = [UILabel new]; _macBadgeMark.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    _macBadgeMark.textColor = UIColor.whiteColor; _macBadgeMark.textAlignment = NSTextAlignmentCenter;
    _macBadgeMark.translatesAutoresizingMaskIntoConstraints = NO;
    [_macBadge addSubview:_macBadgeMark];
    [_macNode addSubview:_macBadge];
    [NSLayoutConstraint activateConstraints:@[
        [_macBadge.widthAnchor constraintEqualToConstant:19], [_macBadge.heightAnchor constraintEqualToConstant:19],
        [_macBadge.trailingAnchor constraintEqualToAnchor:_macNode.trailingAnchor constant:5],
        [_macBadge.bottomAnchor constraintEqualToAnchor:_macNode.bottomAnchor constant:5],
        [_macBadgeMark.centerXAnchor constraintEqualToAnchor:_macBadge.centerXAnchor],
        [_macBadgeMark.centerYAnchor constraintEqualToAnchor:_macBadge.centerYAnchor]]];

    _link = [UIView new]; _link.translatesAutoresizingMaskIntoConstraints = NO;
    _baseLine = [CAShapeLayer layer]; _baseLine.strokeColor = UIColor.separatorColor.CGColor;
    _baseLine.lineWidth = 2; _baseLine.lineCap = kCALineCapRound;
    [_link.layer addSublayer:_baseLine];
    NSMutableArray *dots = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        CALayer *d = [CALayer layer];
        d.bounds = CGRectMake(0, 0, 7, 7); d.cornerRadius = 3.5;
        UIColor *c = i < 2 ? XSViolet() : XSPink();
        d.backgroundColor = c.CGColor; d.shadowColor = c.CGColor; d.shadowRadius = 5; d.shadowOpacity = .9; d.shadowOffset = CGSizeZero;
        d.opacity = 0; [_link.layer addSublayer:d]; [dots addObject:d];
    }
    _dots = dots;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_iphNode, _link, _macNode]];
    row.alignment = UIStackViewAlignmentCenter; row.spacing = 2;
    [NSLayoutConstraint activateConstraints:@[
        [_link.widthAnchor constraintEqualToConstant:kLink], [_link.heightAnchor constraintEqualToConstant:36]]];
    return row;
}

- (UIView *)buildRing {
    UIView *box = [UIView new];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[[box.widthAnchor constraintEqualToConstant:kRing], [box.heightAnchor constraintEqualToConstant:kRing]]];
    CGPoint ctr = CGPointMake(kRing/2, kRing/2); CGFloat r = (kRing - kRingW)/2;
    UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:ctr radius:r startAngle:-M_PI_2 endAngle:-M_PI_2 + 2*M_PI clockwise:YES];
    _ringTrack = [CAShapeLayer layer]; _ringTrack.path = circle.CGPath; _ringTrack.fillColor = nil;
    _ringTrack.strokeColor = UIColor.tertiarySystemFillColor.CGColor; _ringTrack.lineWidth = kRingW;
    [box.layer addSublayer:_ringTrack];
    _ringFill = [CAGradientLayer layer]; _ringFill.frame = CGRectMake(0, 0, kRing, kRing);
    _ringFill.colors = @[(id)XSViolet().CGColor, (id)XSPink().CGColor];
    _ringFill.startPoint = CGPointMake(0, 0); _ringFill.endPoint = CGPointMake(1, 1);
    _ringMask = [CAShapeLayer layer]; _ringMask.path = circle.CGPath; _ringMask.fillColor = nil;
    _ringMask.strokeColor = UIColor.blackColor.CGColor; _ringMask.lineWidth = kRingW; _ringMask.lineCap = kCALineCapRound;
    _ringMask.strokeEnd = 0; _ringFill.mask = _ringMask;
    [box.layer addSublayer:_ringFill];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _spinner.color = XSViolet(); _spinner.translatesAutoresizingMaskIntoConstraints = NO; [_spinner startAnimating];
    [box addSubview:_spinner];
    [NSLayoutConstraint activateConstraints:@[[_spinner.centerXAnchor constraintEqualToAnchor:box.centerXAnchor], [_spinner.centerYAnchor constraintEqualToAnchor:box.centerYAnchor]]];
    _mark = [CAShapeLayer layer]; _mark.frame = box.bounds; _mark.fillColor = nil; _mark.lineWidth = 3;
    _mark.lineCap = kCALineCapRound; _mark.lineJoin = kCALineJoinRound; _mark.strokeEnd = 0;
    [box.layer addSublayer:_mark];
    return box;
}

#pragma mark states

- (void)startConnecting {
    for (int i = 0; i < 4; i++) {
        CALayer *d = _dots[i]; BOOL fwd = i < 2;
        CGFloat y = 18; CGFloat x0 = fwd ? 3 : kLink - 3, x1 = fwd ? kLink - 3 : 3;
        CAKeyframeAnimation *op = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        op.values = @[@0, @1, @1, @0]; op.keyTimes = @[@0, @.15, @.85, @1];
        CABasicAnimation *mv = [CABasicAnimation animationWithKeyPath:@"position.x"];
        mv.fromValue = @(x0); mv.toValue = @(x1);
        CAAnimationGroup *g = [CAAnimationGroup animation];
        g.animations = @[op, mv]; g.duration = 1.2; g.repeatCount = HUGE_VALF;
        g.beginTime = CACurrentMediaTime() + (fwd ? (i*0.6) : (0.3 + (i-2)*0.6));
        d.position = CGPointMake(x1, y); [d addAnimation:g forKey:@"flow"];
    }
    [self pulseMac:YES];
}

- (void)pulseMac:(BOOL)on {
    [_macNode.layer removeAnimationForKey:@"pulse"];
    if (!on) return;
    CABasicAnimation *p = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    p.fromValue = @1; p.toValue = @1.06; p.duration = 0.65; p.autoreverses = YES; p.repeatCount = HUGE_VALF;
    [_macNode.layer addAnimation:p forKey:@"pulse"];
}

- (void)heroConnectedOk:(BOOL)ok {
    for (CALayer *d in _dots) [d removeAnimationForKey:@"flow"];
    [self pulseMac:NO];
    UIColor *c = ok ? UIColor.systemGreenColor : UIColor.systemRedColor;
    _baseLine.strokeColor = c.CGColor;
    _macNode.layer.borderColor = c.CGColor; if (ok) _iphNode.layer.borderColor = c.CGColor;
    _macBadge.backgroundColor = c; _macBadgeMark.text = ok ? @"✓" : @"✕"; _macBadge.hidden = NO;
    _macBadge.transform = CGAffineTransformMakeScale(0.3, 0.3);
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.5 options:0
                     animations:^{ self->_macBadge.transform = CGAffineTransformIdentity; } completion:nil];
}

- (void)setRing:(double)f {
    _fraction = MAX(0, MIN(1, f));
    [CATransaction begin]; [CATransaction setAnimationDuration:0.5];
    _ringMask.strokeEnd = _fraction; [CATransaction commit];
}

- (void)drawMark:(BOOL)ok {
    [_spinner stopAnimating]; _spinner.hidden = YES;
    CGPoint ctr = CGPointMake(kRing/2, kRing/2);
    UIBezierPath *p = [UIBezierPath bezierPath];
    if (ok) { [p moveToPoint:CGPointMake(ctr.x-16, ctr.y+1)]; [p addLineToPoint:CGPointMake(ctr.x-5, ctr.y+12)]; [p addLineToPoint:CGPointMake(ctr.x+17, ctr.y-13)]; }
    else { [p moveToPoint:CGPointMake(ctr.x-13, ctr.y-13)]; [p addLineToPoint:CGPointMake(ctr.x+13, ctr.y+13)];
           [p moveToPoint:CGPointMake(ctr.x+13, ctr.y-13)]; [p addLineToPoint:CGPointMake(ctr.x-13, ctr.y+13)]; }
    _mark.path = p.CGPath; _mark.strokeColor = (ok ? UIColor.systemGreenColor : UIColor.systemRedColor).CGColor;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
    a.fromValue = @0; a.toValue = @1; a.duration = 0.35; a.fillMode = kCAFillModeForwards;
    _mark.strokeEnd = 1; [_mark addAnimation:a forKey:@"draw"];
}

- (void)goWorking {
    [self heroConnectedOk:YES];
    BOOL fr = XSFrench();
    _stepTitle.text = self.willBackUp ? (fr ? @"Sauvegarde et rafraîchissement" : @"Backup and refresh")
                                      : (fr ? @"Rafraîchissement" : @"Refresh");
    _stepSub.text = fr ? @"L’app va se fermer, rouvre-la ensuite." : @"The app will close, open it again then.";
    _lead.text = @"";
    [self setRing:0.9];
}

- (void)stepTitle:(NSString *)t detail:(NSString *)d fraction:(double)f {
    if (t) _stepTitle.text = t; _stepSub.text = d ?: @"";
    if (f >= 0) { if (_spinner.isAnimating) { [_spinner stopAnimating]; _spinner.hidden = YES; } [self setRing:f]; }
}

- (void)errorTitle:(NSString *)t message:(NSString *)m {
    if (_macBadge.hidden) [self heroConnectedOk:NO]; // connection itself failed (never reached « ok »)
    _ringFill.colors = @[(id)UIColor.systemRedColor.CGColor, (id)UIColor.systemRedColor.CGColor];
    [self drawMark:NO];
    _stepTitle.text = t ?: (XSFrench() ? @"Échec" : @"Failed"); _stepSub.text = m ?: @""; _lead.text = @"";
    [self showActions];
}

- (void)showActions {
    BOOL fr = XSFrench();
    for (UIView *v in _acts.arrangedSubviews) [v removeFromSuperview];
    XSGradientButton *retry = [XSGradientButton buttonWithType:UIButtonTypeCustom];
    [retry setTitle:(fr ? @"Réessayer" : @"Try again") forState:UIControlStateNormal];
    [retry setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    retry.titleLabel.font = XSScaledFont(15, UIFontWeightSemibold);
    [retry addTarget:self action:@selector(tapRetry) forControlEvents:UIControlEventTouchUpInside];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:(fr ? @"Fermer" : @"Close") forState:UIControlStateNormal];
    close.titleLabel.font = XSScaledFont(15, UIFontWeightSemibold);
    close.tintColor = UIColor.labelColor; close.backgroundColor = UIColor.secondarySystemBackgroundColor;
    close.layer.cornerRadius = 14; close.layer.cornerCurve = kCACornerCurveContinuous;
    [close addTarget:self action:@selector(tapClose) forControlEvents:UIControlEventTouchUpInside];
    for (UIButton *b in @[retry, close]) [b.heightAnchor constraintEqualToConstant:46].active = YES;
    [_acts addArrangedSubview:retry]; [_acts addArrangedSubview:close];
    _acts.hidden = NO;
}

- (void)tapRetry { void (^r)(void) = self.retry; XSRefreshModalDismiss(); if (r) r(); }
- (void)tapClose { XSRefreshModalDismiss(); }

@end

#pragma mark - C API + window

static UIWindow *XSModalWindow;
static __weak XSRefreshModalController *XSModalVC;

static XSRefreshModalController *XSModalEnsure(BOOL willBackUp) {
    UIWindowScene *scene = XSScene();
    if (!scene) return nil;
    if (XSModalWindow) return XSModalVC;
    XSRefreshModalController *vc = [XSRefreshModalController new]; vc.willBackUp = willBackUp;
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.rootViewController = vc; w.windowLevel = UIWindowLevelAlert + 101; XSModalWindow = w; XSModalVC = vc;
    w.hidden = NO;
    return vc;
}

void XSRefreshModalShow(BOOL willBackUp) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSRefreshModalShow(willBackUp); }); return; }
    XSModalEnsure(willBackUp);
}
void XSRefreshModalWorking(void) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSRefreshModalWorking(); }); return; }
    [XSModalVC goWorking];
}
void XSRefreshModalStep(NSString *title, NSString *detail, double fraction) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSRefreshModalStep(title, detail, fraction); }); return; }
    [XSModalVC stepTitle:title detail:detail fraction:fraction];
}
void XSRefreshModalError(NSString *title, NSString *message, void (^retry)(void)) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSRefreshModalError(title, message, retry); }); return; }
    XSRefreshModalController *vc = XSModalEnsure(NO); // show it even if the request never opened it
    vc.retry = retry; [vc errorTitle:title message:message];
}
void XSRefreshModalDismiss(void) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSRefreshModalDismiss(); }); return; }
    XSModalWindow.hidden = YES; XSModalWindow = nil;
}
