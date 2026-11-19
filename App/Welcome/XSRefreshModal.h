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

// Update flow (Slice 3): the same modal, worded for « Mise à jour ». Reuses Step/Error/Dismiss above.
/// Show it in its « checking the repo on your Mac » state.
void XSUpdateModalShow(void);
/// An update is available: show `title`/`message` with a primary button (`button`, e.g. « Télécharger
/// et installer ») that runs `install`, and a « Plus tard ». `install` leaves the modal up (working).
void XSUpdateModalOffer(NSString *title, NSString *message, NSString *button, void (^_Nullable install)(void));
/// Move to a working state with a title (download/install), `fraction` 0…1 fills the ring, < 0 keeps it.
void XSUpdateModalWorking(NSString *title, NSString *_Nullable detail, double fraction);
/// A terminal state with a single « Fermer » (the app isn't always replaced): `ok` shows a check,
/// otherwise a red cross. For « à jour », « installée », « à regarder sur le Mac ».
void XSUpdateModalDone(NSString *title, NSString *_Nullable message, BOOL ok);

/// A plain full-screen modal with a title, a message and a single « OK » button, in XSide's look.
/// Anthony wanted settings changes shown like the refresh modal, not as a top pill. Its own window,
/// below the refresh modal's level, so a refresh in progress stays on top. Safe from any thread;
/// does nothing when there is no scene. A second call replaces the text of the one already up.
void XSInfoModalShow(NSString *title, NSString *message);

/// How the phone reaches the Mac right now, so the hero draws the link to match (read from the
/// channel connection's path: Wi-Fi arcs, or a USB-C cable).
typedef NS_ENUM(NSInteger, XSLinkKind) { XSLinkUnknown = 0, XSLinkWiFi, XSLinkUSB };
/// Tell the modal which transport the connection uses. Safe from any thread, any time: it updates a
/// live modal's hero and is remembered for the next one.
void XSSetLinkKind(XSLinkKind kind);

NS_ASSUME_NONNULL_END
