// Quick actions on the app's icon (spec §3), see XSShortcuts.m.

#import "XSCommon.h"

/// Wraps the app's quick-action entry points and its setShortcutItems:, in an app XSide signed
/// with its features.
/// Called from the library's constructor, before UIApplicationMain sets the delegates.
void XSInstallShortcuts(void);

/// XSide's quick actions are on the app's icon now (none when the app's own items take the 4 slots).
BOOL XSHasShortcuts(void);

/// Puts XSide's quick actions in the slots the app's own items leave, in the current language
/// (at launch and on each return: the app may have changed its items, the person the language).
void XSUpdateShortcuts(void);
