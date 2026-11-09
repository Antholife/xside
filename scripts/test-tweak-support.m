// Checks XSideTweakSupport.dylib (App/TweakSupport) on the Mac; run by scripts/test-tweak-support.sh.
//   test-tweak-support fixture <tweak-paths-fixture.json>   the C core against the fixture shared with
//                                                           TweakPathsTests (Swift)
//   test-tweak-support active                               the library loaded, Info.plist says
//                                                           XSideTweakPaths = true: lookups redirected
//   test-tweak-support inert                                the library loaded without the key: nothing is
// The script lays out the app folder (Frameworks/XSideTweaks/<id>/…) next to this program.
#import <Foundation/Foundation.h>
#import <dirent.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <pthread.h>
#import <stdio.h>
#import <string.h>
#import <sys/attr.h>
#import <sys/vnode.h>
#import <sys/stat.h>
#import <unistd.h>
#import "XSTweakPathsCore.h"

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL " __VA_ARGS__); fputc('\n', stderr); } } while (0)

#pragma mark - fixture

static NSSet<NSString *> *gPresent;
static int fixtureExists(const char *p) { return [gPresent containsObject:@(p)]; }

static int runFixture(const char *file) {
    NSData *data = [NSData dataWithContentsOfFile:@(file)];
    NSDictionary *f = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![f isKindOfClass:NSDictionary.class]) { fprintf(stderr, "FAIL cannot read %s\n", file); return 1; }
    gPresent = [NSSet setWithArray:f[@"exists"]];
    NSArray<NSString *> *names = f[@"packages"];
    const char *packages[64];
    size_t count = 0;
    for (NSString *n in names) if (count < 64) packages[count++] = n.UTF8String;
    const char *root = [f[@"tweaksRoot"] UTF8String];
    int n = 0;
    for (NSDictionary *c in f[@"cases"]) {
        n++;
        const char *path = [c[@"path"] UTF8String];
        id expect = c[@"expect"];
        char out[PATH_MAX];
        strcpy(out, "untouched");
        int got = xs_tweak_redirect(path, root, packages, count, fixtureExists, out, sizeof out);
        if ([expect isKindOfClass:NSString.class]) {
            CHECK(got == 1 && strcmp(out, [expect UTF8String]) == 0, "%s: %.80s -> %s (expected %s)",
                  [c[@"why"] UTF8String], path, got ? out : "no redirect", [expect UTF8String]);
        } else {
            CHECK(got == 0 && strcmp(out, "untouched") == 0, "%s: %.80s -> %s (expected no redirect)",
                  [c[@"why"] UTF8String], path, out);
        }
    }
    // A result that doesn't fit the caller's buffer is no redirect, and nothing is written.
    char small[8] = "keep";
    CHECK(xs_tweak_redirect("/Library/Application Support/T/a.png", root, packages, count, fixtureExists, small,
                            sizeof small) == 0 && strcmp(small, "keep") == 0, "a small buffer is left untouched");
    CHECK(xs_tweak_redirect(NULL, root, packages, count, fixtureExists, small, sizeof small) == 0, "NULL path");
    if (failures) return 1;
    printf("ok: %d fixture cases through the C core\n", n);
    return 0;
}

#pragma mark - the library in a process

static NSString *const kDir = @"/Library/Application Support/XSTweakSupportTest";
#define DIR_C "/Library/Application Support/XSTweakSupportTest"
#define HELLO DIR_C "/hello.txt"

static NSString *readAll(int fd) {
    if (fd < 0) return nil;
    char buf[256];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n < 0) return nil;
    buf[n] = 0;
    return @(buf);
}

static void *hammer(void *arg) {
    long *bad = arg;
    for (int i = 0; i < 5000; i++) {
        struct stat st;
        if (stat(HELLO, &st) != 0 || !S_ISREG(st.st_mode)) (*bad)++;
        if (stat(DIR_C "/missing.txt", &st) == 0) (*bad)++;
        if (access("/var/jb" HELLO, R_OK) != 0) (*bad)++;
    }
    return NULL;
}

static int runActive(void) {
    NSString *expected = @"hello from p1\n";
    CHECK([readAll(open(HELLO, O_RDONLY)) isEqual:expected], "open");
    CHECK([readAll(open("/var/jb" HELLO, O_RDONLY)) isEqual:expected], "open /var/jb");
    CHECK([readAll(openat(AT_FDCWD, HELLO, O_RDONLY)) isEqual:expected], "openat");
    errno = 0;
    CHECK(open(HELLO, O_WRONLY) == -1 && errno == ENOENT, "a write open goes to the original path");
    CHECK(open(HELLO, O_RDONLY | O_CREAT, 0644) == -1, "a creating open goes to the original path");
    CHECK([readAll(open(DIR_C "/only2.txt", O_RDONLY)) isEqual:@"p2\n"], "a file only in the second tweak");
    CHECK([readAll(open("/var/jb/Library/Frameworks/XSTestDep.framework/data.txt", O_RDONLY)) isEqual:@"dep\n"],
          "a file of an embedded dependency");
    errno = 0;
    CHECK(open(DIR_C "/missing.txt", O_RDONLY) == -1 && errno == ENOENT, "missing file: ENOENT");
    CHECK(open(DIR_C "/../XSTweakSupportTest/hello.txt", O_RDONLY) == -1, "dot-dot not redirected");
    CHECK(open(DIR_C "/evil.txt", O_RDONLY) == -1, "a folder that isn't a package is never used");

    struct stat st;
    CHECK(stat(HELLO, &st) == 0 && S_ISREG(st.st_mode) && st.st_size == 14, "stat");
    CHECK(lstat("/var/jb" HELLO, &st) == 0 && S_ISREG(st.st_mode), "lstat");
    CHECK(stat(DIR_C, &st) == 0 && S_ISDIR(st.st_mode), "stat of the tweak's folder");
    CHECK(access(HELLO, R_OK) == 0, "access");
    CHECK(stat("/etc/hosts", &st) == 0, "other paths still work");

    FILE *f = fopen(HELLO, "r");
    char line[64] = "";
    CHECK(f && fgets(line, sizeof line, f) && strcmp(line, "hello from p1\n") == 0, "fopen r");
    if (f) fclose(f);
    CHECK(fopen(HELLO, "r+") == NULL, "fopen r+ goes to the original path");

    DIR *d = opendir(DIR_C);
    int sawHello = 0;
    if (d) { struct dirent *e; while ((e = readdir(d))) if (!strcmp(e->d_name, "hello.txt")) sawHello = 1; closedir(d); }
    CHECK(sawHello, "opendir lists the copy");

    char resolved[PATH_MAX];
    CHECK(realpath(HELLO, resolved) &&
          strstr(resolved, "/Frameworks/XSideTweaks/0123456789abcdef/Library/Application Support/XSTweakSupportTest/hello.txt"),
          "realpath gives the copy (%s)", resolved);

    struct attrlist al = { .bitmapcount = ATTR_BIT_MAP_COUNT, .commonattr = ATTR_CMN_OBJTYPE };
    struct { uint32_t length; fsobj_type_t type; } __attribute__((packed)) ab;
    CHECK(getattrlist(HELLO, &al, &ab, sizeof ab, 0) == 0 && ab.type == VREG, "getattrlist");

    void *tweak = dlopen("/Library/MobileSubstrate/DynamicLibraries/XSTweakSupportTest.dylib", RTLD_NOW);
    int (*value)(void) = tweak ? (int (*)(void))dlsym(tweak, "xs_test_value") : NULL;
    CHECK(value && value() == 42, "dlopen of a tweak's dylib (%s)", tweak ? "loaded" : dlerror());
    CHECK(dlopen("@loader_path/plain/libplain.dylib", RTLD_NOW) != NULL,
          "dlopen keeps its caller for @loader_path (%s)", dlerror());

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    CHECK([fm fileExistsAtPath:[kDir stringByAppendingPathComponent:@"hello.txt"]], "fileExistsAtPath:");
    CHECK([fm fileExistsAtPath:kDir isDirectory:&isDir] && isDir, "fileExistsAtPath:isDirectory:");
    CHECK([[fm contentsOfDirectoryAtPath:kDir error:NULL] containsObject:@"hello.txt"], "contentsOfDirectoryAtPath:error:");
    CHECK(![fm fileExistsAtPath:[kDir stringByAppendingPathComponent:@"missing.txt"]], "fileExistsAtPath: missing");
    NSBundle *b1 = [NSBundle bundleWithPath:@"/Library/Application Support/XSTweakSupportTestB.bundle"];
    CHECK([b1.bundleIdentifier isEqual:@"com.example.xstestb"], "bundleWithPath: finds a dropped bundle");
    NSBundle *b2 = [[NSBundle alloc] initWithPath:@"/var/jb/Library/Application Support/XSTweakSupportTestB.bundle"];
    CHECK([b2.bundleIdentifier isEqual:@"com.example.xstestb"], "initWithPath:");
    NSData *data = [NSData dataWithContentsOfFile:[kDir stringByAppendingPathComponent:@"hello.txt"]];
    CHECK([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] isEqual:expected], "dataWithContentsOfFile:");
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:[kDir stringByAppendingPathComponent:@"prefs.plist"]];
    CHECK([prefs[@"k"] isEqual:@"v"], "dictionaryWithContentsOfFile:");

    // Many threads at once: no lock, no shared buffer.
    pthread_t threads[8];
    long bad[8] = { 0 };
    for (int i = 0; i < 8; i++) pthread_create(&threads[i], NULL, hammer, &bad[i]);
    long total = 0;
    for (int i = 0; i < 8; i++) { pthread_join(threads[i], NULL); total += bad[i]; }
    CHECK(total == 0, "%ld wrong answers from 8 threads", total);

    if (failures) return 1;
    printf("ok: the library redirects (libc, dlopen, Foundation, 8 threads)\n");
    return 0;
}

static int runInert(void) {
    struct stat st;
    CHECK(open(HELLO, O_RDONLY) == -1, "open redirected while inert");
    CHECK(stat("/var/jb" HELLO, &st) == -1, "stat redirected while inert");
    CHECK(access(HELLO, F_OK) == -1, "access redirected while inert");
    CHECK(opendir(DIR_C) == NULL, "opendir redirected while inert");
    CHECK(dlopen("/Library/MobileSubstrate/DynamicLibraries/XSTweakSupportTest.dylib", RTLD_NOW) == NULL,
          "dlopen redirected while inert");
    CHECK(dlopen("@loader_path/plain/libplain.dylib", RTLD_NOW) != NULL, "dlopen keeps its caller while inert (%s)", dlerror());
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:[kDir stringByAppendingPathComponent:@"hello.txt"]],
          "NSFileManager redirected while inert");
    CHECK([NSBundle bundleWithPath:@"/Library/Application Support/XSTweakSupportTestB.bundle"] == nil,
          "NSBundle redirected while inert");
    CHECK(stat("/etc/hosts", &st) == 0, "other paths still work");
    if (failures) return 1;
    printf("ok: the library stays inert without XSideTweakPaths = true\n");
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "fixture")) return runFixture(argv[2]);
        if (argc == 2 && !strcmp(argv[1], "active")) return runActive();
        if (argc == 2 && !strcmp(argv[1], "inert")) return runInert();
        fprintf(stderr, "usage: %s fixture <json> | active | inert\n", argv[0]);
        return 2;
    }
}
