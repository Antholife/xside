// See XSRefreshModal.h. A full-screen, system-themed modal driven by a tiny C API. Built with
// UIKit + CoreAnimation; degrades to nothing when there is no scene. Never blocks or crashes.

#import "XSRefreshModal.h"
#import "XSLogoPNG.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - Controller

@interface XSRefreshModalController : UIViewController
@property (nonatomic) BOOL willBackUp;
@property (nonatomic, copy, nullable) void (^retry)(void);
/// For the update flow (Slice 3): a different title/lead, and the install action of the offer state.
@property (nonatomic, copy, nullable) NSString *titleText;
@property (nonatomic, copy, nullable) NSString *leadText;
@property (nonatomic, copy, nullable) void (^offerAction)(void);
/// Set while an operation runs so « Annuler » can stop it; nil hides the button.
@property (nonatomic, copy, nullable) void (^cancelAction)(void);
- (void)applyLinkKind:(XSLinkKind)kind;
@end

@implementation XSRefreshModalController {
    // hero
    UIView *_macNode, *_iphNode, *_link;
    CALayer *_wifiLayer, *_usbLayer;        // the two link styles; one is shown
    NSArray<CAShapeLayer *> *_fans;          // 6 Wi-Fi arcs: 0-2 iPhone (violet), 3-5 Mac (pink)
    CALayer *_pulseV, *_pulseP;              // F4: the two crossing data pulses
    CAShapeLayer *_usbCable; NSArray<CALayer *> *_usbDots; NSArray<CALayer *> *_usbPlugs;
    UIView *_macBadge; UILabel *_macBadgeMark; BOOL _macOk; // _macOk tracks the badge's shown state
    UIView *_chip; UIImageView *_chipIcon; UILabel *_chipText;
    XSLinkKind _linkKind;
    BOOL _connecting;
    // ring
    UIView *_ringBox; CAShapeLayer *_ringTrack, *_ringMask; CAGradientLayer *_ringFill;
    UIActivityIndicatorView *_spinner; CAShapeLayer *_mark; // check / cross
    // text
    UILabel *_title, *_lead, *_stepTitle, *_stepSub, *_pct; // _pct: the big % in the ring's centre
    UIStackView *_acts;
    UIButton *_cancelBtn; // « Annuler » during the working phase
    double _fraction;
}

static CGFloat const kRing = 150, kRingW = 8, kNode = 54, kLink = 118, kLinkH = 54;
static XSLinkKind XSLinkCurrent = XSLinkUnknown; // the transport the last channel connection used

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    BOOL fr = XSFrench();

    UIView *logo = [self buildLogo];

    UILabel *kicker = [UILabel new];
    kicker.text = @"XSIDE"; kicker.font = XSScaledFont(11, UIFontWeightHeavy);
    kicker.textColor = XSViolet(); kicker.textAlignment = NSTextAlignmentCenter;

    _title = [UILabel new];
    _title.text = self.titleText ?: (fr ? @"Tu as demandé un rafraîchissement" : @"You asked for a refresh");
    _title.font = XSScaledFont(20, UIFontWeightBold); _title.numberOfLines = 0;
    _title.textAlignment = NSTextAlignmentCenter; _title.adjustsFontForContentSizeCategory = YES;

    _lead = [UILabel new];
    _lead.text = self.leadText ?: (fr ? @"Ton Mac s’en occupe" : @"Your Mac is on it");
    _lead.font = XSScaledFont(13, UIFontWeightRegular); _lead.textColor = UIColor.secondaryLabelColor;
    _lead.textAlignment = NSTextAlignmentCenter; _lead.numberOfLines = 0;

    UIView *hero = [self buildHero];
    UIView *chip = [self buildChip];
    _ringBox = [self buildRing];

    _stepTitle = [UILabel new];
    _stepTitle.font = XSScaledFont(16, UIFontWeightSemibold); _stepTitle.textAlignment = NSTextAlignmentCenter;
    _stepTitle.numberOfLines = 0; _stepTitle.text = fr ? @"Connexion à ton Mac" : @"Connecting to your Mac";
    _stepSub = [UILabel new];
    _stepSub.font = XSScaledFont(12.5, UIFontWeightRegular); _stepSub.textColor = UIColor.secondaryLabelColor;
    _stepSub.textAlignment = NSTextAlignmentCenter; _stepSub.numberOfLines = 0;
    _stepSub.text = fr ? @"Réseau local…" : @"Local network…";

    // The work spinner now lives under the step texts (Anthony: « le spinner en bas »); the ring's
    // centre shows the big % instead.
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.color = XSViolet(); [_spinner startAnimating];

    _acts = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    _acts.axis = UILayoutConstraintAxisHorizontal; _acts.spacing = 9; _acts.distribution = UIStackViewDistributionFillEqually;
    _acts.hidden = YES;

    // « Annuler » during the working phase (hidden otherwise); the exchange sets cancelAction.
    _cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_cancelBtn setTitle:(fr ? @"Annuler" : @"Cancel") forState:UIControlStateNormal];
    _cancelBtn.titleLabel.font = XSScaledFont(15, UIFontWeightSemibold);
    _cancelBtn.tintColor = UIColor.secondaryLabelColor;
    [_cancelBtn addTarget:self action:@selector(tapCancel) forControlEvents:UIControlEventTouchUpInside];
    _cancelBtn.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[logo, kicker, _title, _lead, hero, chip, _ringBox, _stepTitle, _stepSub, _spinner, _cancelBtn, _acts]];
    stack.axis = UILayoutConstraintAxisVertical; stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:9 afterView:logo];
    [stack setCustomSpacing:6 afterView:kicker];
    [stack setCustomSpacing:2 afterView:_title];
    [stack setCustomSpacing:22 afterView:_lead];
    [stack setCustomSpacing:14 afterView:hero];
    [stack setCustomSpacing:18 afterView:chip];
    [stack setCustomSpacing:12 afterView:_ringBox];
    [stack setCustomSpacing:2 afterView:_stepTitle];
    [stack setCustomSpacing:16 afterView:_stepSub];
    [stack setCustomSpacing:14 afterView:_spinner];
    [stack setCustomSpacing:22 afterView:_cancelBtn];
    [self.view addSubview:stack];
    // Centred column, capped so it doesn't stretch edge to edge on a wide screen (iPhone Duo:
    // Anthony « c'est pas centré, ça prend toute la width »). On a normal phone the safe-area cap
    // wins (full width minus margins); on a wide screen the 460 cap wins and it stays centred.
    NSLayoutConstraint *wide = [stack.widthAnchor constraintEqualToConstant:460];
    wide.priority = UILayoutPriorityDefaultHigh; // grow to 460 when there's room, but never past the margins
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor constant:-56],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:460],
        wide,
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

/// The real XSide app icon (the one in the README), embedded as a PNG so the injected dylib can show
/// it without a bundled resource. Its rounded-square shape is already baked into the image.
- (UIView *)buildLogo {
    CGFloat S = 46;
    UIView *box = [UIView new]; box.translatesAutoresizingMaskIntoConstraints = NO;
    box.layer.shadowColor = XSViolet().CGColor; box.layer.shadowRadius = 10; box.layer.shadowOpacity = 0.3; box.layer.shadowOffset = CGSizeMake(0, 4);
    UIImageView *v = [UIImageView new]; v.translatesAutoresizingMaskIntoConstraints = NO;
    v.contentMode = UIViewContentModeScaleAspectFit;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:XSLogoBase64 options:0];
    v.image = [UIImage imageWithData:data scale:UIScreen.mainScreen.scale];
    v.layer.cornerRadius = S * 0.225; v.layer.cornerCurve = kCACornerCurveContinuous; v.layer.masksToBounds = YES;
    [box addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [box.widthAnchor constraintEqualToConstant:S], [box.heightAnchor constraintEqualToConstant:S],
        [v.topAnchor constraintEqualToAnchor:box.topAnchor], [v.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
        [v.leadingAnchor constraintEqualToAnchor:box.leadingAnchor], [v.trailingAnchor constraintEqualToAnchor:box.trailingAnchor]]];
    return box;
}

- (UIView *)buildHero {
    _iphNode = [self nodeWithSymbol:@"iphone"];
    _macNode = [self nodeWithSymbol:@"laptopcomputer"];

    // badge for the Mac node (hidden until connected / error). It is NOT a subview of the node: a
    // view's layer border draws above its subviews, so the node's own border line showed through the
    // ✓ (Anthony: « on voit la bordure du cadre dans le check »). Added to the hero row below, above
    // the node, so nothing of the node renders over it. A background-colour ring sets it off.
    _macBadge = [UIView new]; _macBadge.layer.cornerRadius = 9.5; _macBadge.hidden = YES;
    _macBadge.layer.borderWidth = 2; _macBadge.layer.borderColor = UIColor.systemBackgroundColor.CGColor;
    _macBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _macBadgeMark = [UILabel new]; _macBadgeMark.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    _macBadgeMark.textColor = UIColor.whiteColor; _macBadgeMark.textAlignment = NSTextAlignmentCenter;
    _macBadgeMark.translatesAutoresizingMaskIntoConstraints = NO;
    [_macBadge addSubview:_macBadgeMark];

    _link = [UIView new]; _link.translatesAutoresizingMaskIntoConstraints = NO;
    _wifiLayer = [CALayer layer]; _wifiLayer.frame = CGRectMake(0, 0, kLink, kLinkH); [_link.layer addSublayer:_wifiLayer];
    _usbLayer = [CALayer layer]; _usbLayer.frame = CGRectMake(0, 0, kLink, kLinkH); _usbLayer.hidden = YES; [_link.layer addSublayer:_usbLayer];
    [self buildWifiArt]; [self buildUSBArt];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_iphNode, _link, _macNode]];
    row.alignment = UIStackViewAlignmentCenter; row.spacing = 2;
    [row addSubview:_macBadge]; // a plain subview, above the arranged _macNode, so the node border never crosses it
    [NSLayoutConstraint activateConstraints:@[
        [_link.widthAnchor constraintEqualToConstant:kLink], [_link.heightAnchor constraintEqualToConstant:kLinkH],
        [_macBadge.widthAnchor constraintEqualToConstant:19], [_macBadge.heightAnchor constraintEqualToConstant:19],
        [_macBadge.trailingAnchor constraintEqualToAnchor:_macNode.trailingAnchor constant:5],
        [_macBadge.bottomAnchor constraintEqualToAnchor:_macNode.bottomAnchor constant:5],
        [_macBadgeMark.centerXAnchor constraintEqualToAnchor:_macBadge.centerXAnchor],
        [_macBadgeMark.centerYAnchor constraintEqualToAnchor:_macBadge.centerYAnchor]]];
    return row;
}

/// Two small Wi-Fi fans hugging each node (violet on the iPhone, pink on the Mac) and two data
/// pulses that cross in the gap (F4): the transport, as a Wi-Fi signal.
- (void)buildWifiArt {
    CGFloat cy = kLinkH / 2;
    NSMutableArray *fans = [NSMutableArray array];
    CGFloat centers[2] = {8, kLink - 8};
    for (int side = 0; side < 2; side++) {
        CGFloat ox = centers[side];
        UIColor *c = side == 0 ? XSViolet() : XSPink();
        CGFloat a0 = side == 0 ? -50 : 130, a1 = side == 0 ? 50 : 230; // degrees, fan points inward
        CALayer *dot = [CALayer layer]; dot.bounds = CGRectMake(0, 0, 5, 5); dot.cornerRadius = 2.5;
        dot.position = CGPointMake(ox, cy); dot.backgroundColor = c.CGColor; [_wifiLayer addSublayer:dot];
        CGFloat radii[3] = {8, 13, 18};
        for (int i = 0; i < 3; i++) {
            CAShapeLayer *arc = [CAShapeLayer layer];
            arc.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(ox, cy) radius:radii[i]
                                                  startAngle:a0 * M_PI / 180 endAngle:a1 * M_PI / 180 clockwise:YES].CGPath;
            arc.fillColor = nil; arc.strokeColor = c.CGColor; arc.lineWidth = 2.6; arc.lineCap = kCALineCapRound; arc.opacity = 0.16;
            [_wifiLayer addSublayer:arc]; [fans addObject:arc];
        }
    }
    _fans = fans;
    _pulseV = [self pulseDot:XSViolet() at:CGPointMake(30, cy)];
    _pulseP = [self pulseDot:XSPink() at:CGPointMake(kLink - 30, cy)];
    [_wifiLayer addSublayer:_pulseV]; [_wifiLayer addSublayer:_pulseP];
}

- (CALayer *)pulseDot:(UIColor *)c at:(CGPoint)p {
    CALayer *d = [CALayer layer]; d.bounds = CGRectMake(0, 0, 8, 8); d.cornerRadius = 4;
    d.backgroundColor = c.CGColor; d.shadowColor = c.CGColor; d.shadowRadius = 5; d.shadowOpacity = .9; d.shadowOffset = CGSizeZero;
    d.position = p; d.opacity = 0; return d;
}

/// A cable with a USB-C connector at each end, and data flowing through it.
- (void)buildUSBArt {
    CGFloat cy = kLinkH / 2;
    UIColor *wire = UIColor.tertiaryLabelColor;
    _usbCable = [CAShapeLayer layer];
    UIBezierPath *cp = [UIBezierPath bezierPath]; [cp moveToPoint:CGPointMake(24, cy)]; [cp addLineToPoint:CGPointMake(kLink - 24, cy)];
    _usbCable.path = cp.CGPath; _usbCable.strokeColor = wire.CGColor; _usbCable.lineWidth = 4; _usbCable.lineCap = kCALineCapRound; [_usbLayer addSublayer:_usbCable];
    NSMutableArray *plugs = [NSMutableArray array];
    CGFloat px[2] = {2, kLink - 24};
    for (int i = 0; i < 2; i++) {
        CALayer *plug = [CALayer layer]; plug.frame = CGRectMake(px[i], cy - 7, 22, 14);
        plug.cornerRadius = 7; plug.cornerCurve = kCACornerCurveContinuous; plug.backgroundColor = wire.CGColor;
        plug.shadowColor = (i == 0 ? XSViolet() : XSPink()).CGColor; plug.shadowRadius = 6; plug.shadowOffset = CGSizeZero; plug.shadowOpacity = 0;
        CALayer *slot = [CALayer layer]; slot.frame = CGRectMake(4, 3, 14, 8); slot.cornerRadius = 3;
        slot.backgroundColor = UIColor.systemBackgroundColor.CGColor; [plug addSublayer:slot];
        [_usbLayer addSublayer:plug]; [plugs addObject:plug];
    }
    _usbPlugs = plugs;
    CALayer *fwd = [self pulseDot:XSViolet() at:CGPointMake(28, cy)]; fwd.bounds = CGRectMake(0, 0, 7, 7); fwd.cornerRadius = 3.5;
    CALayer *bwd = [self pulseDot:XSPink() at:CGPointMake(kLink - 28, cy)]; bwd.bounds = CGRectMake(0, 0, 7, 7); bwd.cornerRadius = 3.5;
    [_usbLayer addSublayer:fwd]; [_usbLayer addSublayer:bwd];
    _usbDots = @[fwd, bwd];
}

- (UIView *)buildChip {
    _chip = [UIView new]; _chip.translatesAutoresizingMaskIntoConstraints = NO; _chip.hidden = YES;
    _chip.backgroundColor = UIColor.secondarySystemBackgroundColor;
    _chip.layer.cornerRadius = 12; _chip.layer.cornerCurve = kCACornerCurveContinuous;
    _chipIcon = [UIImageView new]; _chipIcon.translatesAutoresizingMaskIntoConstraints = NO; _chipIcon.contentMode = UIViewContentModeScaleAspectFit;
    _chipText = [UILabel new]; _chipText.translatesAutoresizingMaskIntoConstraints = NO;
    _chipText.font = XSScaledFont(12.5, UIFontWeightSemibold);
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[_chipIcon, _chipText]];
    s.spacing = 5; s.alignment = UIStackViewAlignmentCenter; s.translatesAutoresizingMaskIntoConstraints = NO;
    [_chip addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.leadingAnchor constraintEqualToAnchor:_chip.leadingAnchor constant:11], [s.trailingAnchor constraintEqualToAnchor:_chip.trailingAnchor constant:-11],
        [s.topAnchor constraintEqualToAnchor:_chip.topAnchor constant:5], [s.bottomAnchor constraintEqualToAnchor:_chip.bottomAnchor constant:-5],
        [_chipIcon.widthAnchor constraintEqualToConstant:15], [_chipIcon.heightAnchor constraintEqualToConstant:15]]];
    return _chip;
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

    _pct = [UILabel new]; _pct.translatesAutoresizingMaskIntoConstraints = NO;
    _pct.font = [UIFont monospacedDigitSystemFontOfSize:40 weight:UIFontWeightBold];
    _pct.textColor = UIColor.labelColor; _pct.textAlignment = NSTextAlignmentCenter; _pct.hidden = YES;
    [box addSubview:_pct];
    [NSLayoutConstraint activateConstraints:@[[_pct.centerXAnchor constraintEqualToAnchor:box.centerXAnchor], [_pct.centerYAnchor constraintEqualToAnchor:box.centerYAnchor]]];
    _mark = [CAShapeLayer layer]; _mark.frame = box.bounds; _mark.fillColor = nil; _mark.lineWidth = 3;
    _mark.lineCap = kCALineCapRound; _mark.lineJoin = kCALineJoinRound; _mark.strokeEnd = 0;
    [box.layer addSublayer:_mark];
    return box;
}

#pragma mark states

- (void)startConnecting {
    _connecting = YES;
    [self applyLinkKind:XSLinkCurrent];
    [self pulseMac:YES];
}

/// Switch the hero's link to the transport in use (Wi-Fi arcs or a USB-C cable) and relabel the chip.
- (void)applyLinkKind:(XSLinkKind)k {
    _linkKind = k;
    BOOL usb = (k == XSLinkUSB);
    _usbLayer.hidden = !usb; _wifiLayer.hidden = usb;
    NSString *sym = usb ? @"cable.connector" : @"wifi";
    _chipIcon.image = [UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]];
    _chipIcon.tintColor = usb ? XSPink() : XSViolet();
    _chipText.text = usb ? @"USB" : @"Wi-Fi"; _chipText.textColor = usb ? XSPink() : XSViolet();
    _chip.hidden = (k == XSLinkUnknown);
    if (_connecting) { [self stopLinkAnims]; [self animateLink]; }
}

- (void)animateLink { if (_linkKind == XSLinkUSB) [self animateUSB]; else [self animateWifi]; }

- (void)animateWifi {
    for (NSUInteger i = 0; i < _fans.count; i++) {
        CAKeyframeAnimation *op = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        op.values = @[@0.16, @1, @0.16]; op.keyTimes = @[@0, @0.34, @1];
        op.duration = 1.5; op.repeatCount = HUGE_VALF;
        op.beginTime = CACurrentMediaTime() + (i % 3) * 0.16; // inner → outer per side
        [_fans[i] addAnimation:op forKey:@"wave"];
    }
    [self travelDot:_pulseV from:30 to:kLink - 30 begin:0];      // violet iPhone → Mac
    [self travelDot:_pulseP from:kLink - 30 to:30 begin:0];      // pink Mac → iPhone, they cross
}

- (void)animateUSB {
    [self travelDot:_usbDots[0] from:28 to:kLink - 28 begin:0];
    [self travelDot:_usbDots[1] from:kLink - 28 to:28 begin:0.25];
    for (NSUInteger i = 0; i < _usbPlugs.count; i++) {
        CAKeyframeAnimation *gl = [CAKeyframeAnimation animationWithKeyPath:@"shadowOpacity"];
        gl.values = @[@0, @0.9, @0]; gl.keyTimes = @[@0, @0.5, @1]; gl.duration = 1.3; gl.repeatCount = HUGE_VALF;
        gl.beginTime = CACurrentMediaTime() + (i == 0 ? 0.1 : 0.7);
        [_usbPlugs[i] addAnimation:gl forKey:@"glow"];
    }
}

- (void)travelDot:(CALayer *)d from:(CGFloat)x0 to:(CGFloat)x1 begin:(CFTimeInterval)b {
    CGFloat cy = kLinkH / 2;
    CAKeyframeAnimation *op = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    op.values = @[@0, @1, @1, @0]; op.keyTimes = @[@0, @0.2, @0.8, @1];
    CABasicAnimation *mv = [CABasicAnimation animationWithKeyPath:@"position.x"]; mv.fromValue = @(x0); mv.toValue = @(x1);
    CAAnimationGroup *g = [CAAnimationGroup animation]; g.animations = @[op, mv]; g.duration = 1.7; g.repeatCount = HUGE_VALF;
    g.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    g.beginTime = CACurrentMediaTime() + b;
    d.position = CGPointMake(x1, cy); [d addAnimation:g forKey:@"cross"];
}

- (void)stopLinkAnims {
    for (CAShapeLayer *a in _fans) [a removeAnimationForKey:@"wave"];
    [_pulseV removeAnimationForKey:@"cross"]; [_pulseP removeAnimationForKey:@"cross"];
    for (CALayer *d in _usbDots) [d removeAnimationForKey:@"cross"];
    for (CALayer *p in _usbPlugs) [p removeAnimationForKey:@"glow"];
}

- (void)pulseMac:(BOOL)on {
    [_macNode.layer removeAnimationForKey:@"pulse"];
    if (!on) return;
    CABasicAnimation *p = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    p.fromValue = @1; p.toValue = @1.06; p.duration = 0.65; p.autoreverses = YES; p.repeatCount = HUGE_VALF;
    [_macNode.layer addAnimation:p forKey:@"pulse"];
}

- (void)heroConnectedOk:(BOOL)ok {
    // Idempotent: once the badge is shown in a state, don't re-pop it. The update flow calls this on
    // every download %, which made the ✓ blink each time (Anthony). Re-run only when the state flips.
    if (!_macBadge.hidden && _macOk == ok) return;
    _macOk = ok;
    [self pulseMac:NO];
    // The link keeps flowing while the Mac works (data really is moving); it is stopped only at the
    // end, in drawMark. So the transport animation stays visible for the whole refresh, not a blink.
    UIColor *c = ok ? UIColor.systemGreenColor : UIColor.systemRedColor;
    _macNode.layer.borderColor = c.CGColor; if (ok) _iphNode.layer.borderColor = c.CGColor;
    _macBadge.backgroundColor = c; _macBadgeMark.text = ok ? @"✓" : @"✕"; _macBadge.hidden = NO;
    _macBadge.transform = CGAffineTransformMakeScale(0.3, 0.3);
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.5 options:0
                     animations:^{ self->_macBadge.transform = CGAffineTransformIdentity; } completion:nil];
}

- (void)showCancel { _cancelBtn.hidden = (self.cancelAction == nil); }
- (void)hideCancel { _cancelBtn.hidden = YES; }
- (void)tapCancel { void (^c)(void) = self.cancelAction; _cancelBtn.hidden = YES; if (c) c(); }

- (void)setRing:(double)f {
    _fraction = MAX(0, MIN(1, f));
    [CATransaction begin]; [CATransaction setAnimationDuration:0.5];
    _ringMask.strokeEnd = _fraction; [CATransaction commit];
    _pct.hidden = NO; _pct.text = [NSString stringWithFormat:@"%d%%", (int)lround(_fraction * 100)];
}

- (void)drawMark:(BOOL)ok {
    _connecting = NO;
    [self stopLinkAnims]; // the end: the data stops flowing
    [_spinner stopAnimating]; _spinner.hidden = YES; _pct.hidden = YES; [self hideCancel]; // the ✓/✕ takes the centre
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
    [self showCancel];
    // No fake fill: the live steps drive the ring and its centre %. Until the first one, the bottom
    // spinner shows the work.
}

- (void)stepTitle:(NSString *)t detail:(NSString *)d fraction:(double)f {
    if (t) _stepTitle.text = t; _stepSub.text = d ?: @"";
    if (f >= 0) [self setRing:f]; // the spinner stays, spinning at the bottom, until the end
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

// MARK: - Update flow (Slice 3)

/// Connected, and now working on something that isn't a refresh (an update's download/install): a
/// plain « working » with a title, no « the app will close » line.
- (void)workingTitle:(NSString *)t detail:(NSString *)d {
    [self heroConnectedOk:YES];
    _stepTitle.text = t; _stepSub.text = d ?: @""; _lead.text = @"";
    [self showCancel];
    // The real fraction (download %) drives the ring when it comes; meanwhile the bottom spinner works.
}

/// An update is available: show it with a primary button (its block) and « Plus tard ».
- (void)offerTitle:(NSString *)t message:(NSString *)m button:(NSString *)b {
    [self heroConnectedOk:YES];
    [self hideCancel];
    if (_spinner.isAnimating) { [_spinner stopAnimating]; _spinner.hidden = YES; }
    BOOL fr = XSFrench();
    _stepTitle.text = t; _stepSub.text = m ?: @""; _lead.text = @"";
    for (UIView *v in _acts.arrangedSubviews) [v removeFromSuperview];
    XSGradientButton *install = [XSGradientButton buttonWithType:UIButtonTypeCustom];
    [install setTitle:b forState:UIControlStateNormal];
    [install setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    install.titleLabel.font = XSScaledFont(15, UIFontWeightSemibold);
    install.titleLabel.numberOfLines = 1; install.titleLabel.adjustsFontSizeToFitWidth = YES;
    [install addTarget:self action:@selector(tapOffer) forControlEvents:UIControlEventTouchUpInside];
    UIButton *later = [UIButton buttonWithType:UIButtonTypeSystem];
    [later setTitle:(fr ? @"Plus tard" : @"Later") forState:UIControlStateNormal];
    later.titleLabel.font = XSScaledFont(15, UIFontWeightSemibold);
    later.tintColor = UIColor.labelColor; later.backgroundColor = UIColor.secondarySystemBackgroundColor;
    later.layer.cornerRadius = 14; later.layer.cornerCurve = kCACornerCurveContinuous;
    [later addTarget:self action:@selector(tapClose) forControlEvents:UIControlEventTouchUpInside];
    for (UIButton *bb in @[install, later]) [bb.heightAnchor constraintEqualToConstant:46].active = YES;
    [_acts addArrangedSubview:install]; [_acts addArrangedSubview:later];
    _acts.hidden = NO;
}

/// A terminal state for the update flow with a single « Fermer » (the app isn't always replaced, so
/// unlike a refresh it needs a way out): a check when `ok`, a red cross otherwise.
- (void)doneTitle:(NSString *)t message:(NSString *)m ok:(BOOL)ok {
    [self heroConnectedOk:ok];
    if (_spinner.isAnimating) { [_spinner stopAnimating]; _spinner.hidden = YES; }
    _ringFill.colors = ok ? @[(id)XSViolet().CGColor, (id)XSPink().CGColor]
                          : @[(id)UIColor.systemRedColor.CGColor, (id)UIColor.systemRedColor.CGColor];
    [self drawMark:ok];
    _stepTitle.text = t; _stepSub.text = m ?: @""; _lead.text = @"";
    for (UIView *v in _acts.arrangedSubviews) [v removeFromSuperview];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:(XSFrench() ? @"Fermer" : @"Close") forState:UIControlStateNormal];
    close.titleLabel.font = XSScaledFont(15, UIFontWeightSemibold);
    close.tintColor = UIColor.labelColor; close.backgroundColor = UIColor.secondarySystemBackgroundColor;
    close.layer.cornerRadius = 14; close.layer.cornerCurve = kCACornerCurveContinuous;
    [close.heightAnchor constraintEqualToConstant:46].active = YES;
    [close addTarget:self action:@selector(tapClose) forControlEvents:UIControlEventTouchUpInside];
    [_acts addArrangedSubview:close];
    _acts.hidden = NO;
}

/// The person tapped « Télécharger et installer »: hide the buttons, go back to working, run it.
- (void)tapOffer {
    void (^a)(void) = self.offerAction;
    _acts.hidden = YES;
    for (UIView *v in _acts.arrangedSubviews) [v removeFromSuperview];
    [self workingTitle:(XSFrench() ? @"Téléchargement…" : @"Downloading…") detail:nil];
    if (a) a();
}

@end

#pragma mark - C API + window

static UIWindow *XSModalWindow;
static __weak XSRefreshModalController *XSModalVC;

static XSRefreshModalController *XSModalEnsureCore(BOOL willBackUp, NSString *title, NSString *lead) {
    UIWindowScene *scene = XSScene();
    if (!scene) return nil;
    if (XSModalWindow) return XSModalVC;
    XSRefreshModalController *vc = [XSRefreshModalController new];
    vc.willBackUp = willBackUp; vc.titleText = title; vc.leadText = lead;
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.rootViewController = vc; w.windowLevel = UIWindowLevelAlert + 101; XSModalWindow = w; XSModalVC = vc;
    w.hidden = NO;
    return vc;
}

static XSRefreshModalController *XSModalEnsure(BOOL willBackUp) { return XSModalEnsureCore(willBackUp, nil, nil); }

static XSRefreshModalController *XSUpdateModalEnsure(void) {
    BOOL fr = XSFrench();
    return XSModalEnsureCore(NO, fr ? @"Mise à jour" : @"Update", fr ? @"Ton Mac vérifie le dépôt suivi" : @"Your Mac is checking the tracked repo");
}

void XSRefreshModalShow(BOOL willBackUp) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSRefreshModalShow(willBackUp); }); return; }
    XSModalEnsure(willBackUp);
}
void XSRefreshModalShowTitled(BOOL willBackUp, NSString *title, NSString *lead) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSRefreshModalShowTitled(willBackUp, title, lead); }); return; }
    XSModalEnsureCore(willBackUp, title, lead);
}
void XSRefreshModalWorking(void) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSRefreshModalWorking(); }); return; }
    [XSModalVC goWorking];
}
void XSRefreshModalStep(NSString *title, NSString *detail, double fraction) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSRefreshModalStep(title, detail, fraction); }); return; }
    [XSModalVC stepTitle:title detail:detail fraction:fraction];
}
/// Uppercases the first character of a sentence shown on its own (the reason texts are authored
/// lowercase to sit inside « X : … » pills, but a modal shows them as a standalone line, Anthony:
/// « majuscule au début des phrases »). nil-safe.
static NSString *XSSentenceCase(NSString *s) {
    if (s.length == 0) return s;
    return [[[s substringToIndex:1] uppercaseString] stringByAppendingString:[s substringFromIndex:1]];
}

void XSRefreshModalError(NSString *title, NSString *message, void (^retry)(void)) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSRefreshModalError(title, message, retry); }); return; }
    XSRefreshModalController *vc = XSModalEnsure(NO); // show it even if the request never opened it
    vc.retry = retry; [vc errorTitle:XSSentenceCase(title) message:XSSentenceCase(message)];
}
void XSRefreshModalDismiss(void) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSRefreshModalDismiss(); }); return; }
    XSModalWindow.hidden = YES; XSModalWindow = nil;
}
BOOL XSRefreshModalIsShowing(void) { return XSModalWindow != nil; }
void XSUpdateModalShow(void) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSUpdateModalShow(); }); return; }
    XSUpdateModalEnsure();
}
void XSUpdateModalOffer(NSString *title, NSString *message, NSString *button, void (^install)(void)) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSUpdateModalOffer(title, message, button, install); }); return; }
    XSRefreshModalController *vc = XSUpdateModalEnsure();
    vc.offerAction = install; [vc offerTitle:title message:message button:button];
}
void XSUpdateModalWorking(NSString *title, NSString *detail, double fraction) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSUpdateModalWorking(title, detail, fraction); }); return; }
    // Ensure the modal exists: « Réessayer » dismisses it first, so a retried install must bring it
    // back (Anthony: « le bouton réessayer marchait pas » — nothing reappeared).
    XSRefreshModalController *vc = XSUpdateModalEnsure();
    [vc workingTitle:title detail:detail]; if (fraction >= 0) [vc stepTitle:title detail:detail fraction:fraction];
}
void XSUpdateModalDone(NSString *title, NSString *message, BOOL ok) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSUpdateModalDone(title, message, ok); }); return; }
    XSRefreshModalController *vc = XSUpdateModalEnsure(); [vc doneTitle:title message:message ok:ok];
}
void XSSetLinkKind(XSLinkKind kind) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSSetLinkKind(kind); }); return; }
    XSLinkCurrent = kind;
    [XSModalVC applyLinkKind:kind];
}
void XSRefreshModalSetCancel(void (^cancel)(void)) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSRefreshModalSetCancel(cancel); }); return; }
    XSModalVC.cancelAction = cancel; // revealed once the modal enters its working state (showCancel)
}

#pragma mark - Info modal (a settings change, shown full screen with OK)

static void XSInfoModalDismiss(void);

@interface XSInfoModalController : UIViewController
@property (nonatomic, copy, nullable) NSString *infoTitle;
@property (nonatomic, copy, nullable) NSString *infoMessage;
@property (nonatomic, weak, nullable) UILabel *titleLabel;
@property (nonatomic, weak, nullable) UILabel *messageLabel;
@end

@implementation XSInfoModalController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    CGFloat S = 46;
    UIImageView *logo = [UIImageView new];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:XSLogoBase64 options:0];
    logo.image = [UIImage imageWithData:data scale:UIScreen.mainScreen.scale];
    logo.contentMode = UIViewContentModeScaleAspectFit;
    logo.layer.cornerRadius = S * 0.225; logo.layer.cornerCurve = kCACornerCurveContinuous; logo.layer.masksToBounds = YES;
    [NSLayoutConstraint activateConstraints:@[[logo.widthAnchor constraintEqualToConstant:S], [logo.heightAnchor constraintEqualToConstant:S]]];

    UILabel *kicker = [UILabel new];
    kicker.text = @"XSIDE"; kicker.font = XSScaledFont(11, UIFontWeightHeavy);
    kicker.textColor = XSViolet(); kicker.textAlignment = NSTextAlignmentCenter;

    UILabel *t = [UILabel new];
    t.text = self.infoTitle; t.font = XSScaledFont(20, UIFontWeightBold);
    t.numberOfLines = 0; t.textAlignment = NSTextAlignmentCenter; t.adjustsFontForContentSizeCategory = YES;
    self.titleLabel = t;

    UILabel *m = [UILabel new];
    m.text = self.infoMessage; m.font = XSScaledFont(14, UIFontWeightRegular);
    m.textColor = UIColor.secondaryLabelColor; m.numberOfLines = 0; m.textAlignment = NSTextAlignmentCenter;
    m.adjustsFontForContentSizeCategory = YES;
    self.messageLabel = m;

    XSGradientButton *ok = [XSGradientButton buttonWithType:UIButtonTypeCustom];
    [ok setTitle:@"OK" forState:UIControlStateNormal];
    [ok setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    ok.titleLabel.font = XSScaledFont(15, UIFontWeightSemibold);
    [ok addTarget:self action:@selector(tapOK) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[[ok.heightAnchor constraintEqualToConstant:46],
                                              [ok.widthAnchor constraintGreaterThanOrEqualToConstant:160]]];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[logo, kicker, t, m, ok]];
    stack.axis = UILayoutConstraintAxisVertical; stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:9 afterView:logo];
    [stack setCustomSpacing:6 afterView:kicker];
    [stack setCustomSpacing:8 afterView:t];
    [stack setCustomSpacing:26 afterView:m];
    [self.view addSubview:stack];
    NSLayoutConstraint *iWide = [stack.widthAnchor constraintEqualToConstant:460];
    iWide.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor constant:-56],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:460], iWide]];
}
- (void)tapOK { XSInfoModalDismiss(); }
@end

static UIWindow *XSInfoWindow;
static __weak XSInfoModalController *XSInfoVC;

static void XSInfoModalDismiss(void) { XSInfoWindow.hidden = YES; XSInfoWindow = nil; }

void XSInfoModalShow(NSString *title, NSString *message) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XSInfoModalShow(title, message); }); return; }
    UIWindowScene *scene = XSScene();
    if (!scene) return;
    if (XSInfoWindow) { // one already up: replace its text rather than stack a second window
        XSInfoVC.infoTitle = title; XSInfoVC.infoMessage = message;
        XSInfoVC.titleLabel.text = title; XSInfoVC.messageLabel.text = message;
        return;
    }
    XSInfoModalController *vc = [XSInfoModalController new];
    vc.infoTitle = title; vc.infoMessage = message;
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.rootViewController = vc; w.windowLevel = UIWindowLevelAlert + 100; // below the refresh modal (+101)
    XSInfoWindow = w; XSInfoVC = vc;
    w.hidden = NO;
}
