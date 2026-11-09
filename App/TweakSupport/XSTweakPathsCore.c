// See XSTweakPathsCore.h. Hand-written byte loops only: this runs inside interposed open()/stat(),
// before anything else is ready, so it calls nothing that could allocate, lock or be interposed.
#include "XSTweakPathsCore.h"
#include <limits.h>

static const char *const kPrefixes[] = {
    // TweakAnalyzer.copiedPrefixes, in the same order.
    "Library/MobileSubstrate/DynamicLibraries/", "usr/lib/TweakInject/",
    "Library/Application Support/", "Library/Frameworks/", "usr/lib/",
};
static const char kBundlePrefix[] = "Library/Application Support/";
// Libraries iOS ships: a tweak's copy never answers for them. TweakClassifier.iOSUsrLibNames (the
// fixture's protectedNames, checked against it by TweakPathsTests), plus /usr/lib/system/ and
// /usr/lib/swift/. /System/ is never a copied prefix.
static const char *const kSystemNames[] = {
    "libaccessibility", "libapple_nghttp2", "libarchive", "libate", "libboringssl", "libbsm", "libbz2", "libc",
    "libc++", "libc++abi", "libcharset", "libcmph", "libcompression", "libcoretls", "libcoretls_cfhelpers",
    "libcupolicy", "libdl", "libenergytrace", "libexslt", "libextension", "libfosl_dynamic", "libgcc_s",
    "libiconv", "libicucore", "libinfo", "liblangid", "liblzma", "libm", "libmecab", "libmis",
    "libmobilegestalt", "libnetwork", "libobjc", "libobjc-trampolines", "libpam", "libpcap", "libprequelite",
    "libpthread", "libresolv", "libsandbox", "libsqlite3", "libstdc++", "libsystem", "libtailspin", "libutil",
    "libxml2", "libxslt", "libz",
};
static const char kUsrLib[] = "usr/lib/";
static const char *const kSystemFolders[] = { "usr/lib/system/", "usr/lib/swift/" };
static const char kRootless[] = "/var/jb/";
static const char kDeps[] = "deps/";
static const char kBundleExt[] = ".bundle";

static size_t xs_len(const char *s, size_t max) {
    size_t n = 0;
    while (n < max && s[n]) n++;
    return n;
}

static int xs_starts(const char *s, const char *prefix, size_t *prefixLen) {
    size_t i = 0;
    for (; prefix[i]; i++) if (s[i] != prefix[i]) return 0;
    if (prefixLen) *prefixLen = i;
    return 1;
}

// No empty, "." or ".." component; a trailing "/" is fine. `p` starts with "/".
static int xs_clean(const char *p, size_t n) {
    size_t i = 1;
    while (i <= n) {
        size_t start = i;
        while (i < n && p[i] != '/') i++;
        size_t len = i - start;
        if (len == 0 && i < n) return 0;                                   // "//"
        if (len == 1 && p[start] == '.') return 0;
        if (len == 2 && p[start] == '.' && p[start + 1] == '.') return 0;
        i++;
    }
    return 1;
}

// `body` is the path after its "/" (and after /var/jb). A file directly in /usr/lib whose name's
// first dot-separated part is an iOS library name, in any case, or anything in /usr/lib/system/
// or /usr/lib/swift/.
static int xs_system_library(const char *body) {
    for (size_t k = 0; k < sizeof kSystemFolders / sizeof *kSystemFolders; k++)
        if (xs_starts(body, kSystemFolders[k], NULL)) return 1;
    size_t u;
    if (!xs_starts(body, kUsrLib, &u)) return 0;
    const char *file = body + u;
    for (const char *s = file; *s; s++) if (*s == '/') return 0;
    while (*file == '.') file++;
    char base[64];
    size_t n = 0;
    for (; file[n] && file[n] != '.'; n++) {
        if (n + 1 >= sizeof base) return 0;                    // longer than any iOS name
        char c = file[n];
        base[n] = (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
    }
    if (n == 0) return 0;
    base[n] = 0;
    for (size_t k = 0; k < sizeof kSystemNames / sizeof *kSystemNames; k++) {
        const char *a = kSystemNames[k];
        size_t i = 0;
        while (a[i] && a[i] == base[i]) i++;
        if (!a[i] && !base[i]) return 1;
    }
    return 0;
}

static int xs_alnum(char c) { return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'); }

int xs_tweak_is_package_folder(const char *name) {
    if (!name) return 0;
    size_t n = xs_len(name, 256);
    if (n == 16) {
        int hex = 1;
        for (size_t i = 0; i < 16; i++) {
            char c = name[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) { hex = 0; break; }
        }
        if (hex) return 1;
    }
    size_t d;
    if (!xs_starts(name, kDeps, &d)) return 0;
    const char *id = name + d;
    size_t idLen = n - d;
    if (idLen == 0 || idLen > 128 || !xs_alnum(id[0])) return 0;   // DebControl.isValidPackageID
    for (size_t i = 0; i < idLen; i++) {
        char c = id[i];
        if (!(xs_alnum(c) || c == '+' || c == '-' || c == '.')) return 0;
    }
    return 1;
}

// Writes root + "/" + package + sep + tail into buf[PATH_MAX]; 0 when that is PATH_MAX bytes or more.
static int xs_join(char *buf, const char *root, const char *package, const char *sep, const char *tail) {
    const char *parts[5] = { root, "/", package, sep, tail };
    size_t n = 0;
    for (int k = 0; k < 5; k++)
        for (const char *s = parts[k]; *s; s++) { if (n + 1 >= PATH_MAX) return 0; buf[n++] = *s; }
    buf[n] = 0;
    return 1;
}

static int xs_emit(const char *candidate, char *out, size_t outSize) {
    size_t n = xs_len(candidate, PATH_MAX);
    if (n + 1 > outSize) return 0;
    for (size_t i = 0; i <= n; i++) out[i] = candidate[i];
    return 1;
}

int xs_tweak_redirect(const char *path, const char *tweaksRoot, const char *const *packages, size_t count,
                      int (*exists)(const char *), char *out, size_t outSize) {
    if (!path || !tweaksRoot || !packages || !exists || !out || outSize == 0) return 0;
    if (path[0] != '/' || tweaksRoot[0] != '/') return 0;
    size_t n = xs_len(path, PATH_MAX);
    if (n >= PATH_MAX || xs_len(tweaksRoot, PATH_MAX) >= PATH_MAX) return 0;
    if (!xs_clean(path, n)) return 0;

    const char *rest = path;
    size_t r;
    if (xs_starts(path, kRootless, &r)) rest = path + r - 1;               // keeps its "/"
    const char *body = rest + 1;
    size_t prefixLen = 0;
    int matched = 0;
    for (size_t k = 0; k < sizeof kPrefixes / sizeof *kPrefixes; k++) {
        if (xs_starts(body, kPrefixes[k], &prefixLen) && body[prefixLen]) { matched = 1; break; }
    }
    if (!matched || xs_system_library(body)) return 0;
    const char *afterPrefix = body + prefixLen;

    // "/Library/Application Support/<X>.bundle…": a dropped bundle lives at its package's root.
    int bundle = 0;
    size_t bp;
    if (xs_starts(body, kBundlePrefix, &bp) && bp == prefixLen) {
        size_t first = 0;
        while (afterPrefix[first] && afterPrefix[first] != '/') first++;
        size_t ext = sizeof kBundleExt - 1;
        if (first > ext) {
            bundle = 1;
            for (size_t i = 0; i < ext; i++) if (afterPrefix[first - ext + i] != kBundleExt[i]) { bundle = 0; break; }
        }
    }

    // Built straight in `out` when it holds PATH_MAX bytes (the library's case: one buffer per call).
    char local[PATH_MAX];
    char *candidate = outSize >= PATH_MAX ? out : local;
    for (size_t i = 0; i < count; i++) {
        const char *package = packages[i];
        if (!xs_tweak_is_package_folder(package)) continue;
        if ((xs_join(candidate, tweaksRoot, package, "", rest) && exists(candidate)) ||
            (bundle && xs_join(candidate, tweaksRoot, package, "/", afterPrefix) && exists(candidate)))
            return candidate == out ? 1 : xs_emit(candidate, out, outSize);
    }
    if (candidate == out) out[0] = 0;
    return 0;
}
