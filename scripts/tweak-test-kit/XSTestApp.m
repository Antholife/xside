// XSide Tweak Test (io.github.xside.tweaktest): the app the test tweaks change. Five lines, each
// "no" until a tweak changes it:
//   1. ObjC hook       +[XSTProbe objcLine], replaced by a tweak (runtime or MSHookMessageEx)
//   2. C function hook XSTCProbe(), hooked with MSHookFunction when « Essayer le hook C » is tapped
//                      (+[XSTProbe tryCHook], replaced by the Substrate tweak): a hook that needs
//                      writable code may crash the app, so it never runs at launch
//   3. Marker          +[XSTProbe markerLine]: the tweak reads
//                      /Library/Application Support/XSideTestTweak/marker.txt (or /var/jb/…)
//   4. NSBundle        +[XSTProbe bundleLine]: the tweak opens
//                      /Library/Application Support/XSideTestTweak.bundle (or /var/jb/…)
//   5. Cephei          NSClassFromString(@"HBPreferences"), plus +[XSTProbe cepheiDetail]
// Below: iOS, device, what Frameworks/XSideTweaks holds and the XSideTweaks images loaded.
// Built by scripts/make-tweak-test-kit.sh (never shipped).
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <sys/utsname.h>
#import <os/log.h>

#define XSTLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[XSTest] app: " fmt, ##__VA_ARGS__)

static BOOL XSTFrench(void) {
    NSString *lang = NSLocale.preferredLanguages.firstObject ?: @"en";
    return [lang hasPrefix:@"fr"];
}
#define XST(fr, en) (XSTFrench() ? (fr) : (en))

// The C function a tweak hooks. Exported (found with dlsym / MSFindSymbol), never inlined, and
// called through a volatile pointer so the compiler can't fold its result.
__attribute__((visibility("default"), noinline, used))
const char *XSTCProbe(void) {
    __asm__ volatile("");
    return "no";
}
static const char *(*volatile gCProbe)(void) = XSTCProbe;

@interface XSTProbe : NSObject
@end
@implementation XSTProbe
+ (NSString *)objcLine { return nil; }
+ (NSString *)tryCHook { return XST(@"aucun tweak ne propose ce hook", @"no tweak offers this hook"); }
+ (NSString *)markerLine { return nil; }
+ (NSString *)bundleLine { return nil; }
+ (NSString *)cepheiDetail { return nil; }
+ (NSString *)cepheiShellLine { return XST(@"aucun tweak Cephei", @"no Cephei tweak"); }
@end

static NSString *XSTNo(void) { return XST(@"non", @"no"); }
static NSString *XSTOr(NSString *s) { return s.length ? s : XSTNo(); }

#pragma mark - Root view

@interface XSTRootViewController : UIViewController
@property UILabel *lines, *info;
@property (copy) NSString *cHookStatus, *shellStatus;
@end

@implementation XSTRootViewController

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    b.backgroundColor = UIColor.secondarySystemBackgroundColor;
    b.layer.cornerRadius = 10;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UILabel *)label:(CGFloat)size {
    UILabel *l = [UILabel new];
    l.numberOfLines = 0;
    l.font = [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightMedium];
    return l;
}

- (void)loadView {
    UIView *v = [UIView new];
    v.backgroundColor = UIColor.systemBackgroundColor;
    self.view = v;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:scroll];

    UILabel *title = [self label:20];
    title.font = [UIFont boldSystemFontOfSize:22];
    title.text = @"XSide Tweak Test";
    self.lines = [self label:15];
    self.info = [self label:11];
    self.info.textColor = UIColor.secondaryLabelColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, self.lines,
        [self button:XST(@"Essayer le hook C (ligne 2)", @"Try the C hook (line 2)") action:@selector(tryCHook)],
        [self button:XST(@"Cephei : commande shell", @"Cephei: shell command") action:@selector(tryShell)],
        [self button:XST(@"Actualiser", @"Refresh") action:@selector(refresh)],
        self.info,
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    UILayoutGuide *g = v.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:g.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self refresh];
}

- (void)tryCHook {
    self.cHookStatus = [XSTProbe tryCHook];
    XSTLOG("C hook: %{public}@", self.cHookStatus);
    [self refresh];
}

- (void)tryShell {
    self.shellStatus = [XSTProbe cepheiShellLine];
    XSTLOG("Cephei shell: %{public}@", self.shellStatus);
    [self refresh];
}

/// What the app's own Frameworks/XSideTweaks holds (two levels), and the images loaded from it.
- (NSString *)tweaksFolder {
    NSString *root = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/XSideTweaks"];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL dir = NO;
    if (![fm fileExistsAtPath:root isDirectory:&dir] || !dir) {
        return XST(@"Frameworks/XSideTweaks : absent", @"Frameworks/XSideTweaks: missing");
    }
    NSMutableArray *out = [NSMutableArray arrayWithObject:@"Frameworks/XSideTweaks:"];
    for (NSString *name in [[fm contentsOfDirectoryAtPath:root error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *path = [root stringByAppendingPathComponent:name];
        [out addObject:[@"  " stringByAppendingString:name]];
        if ([fm fileExistsAtPath:path isDirectory:&dir] && dir && ![name hasSuffix:@".bundle"]) {
            for (NSString *sub in [[fm contentsOfDirectoryAtPath:path error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
                [out addObject:[@"    " stringByAppendingString:sub]];
            }
        }
    }
    [out addObject:XST(@"Images chargées depuis XSideTweaks :", @"Images loaded from XSideTweaks:")];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        const char *at = name ? strstr(name, "/XSideTweaks/") : NULL;
        if (at) [out addObject:[@"  " stringByAppendingString:@(at + strlen("/XSideTweaks/"))]];
    }
    return [out componentsJoinedByString:@"\n"];
}

- (void)refresh {
    Class cephei = NSClassFromString(@"HBPreferences");
    NSString *line5 = cephei ? [XST(@"oui", @"yes") stringByAppendingString:([XSTProbe cepheiDetail].length
                                    ? [@" — " stringByAppendingString:[XSTProbe cepheiDetail]] : @"")]
                             : XSTNo();
    NSString *c = @(gCProbe());
    if ([c isEqualToString:@"no"]) c = XSTNo();
    if (self.cHookStatus) c = [c stringByAppendingFormat:@"\n   (%@)", self.cHookStatus];
    NSArray *rows = @[
        [NSString stringWithFormat:XST(@"1. Hook ObjC : %@", @"1. ObjC hook: %@"), XSTOr([XSTProbe objcLine])],
        [NSString stringWithFormat:XST(@"2. Hook de fonction C : %@", @"2. C function hook: %@"), c],
        [NSString stringWithFormat:XST(@"3. Marqueur : %@", @"3. Marker: %@"), XSTOr([XSTProbe markerLine])],
        [NSString stringWithFormat:XST(@"4. NSBundle (chemin de jailbreak) : %@", @"4. NSBundle (jailbreak path): %@"),
                                   XSTOr([XSTProbe bundleLine])],
        [NSString stringWithFormat:XST(@"5. Cephei chargé : %@", @"5. Cephei loaded: %@"), line5],
    ];
    NSMutableString *text = [[rows componentsJoinedByString:@"\n\n"] mutableCopy];
    if (self.shellStatus) [text appendFormat:XST(@"\n\nCommande shell (Cephei) : %@", @"\n\nShell command (Cephei): %@"), self.shellStatus];
    self.lines.text = text;

    struct utsname u;
    uname(&u);
    self.info.text = [NSString stringWithFormat:@"iOS %@ · %s\n%@ %@\n\n%@",
        UIDevice.currentDevice.systemVersion, u.machine,
        NSBundle.mainBundle.bundleIdentifier,
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
        [self tweaksFolder]];
    XSTLOG("%{public}@", [text stringByReplacingOccurrencesOfString:@"\n\n" withString:@" | "]);
}

@end

#pragma mark - Scene and app

@interface XSTSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation XSTSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [XSTRootViewController new];
    [self.window makeKeyAndVisible];
}
@end

@interface XSTAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation XSTAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    c.delegateClass = XSTSceneDelegate.class;
    return c;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(XSTAppDelegate.class));
    }
}
