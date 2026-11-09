// ✅ test tweak: no hooking library, no jailbreak path. It replaces +[XSTProbe objcLine] of the
// test app with the ObjC runtime alone (line 1).
//   -DXST_CRASH  crash build: traps in its own code 3 s after launch (CrashDiagnosis must name it
//                and offer « Désactiver ce tweak »)
//   -DXST_QUIET  changes nothing (the download tests' tweaks only need to load)
// Built by scripts/make-tweak-test-kit.sh (never shipped).
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>

#define XSTLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[XSTest] plain: " fmt, ##__VA_ARGS__)
#define XST(fr, en) ([NSLocale.preferredLanguages.firstObject hasPrefix:@"fr"] ? (fr) : (en))

#ifndef XST_QUIET
static NSString *XSTObjcLine(id self, SEL _cmd) {
    return XST(@"oui (tweak simple, runtime ObjC)", @"yes (plain tweak, ObjC runtime)");
}
#endif

#ifdef XST_CRASH
__attribute__((noinline)) static void XSTCrashNow(void) {
    XSTLOG("crashing on purpose (XST_CRASH)");
    __builtin_trap();
}
#endif

__attribute__((constructor)) static void XSTPlainInit(void) {
#ifdef XST_QUIET
    XSTLOG("loaded (quiet)");
#else
    Class meta = objc_getMetaClass("XSTProbe");
    Method m = meta ? class_getClassMethod(meta, @selector(objcLine)) : NULL;
    if (!m) { XSTLOG("XSTProbe.objcLine not found: not the test app"); return; }
    method_setImplementation(m, (IMP)XSTObjcLine);
    XSTLOG("objcLine replaced");
#endif
#ifdef XST_CRASH
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ XSTCrashNow(); });
#endif
}
