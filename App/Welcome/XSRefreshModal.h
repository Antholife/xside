// A full-screen modal shown in the host app for a phone-triggered refresh, replacing the small top
// pill (Anthony wanted a real modal). It shows the iPhone <-> Mac connection animating, then the
// work, with a progress ring. Follows the system light/dark appearance. Everything here is main
// thread, and inert/safe when there is no scene (it just does nothing, like the rest of the dylib).

#import "XSCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// Show the modal in its « connecting to your Mac » state. `willBackUp`: the refresh snapshots the
/// data first, so the work step is announced as « Sauvegarde et rafraîchissement ».
void XSRefreshModalShow(BOOL willBackUp);
/// The Mac accepted: the connection is made, move to the work phase (« l'app va se fermer »).
void XSRefreshModalWorking(void);
/// A named progress step with a fraction 0...1, or < 0 for indeterminate (Slice 2: live streaming).
void XSRefreshModalStep(NSString *title, NSString *_Nullable detail, double fraction);
/// The request failed or went unheard: error state, with « Réessayer » (runs `retry`) and « Fermer ».
void XSRefreshModalError(NSString *title, NSString *_Nullable message, void (^_Nullable retry)(void));
/// Remove the modal (nothing if it isn't up).
void XSRefreshModalDismiss(void);

NS_ASSUME_NONNULL_END
