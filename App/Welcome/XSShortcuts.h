// Quick actions on the app's icon (spec §3), see XSShortcuts.m.

#import "XSCommon.h"

/// Wraps the app's quick-action entry points, when XSide added quick actions to the app.
/// Called from the library's constructor, before UIApplicationMain sets the delegates.
void XSInstallShortcuts(void);

/// XSide added quick actions to this app's icon (none when the app already had 4).
BOOL XSHasShortcuts(void);
