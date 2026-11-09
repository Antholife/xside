// Link-time stand-in for CydiaSubstrate, so the test tweaks are linked as a jailbreak tweak is:
// built as CydiaSubstrate.framework/CydiaSubstrate with the install name a jailbreak uses
// (/Library/Frameworks/… rootful, @rpath/… rootless). Never copied anywhere: XSide rewrites that
// load command to its embedded ElleKit, which exports the same functions. If this stub were ever
// loaded, nothing would be hooked.
// Built by scripts/make-tweak-test-kit.sh (never shipped).
#include <objc/objc.h>

__attribute__((visibility("default"))) void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old) {
    (void)_class; (void)message; (void)hook;
    if (old) *old = 0;
}

__attribute__((visibility("default"))) void MSHookFunction(void *symbol, void *replace, void **result) {
    (void)symbol; (void)replace;
    if (result) *result = 0;
}
