// XSideTweakSupport.dylib: makes converted tweaks find their files. A tweak built for a jailbreak
// reads its files where the jailbreak put them (/Library/MobileSubstrate/DynamicLibraries,
// /Library/Application Support/<Tweak>, /Library/Frameworks, /usr/lib, or the same under /var/jb);
// XSide copies those files into <App>.app/Frameworks/XSideTweaks/<id>/ (and its embedded
// dependencies into Frameworks/XSideTweaks/deps/<packageID>/), and this library sends the tweak's
// lookups there. Added by XSide (weak load command, before the tweaks) only when a converted tweak
// needs it; independent of XSide's module (App/Welcome).
//
// - The rule (XSTweakPathsCore.c, mirror of Sources/XSideCore/TweakPaths.swift): only paths under
//   those known prefixes, never with an empty, "." or ".." component, and only when the file
//   exists in a package's copy (first package wins; tweaks by id, then deps). A dropped .bundle
//   (Frameworks/XSideTweaks/<id>/<X>.bundle) answers /Library/Application Support/<X>.bundle.
// - libc: open, openat, fopen (read-only opens only: a write still goes to the original path),
//   stat, lstat, fstatat, access, faccessat, opendir, dlopen, realpath and getattrlist are interposed
//   (__DATA,__interpose). A library iOS ships is never answered by a tweak's copy.
//   They take a stack buffer, no lock and no allocation; until the library is ready they only pass
//   the call on. dlopen keeps its caller (dlopen_from, or a tail call) so @loader_path / @rpath
//   lookups of the app are unchanged.
// - Foundation / UIKit: -[NSFileManager fileExistsAtPath:], fileExistsAtPath:isDirectory:,
//   contentsOfDirectoryAtPath:error:, +[NSBundle bundleWithPath:], -[NSBundle initWithPath:],
//   +[NSData dataWithContentsOfFile:], -[NSData initWithContentsOfFile:] (and options:error:),
//   +[NSDictionary dictionaryWithContentsOfFile:], -[NSDictionary initWithContentsOfFile:],
//   +[NSString stringWithContentsOfFile:encoding:error:] and +[UIImage imageWithContentsOfFile:]
//   (iOS, when UIKit is there) get the same mapping.
//
// It runs inside apps XSide doesn't know: nothing happens unless the Info.plist file on disk has
// XSideTweakPaths = true (written by XSide only when it added this library); every hook checks
// the class and method exist; nothing throws into the app; the interposed calls never call back
// into themselves (dyld doesn't interpose the interposing image's own calls). Everything is set
// up once, in the constructor, before the tweaks' own constructors run; nothing is ever sent to
// the main thread. Logs: os_log, prefix "[XSTweaks]".

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <dirent.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <stdarg.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/attr.h>
#import <sys/stat.h>
#import <unistd.h>
#import "XSTweakPathsCore.h"

#define XSLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[XSTweaks] " fmt, ##__VA_ARGS__)

#define XS_MAX_PACKAGES 256
#define XS_MAX_NAME (5 + 128 + 1)   // "deps/" + a package id + NUL

// Written once by the constructor, then published by gReady (release); read after an acquire.
static char gRoot[PATH_MAX];
static char gNames[XS_MAX_PACKAGES][XS_MAX_NAME];
static const char *gPackages[XS_MAX_PACKAGES];
static size_t gCount;
typedef void *(*XSDlopenFrom)(const char *path, int mode, void *addressInCaller);
static XSDlopenFrom gDlopenFrom;
static atomic_int gReady;

static int xsReady(void) { return atomic_load_explicit(&gReady, memory_order_acquire); }

// lstat here is libc's own: dyld never interposes the calls of the image that interposes.
static int xsExists(const char *p) {
    struct stat st;
    return lstat(p, &st) == 0;
}

// Fills buf[PATH_MAX] with the tweak's copy of `path`; 0 (and errno untouched) when there is none.
static int xsMap(const char *path, char *buf) {
    if (!path || !xsReady()) return 0;
    // Every redirected path starts with /Library, /usr or /var/jb.
    if (path[0] != '/' || (path[1] != 'L' && path[1] != 'u' && path[1] != 'v')) return 0;
    int saved = errno;
    int mapped = xs_tweak_redirect(path, gRoot, gPackages, gCount, xsExists, buf, PATH_MAX);
    errno = saved;
    return mapped;
}

static int xsReadOnlyFlags(int flags) {
    return (flags & O_ACCMODE) == O_RDONLY && !(flags & (O_CREAT | O_TRUNC | O_APPEND));
}

#pragma mark - libc

static int xs_open(const char *path, int flags, ...) {
    int mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    char buf[PATH_MAX];
    if (xsReadOnlyFlags(flags) && xsMap(path, buf)) path = buf;
    return open(path, flags, mode);
}

static int xs_openat(int fd, const char *path, int flags, ...) {
    int mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    char buf[PATH_MAX];
    if (xsReadOnlyFlags(flags) && xsMap(path, buf)) path = buf;   // absolute paths only (fd unused)
    return openat(fd, path, flags, mode);
}

static FILE *xs_fopen(const char *restrict path, const char *restrict mode) {
    char buf[PATH_MAX];
    if (mode && mode[0] == 'r' && !strchr(mode, '+') && xsMap(path, buf)) path = buf;
    return fopen(path, mode);
}

static int xs_stat(const char *path, struct stat *st) {
    char buf[PATH_MAX];
    return stat(xsMap(path, buf) ? buf : path, st);
}

static int xs_lstat(const char *path, struct stat *st) {
    char buf[PATH_MAX];
    return lstat(xsMap(path, buf) ? buf : path, st);
}

static int xs_access(const char *path, int mode) {
    char buf[PATH_MAX];
    return access(xsMap(path, buf) ? buf : path, mode);
}

static int xs_fstatat(int fd, const char *path, struct stat *st, int flag) {
    char buf[PATH_MAX];
    return fstatat(fd, xsMap(path, buf) ? buf : path, st, flag);   // absolute paths only (fd unused)
}

static int xs_faccessat(int fd, const char *path, int mode, int flag) {
    char buf[PATH_MAX];
    return faccessat(fd, xsMap(path, buf) ? buf : path, mode, flag);
}

static DIR *xs_opendir(const char *path) {
    char buf[PATH_MAX];
    return opendir(xsMap(path, buf) ? buf : path);
}

static char *xs_realpath(const char *restrict path, char *restrict resolved) {
    char buf[PATH_MAX];
    return realpath(xsMap(path, buf) ? buf : path, resolved);
}

static int xs_getattrlist(const char *path, void *attrList, void *attrBuf, size_t attrBufSize, unsigned int options) {
    char buf[PATH_MAX];
    return getattrlist(xsMap(path, buf) ? buf : path, attrList, attrBuf, attrBufSize, options);
}

// dyld resolves @loader_path / @rpath against the image that calls dlopen: the app's call must
// stay the app's. With dlopen_from (dyld 4) the caller is passed on; without it a mapped (absolute)
// path is opened from here, and anything else is a tail call that leaves the caller as it was.
static char gNotMapped;
__attribute__((noinline)) static void *xsDlopenMapped(const char *path, int mode) {
    char buf[PATH_MAX];
    if (!xsMap(path, buf)) return &gNotMapped;
    return dlopen(buf, mode);
}

static void *xs_dlopen(const char *path, int mode) {
    if (xsReady()) {
        if (gDlopenFrom) {
            char buf[PATH_MAX];
            return gDlopenFrom(xsMap(path, buf) ? buf : path, mode, __builtin_return_address(0));
        }
        void *handle = xsDlopenMapped(path, mode);
        if (handle != &gNotMapped) return handle;
    }
    __attribute__((musttail)) return dlopen(path, mode);
}

typedef struct { const void *replacement; const void *original; } XSInterpose;
#define XS_INTERPOSE(repl, orig) \
    __attribute__((used)) static const XSInterpose xs_interpose_##orig \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&repl, (const void *)&orig }

XS_INTERPOSE(xs_open, open);
XS_INTERPOSE(xs_openat, openat);
XS_INTERPOSE(xs_fopen, fopen);
XS_INTERPOSE(xs_stat, stat);
XS_INTERPOSE(xs_lstat, lstat);
XS_INTERPOSE(xs_access, access);
XS_INTERPOSE(xs_fstatat, fstatat);
XS_INTERPOSE(xs_faccessat, faccessat);
XS_INTERPOSE(xs_opendir, opendir);
XS_INTERPOSE(xs_realpath, realpath);   // realpath$DARWIN_EXTSN, through the header
XS_INTERPOSE(xs_getattrlist, getattrlist);
XS_INTERPOSE(xs_dlopen, dlopen);

#pragma mark - Foundation / UIKit

static NSString *xsMapped(id path) {
    if (![path isKindOfClass:NSString.class]) return nil;
    char in[PATH_MAX], out[PATH_MAX];
    if (![(NSString *)path getFileSystemRepresentation:in maxLength:sizeof in]) return nil;
    if (!xsMap(in, out)) return nil;
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:out length:strlen(out)];
}

static IMP oFileExists, oFileExistsDir, oContents, oBundleWithPath, oBundleInit, oDataWithFile, oDictWithFile,
    oDataInit, oDataInitOptions, oDictInit, oStringWithFile;

static BOOL h_fileExists(id self, SEL _cmd, NSString *path) {
    return ((BOOL (*)(id, SEL, id))oFileExists)(self, _cmd, xsMapped(path) ?: path);
}
static BOOL h_fileExistsDir(id self, SEL _cmd, NSString *path, BOOL *isDir) {
    return ((BOOL (*)(id, SEL, id, BOOL *))oFileExistsDir)(self, _cmd, xsMapped(path) ?: path, isDir);
}
static id h_contents(id self, SEL _cmd, NSString *path, NSError **error) {
    return ((id (*)(id, SEL, id, NSError **))oContents)(self, _cmd, xsMapped(path) ?: path, error);
}
static id h_bundleWithPath(id self, SEL _cmd, NSString *path) {
    return ((id (*)(id, SEL, id))oBundleWithPath)(self, _cmd, xsMapped(path) ?: path);
}
static id h_bundleInit(id self, SEL _cmd, NSString *path) {
    return ((id (*)(id, SEL, id))oBundleInit)(self, _cmd, xsMapped(path) ?: path);
}
static id h_dataWithFile(id self, SEL _cmd, NSString *path) {
    return ((id (*)(id, SEL, id))oDataWithFile)(self, _cmd, xsMapped(path) ?: path);
}
static id h_dictWithFile(id self, SEL _cmd, NSString *path) {
    return ((id (*)(id, SEL, id))oDictWithFile)(self, _cmd, xsMapped(path) ?: path);
}
static id h_dataInit(id self, SEL _cmd, NSString *path) {
    return ((id (*)(id, SEL, id))oDataInit)(self, _cmd, xsMapped(path) ?: path);
}
static id h_dataInitOptions(id self, SEL _cmd, NSString *path, NSDataReadingOptions options, NSError **error) {
    return ((id (*)(id, SEL, id, NSDataReadingOptions, NSError **))oDataInitOptions)(self, _cmd, xsMapped(path) ?: path,
                                                                                   options, error);
}
static id h_dictInit(id self, SEL _cmd, NSString *path) {
    return ((id (*)(id, SEL, id))oDictInit)(self, _cmd, xsMapped(path) ?: path);
}
static id h_stringWithFile(id self, SEL _cmd, NSString *path, NSStringEncoding encoding, NSError **error) {
    return ((id (*)(id, SEL, id, NSStringEncoding, NSError **))oStringWithFile)(self, _cmd, xsMapped(path) ?: path,
                                                                              encoding, error);
}
#if TARGET_OS_IPHONE
static IMP oImageWithFile;
static id h_imageWithFile(id self, SEL _cmd, NSString *path) {
    return ((id (*)(id, SEL, id))oImageWithFile)(self, _cmd, xsMapped(path) ?: path);
}
#endif

// Replaces `sel` on `c` (added on `c` when inherited) and keeps the original. Does nothing when
// the class or the method doesn't exist.
static void xsHook(Class c, SEL sel, IMP repl, IMP *orig) {
    if (!c) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { XSLOG("no method %{public}s on %{public}s", sel_getName(sel), class_getName(c)); return; }
    // The original is known before the hook can run (another thread may call it at once).
    *orig = method_getImplementation(m);
    if (class_addMethod(c, sel, repl, method_getTypeEncoding(m))) return;
    IMP previous = method_setImplementation(m, repl);
    if (previous && previous != *orig) *orig = previous;
}

// The class whose `sel` runs for `[name alloc]`: the cluster's placeholder when that defines it.
static Class xsInitClass(const char *name, SEL sel) {
    Class c = objc_getClass(name);
    if (!c) return Nil;
    id placeholder = ((id (*)(id, SEL))objc_msgSend)(c, @selector(alloc));   // a shared placeholder, never freed
    Class p = placeholder ? object_getClass(placeholder) : Nil;
    if (!p || p == c) return c;
    // Defined on the placeholder itself, or only inherited from `c`?
    unsigned n = 0;
    Method *methods = class_copyMethodList(p, &n);
    BOOL own = NO;
    for (unsigned i = 0; i < n && !own; i++) own = method_getName(methods[i]) == sel;
    free(methods);
    return own ? p : c;
}

static void xsInstallHooks(void) {
    Class fm = objc_getClass("NSFileManager"), bundle = objc_getClass("NSBundle");
    xsHook(fm, @selector(fileExistsAtPath:), (IMP)h_fileExists, &oFileExists);
    xsHook(fm, @selector(fileExistsAtPath:isDirectory:), (IMP)h_fileExistsDir, &oFileExistsDir);
    xsHook(fm, @selector(contentsOfDirectoryAtPath:error:), (IMP)h_contents, &oContents);
    xsHook(bundle, @selector(initWithPath:), (IMP)h_bundleInit, &oBundleInit);
    xsHook(object_getClass(bundle), @selector(bundleWithPath:), (IMP)h_bundleWithPath, &oBundleWithPath);
    xsHook(object_getClass(objc_getClass("NSData")), @selector(dataWithContentsOfFile:), (IMP)h_dataWithFile, &oDataWithFile);
    xsHook(object_getClass(objc_getClass("NSDictionary")), @selector(dictionaryWithContentsOfFile:),
           (IMP)h_dictWithFile, &oDictWithFile);
    xsHook(object_getClass(objc_getClass("NSString")), @selector(stringWithContentsOfFile:encoding:error:),
           (IMP)h_stringWithFile, &oStringWithFile);
    // Class clusters: +alloc gives a placeholder that may have its own -init…; hook the class the
    // init really runs on (the placeholder), or the class itself.
    xsHook(xsInitClass("NSData", @selector(initWithContentsOfFile:)), @selector(initWithContentsOfFile:),
           (IMP)h_dataInit, &oDataInit);
    xsHook(xsInitClass("NSData", @selector(initWithContentsOfFile:options:error:)),
           @selector(initWithContentsOfFile:options:error:), (IMP)h_dataInitOptions, &oDataInitOptions);
    xsHook(xsInitClass("NSDictionary", @selector(initWithContentsOfFile:)), @selector(initWithContentsOfFile:),
           (IMP)h_dictInit, &oDictInit);
#if TARGET_OS_IPHONE
    Class image = objc_getClass("UIImage");   // UIKit only when the app has it
    if (image) xsHook(object_getClass(image), @selector(imageWithContentsOfFile:), (IMP)h_imageWithFile, &oImageWithFile);
#endif
}

#pragma mark - Setup

static int xsCompare(const void *a, const void *b) { return strcmp(*(const char *const *)a, *(const char *const *)b); }

// Adds the package folders found in `dir` (names prefixed with `prefix`), sorted, to gPackages.
static void xsListPackages(const char *dir, const char *prefix) {
    DIR *d = opendir(dir);
    if (!d) return;
    size_t first = gCount;
    struct dirent *e;
    while ((e = readdir(d)) && gCount < XS_MAX_PACKAGES) {
        char name[XS_MAX_NAME];
        if (snprintf(name, sizeof name, "%s%s", prefix, e->d_name) >= (int)sizeof name) continue;
        if (!xs_tweak_is_package_folder(name)) continue;
        char full[PATH_MAX];
        struct stat st;
        if (snprintf(full, sizeof full, "%s/%s", dir, e->d_name) >= (int)sizeof full) continue;
        if (lstat(full, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        memcpy(gNames[gCount], name, strlen(name) + 1);
        gPackages[gCount] = gNames[gCount];
        gCount++;
    }
    closedir(d);
    qsort(&gPackages[first], gCount - first, sizeof *gPackages, xsCompare);
}

__attribute__((constructor)) static void xsTweakSupportInit(void) {
    @autoreleasepool {
        @try {
            // From the file, not NSBundle (AGENTS rule 4).
            NSString *app = NSBundle.mainBundle.bundlePath;
            NSData *data = app ? [NSData dataWithContentsOfFile:[app stringByAppendingPathComponent:@"Info.plist"]] : nil;
            id info = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
            if (![info isKindOfClass:NSDictionary.class] || ((NSDictionary *)info)[@"XSideTweakPaths"] != (id)kCFBooleanTrue) {
                XSLOG("not enabled for this app (no XSideTweakPaths in its Info.plist): nothing installed");
                return;
            }
            NSString *root = [app stringByAppendingPathComponent:@"Frameworks/XSideTweaks"];
            if (![root getFileSystemRepresentation:gRoot maxLength:sizeof gRoot] || gRoot[0] != '/') {
                XSLOG("unusable app path: nothing installed");
                return;
            }
            xsListPackages(gRoot, "");
            char deps[PATH_MAX];
            if (snprintf(deps, sizeof deps, "%s/deps", gRoot) < (int)sizeof deps) xsListPackages(deps, "deps/");
            if (gCount == 0) { XSLOG("no tweak folder in %{public}s: nothing installed", gRoot); return; }
#ifndef XS_TEST_NO_DLOPEN_FROM   // scripts/test-tweak-support.sh: runs the tail-call fallback
            gDlopenFrom = (XSDlopenFrom)dlsym(RTLD_DEFAULT, "dlopen_from");
#endif
            atomic_store_explicit(&gReady, 1, memory_order_release);
            xsInstallHooks();
            XSLOG("redirecting jailbreak paths to %zu tweak folders", gCount);
        } @catch (NSException *e) {
            XSLOG("setup failed: %{public}@", e.reason);
        }
    }
}
