// 🔧 test tweak, as a jailbreak tweak is built: linked against CydiaSubstrate (XSide swaps in
// ElleKit) and reading its files from the jailbreak's folders (XSide copies them into the app and
// XSideTweakSupport redirects the paths). In the test app it changes:
//   line 1  +[XSTProbe objcLine]   with MSHookMessageEx
//   line 2  XSTCProbe()            with MSHookFunction, only when « Essayer le hook C » is tapped
//                                  (+[XSTProbe tryCHook]): patching code may crash without JIT
//   line 3  +[XSTProbe markerLine] reads <root>/Library/Application Support/XSideTestTweak/marker.txt
//   line 4  +[XSTProbe bundleLine] opens <root>/Library/Application Support/XSideTestTweak.bundle
// <root> is "" (rootful) or "/var/jb" (-DROOTLESS).
// Built by scripts/make-tweak-test-kit.sh (never shipped).
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <os/log.h>

#define XSTLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[XSTest] substrate: " fmt, ##__VA_ARGS__)
#define XST(fr, en) ([NSLocale.preferredLanguages.firstObject hasPrefix:@"fr"] ? (fr) : (en))

// CydiaSubstrate's API (CydiaSubstrateStub.c at link time, ElleKit on the device).
extern void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old);
extern void MSHookFunction(void *symbol, void *replace, void **result);

#ifdef ROOTLESS
#define XST_ROOT "/var/jb"
#define XST_LAYOUT "rootless"
#else
#define XST_ROOT ""
#define XST_LAYOUT "rootful"
#endif
#define XST_MARKER XST_ROOT "/Library/Application Support/XSideTestTweak/marker.txt"
#define XST_BUNDLE XST_ROOT "/Library/Application Support/XSideTestTweak.bundle"

static IMP origObjcLine, origTryCHook, origMarkerLine, origBundleLine;
static const char *(*origCProbe)(void);
static NSString *gCResult;

static NSString *XSTObjcLine(id self, SEL _cmd) {
    return [NSString stringWithFormat:XST(@"oui (MSHookMessageEx, %s)", @"yes (MSHookMessageEx, %s)"), XST_LAYOUT];
}

static const char *XSTCProbeHooked(void) { return gCResult.UTF8String; }

static NSString *XSTTryCHook(id self, SEL _cmd) {
    static BOOL done;
    if (done) return XST(@"déjà essayé", @"already tried");
    done = YES;
    void *symbol = dlsym(RTLD_DEFAULT, "XSTCProbe");
    if (!symbol) return XST(@"XSTCProbe introuvable (dlsym)", @"XSTCProbe not found (dlsym)");
    XSTLOG("MSHookFunction(%p)...", symbol);
    MSHookFunction(symbol, (void *)XSTCProbeHooked, (void **)&origCProbe);
    XSTLOG("MSHookFunction returned, original %p", origCProbe);
    return [NSString stringWithFormat:XST(@"MSHookFunction a rendu la main, original %@", @"MSHookFunction returned, original %@"),
            origCProbe ? @"ok" : @"NULL"];
}

static NSString *XSTMarkerLine(id self, SEL _cmd) {
    FILE *f = fopen(XST_MARKER, "r");
    if (!f) return [NSString stringWithFormat:XST(@"non (fopen : %s)", @"no (fopen: %s)"), strerror(errno)];
    char buf[256] = {0};
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    NSString *text = [[[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding] ?: @"?"
                      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [NSString stringWithFormat:XST(@"oui « %@ »", @"yes \"%@\""), text];
}

static NSString *XSTBundleLine(id self, SEL _cmd) {
    NSBundle *b = [NSBundle bundleWithPath:@XST_BUNDLE];
    if (!b) return XST(@"non (bundle introuvable)", @"no (bundle not found)");
    NSString *marker = [b objectForInfoDictionaryKey:@"XSTMarker"];
    if (!marker) return XST(@"non (bundle sans XSTMarker)", @"no (bundle without XSTMarker)");
    NSArray *parts = b.bundlePath.pathComponents;
    NSString *where = parts.count > 3 ? [[parts subarrayWithRange:NSMakeRange(parts.count - 3, 3)] componentsJoinedByString:@"/"]
                                      : b.bundlePath;
    return [NSString stringWithFormat:XST(@"oui « %@ » (…/%@)", @"yes \"%@\" (…/%@)"), marker, where];
}

__attribute__((constructor)) static void XSTSubstrateInit(void) {
    gCResult = [NSString stringWithFormat:XST(@"oui (MSHookFunction, %s)", @"yes (MSHookFunction, %s)"), XST_LAYOUT];
    Class meta = objc_getMetaClass("XSTProbe");
    if (!meta) { XSTLOG("XSTProbe not found: not the test app"); return; }
    MSHookMessageEx(meta, @selector(objcLine), (IMP)XSTObjcLine, &origObjcLine);
    MSHookMessageEx(meta, @selector(tryCHook), (IMP)XSTTryCHook, &origTryCHook);
    MSHookMessageEx(meta, @selector(markerLine), (IMP)XSTMarkerLine, &origMarkerLine);
    MSHookMessageEx(meta, @selector(bundleLine), (IMP)XSTBundleLine, &origBundleLine);
    XSTLOG("hooks installed (" XST_LAYOUT "), objcLine original %p", origObjcLine);
}
