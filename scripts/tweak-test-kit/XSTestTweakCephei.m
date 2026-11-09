// 🔧 test tweak that needs Cephei (ws.hbang.common), linked as on a jailbreak:
// /Library/Frameworks/Cephei.framework/Cephei. XSide adds its embedded Cephei and rewrites the
// path. Its loading makes line 5 of the test app say yes; +[XSTProbe cepheiDetail] (replaced with
// the ObjC runtime, no hooking library) shows that HBPreferences keeps a value across launches,
// and +[XSTProbe cepheiShellLine] runs HBOutputForShellCommand: embedded, Cephei's shell commands
// are expected to fail (they need /var/jb/bin/sh), without crashing.
// Built by scripts/make-tweak-test-kit.sh (never shipped).
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>

#define XSTLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[XSTest] cephei: " fmt, ##__VA_ARGS__)
#define XST(fr, en) ([NSLocale.preferredLanguages.firstObject hasPrefix:@"fr"] ? (fr) : (en))

// Cephei's API (a link stub at build time, XSide's embedded Cephei on the device).
@interface HBPreferences : NSObject
+ (instancetype)preferencesForIdentifier:(NSString *)identifier;
- (NSInteger)integerForKey:(NSString *)key default:(NSInteger)defaultValue;
- (void)setInteger:(NSInteger)value forKey:(NSString *)key;
@end
extern NSString *HBOutputForShellCommandWithReturnCode(NSString *command, int *returnCode);

static NSString *gDetail;

static NSString *XSTCepheiDetail(id self, SEL _cmd) { return gDetail; }

static NSString *XSTCepheiShellLine(id self, SEL _cmd) {
    int code = -1;
    NSString *out = HBOutputForShellCommandWithReturnCode(@"echo xside", &code);
    XSTLOG("HBOutputForShellCommand: %{public}@ (code %d)", out ?: @"nil", code);
    return [NSString stringWithFormat:XST(@"sortie %@, code %d", @"output %@, code %d"),
            out ? [NSString stringWithFormat:@"\"%@\"", out] : @"nil", code];
}

__attribute__((constructor)) static void XSTCepheiInit(void) {
    HBPreferences *prefs = [HBPreferences preferencesForIdentifier:@"io.github.xside.testtweak.cephei"];
    NSInteger runs = [prefs integerForKey:@"launches" default:0] + 1;
    [prefs setInteger:runs forKey:@"launches"];
    gDetail = [NSString stringWithFormat:XST(@"HBPreferences : lancement n° %ld", @"HBPreferences: launch #%ld"), (long)runs];
    XSTLOG("%{public}@", gDetail);
    Class meta = objc_getMetaClass("XSTProbe");
    if (!meta) { XSTLOG("XSTProbe not found: not the test app"); return; }
    method_setImplementation(class_getClassMethod(meta, @selector(cepheiDetail)), (IMP)XSTCepheiDetail);
    method_setImplementation(class_getClassMethod(meta, @selector(cepheiShellLine)), (IMP)XSTCepheiShellLine);
}
