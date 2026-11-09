// The path rule of XSideTweakSupport.dylib, in plain C (no allocation, no lock, no libc call that
// the library interposes): safe from any thread, from the earliest open()/stat(). Mirror of
// Sources/XSideCore/TweakPaths.swift; both run Tests/XSideCoreTests/Fixtures/tweak-paths-fixture.json
// (scripts/test-tweak-support.sh). Change them together.
#ifndef XSTweakPathsCore_h
#define XSTweakPathsCore_h

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns 1 and writes `<tweaksRoot>/<package><rest>` (NUL-terminated) to `out` for the first
// package where `exists` says that file is there; returns 0 otherwise (`out` then holds an empty
// string when outSize >= PATH_MAX, where candidates are built in place, and is untouched when smaller).
// `<rest>` is `path` without a leading `/var/jb`, and must start with `/` + one of the copied
// prefixes (TweakAnalyzer.copiedPrefixes). A relative path, an empty / `.` / `..` component, a path
// or result of PATH_MAX bytes or more, or a package that is neither 16 lowercase hex nor
// `deps/<packageID>` is never redirected, nor is a library iOS ships (a file directly in /usr/lib
// named like TweakClassifier.iOSUsrLibNames, or anything in /usr/lib/system/ or /usr/lib/swift/). For `/Library/Application Support/<X>.bundle…`, a
// package's `<tweaksRoot>/<package>/<X>.bundle…` (a dropped bundle) is tried after its own copy.
int xs_tweak_redirect(const char *path, const char *tweaksRoot, const char *const *packages, size_t count,
                      int (*exists)(const char *), char *out, size_t outSize);

// 1 when `name` is a package folder under Frameworks/XSideTweaks/ (16 lowercase hex, or
// `deps/<packageID>`).
int xs_tweak_is_package_folder(const char *name);

#ifdef __cplusplus
}
#endif

#endif
