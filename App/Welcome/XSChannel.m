// See XSChannel.h. The wire format (frames, MACs, exchanges) is in Sources/XSideCore/Channel.swift;
// the frames themselves are built and checked by XSChannelCore.

#import "XSChannel.h"
#import "XSChannelCore.h"
#import "XSSettingsCore.h"
#import "XSPill.h"
#import <Network/Network.h>

static const int XSPolicyDenied = -65570; // kDNSServiceErr_PolicyDenied: local network not allowed
static const NSTimeInterval XSFirstLineTimeout = 5;
/// XSide sends the refresh outcome within 2 min of `accepted`; a little more for the network.
static const NSTimeInterval XSOutcomeTimeout = 125;
/// A request the person made waits this long for the Mac (macOS may be asking whether XSide may
/// accept incoming connections: nothing gets through until it's answered).
static const NSTimeInterval XSPatientTimeout = 20;
/// Between two rounds of connection attempts, when every XSide found failed to answer.
static const NSTimeInterval XSRetryDelay = 2;
/// After this long without an answer, the person is told what the wait is about.
static const NSTimeInterval XSWaitingNotice = 3;

typedef NS_ENUM(NSInteger, XSChannelResult) {
    /// A signed reply from XSide (`reply`).
    XSChannelReplied,
    /// No XSide answered in time.
    XSChannelNotFound,
    /// The local network permission is off for this app.
    XSChannelDenied,
    /// An XSide answered but doesn't know this installation (bare `rejected`).
    XSChannelUnknownInstallation,
    /// A refresh was accepted, then no outcome came (the connection closed or 2 min passed).
    XSChannelNoOutcome,
    /// (Patient exchanges, not final) no answer yet: still trying.
    XSChannelWaiting,
};

/// Called on the main queue; `final` is NO for a refresh's `accepted` (the outcome follows) and for
/// `XSChannelWaiting`.
typedef void (^XSChannelHandler)(XSChannelResult result, NSDictionary *_Nullable reply, BOOL final);

/// One request: browse for XSide, try each one found until one answers with a signed reply.
/// Everything runs on its own serial queue; the handler gets results on the main queue.
@interface XSChannelExchange : NSObject
- (instancetype)initWithBody:(NSDictionary *)body findTimeout:(NSTimeInterval)findTimeout
              waitsOutcome:(BOOL)waitsOutcome handler:(XSChannelHandler)handler;
/// Keeps retrying the XSides found (every XSRetryDelay) until one answers or `findTimeout`
/// passes, and says `XSChannelWaiting` once after XSWaitingNotice. For requests the person made.
@property (nonatomic) BOOL patient;
- (void)start;
@end

/// Exchanges in flight, kept alive until they finish.
static NSMutableSet<XSChannelExchange *> *XSExchanges;

@implementation XSChannelExchange {
    NSDictionary *_body;
    NSTimeInterval _findTimeout;
    BOOL _waitsOutcome;
    XSChannelHandler _handler;
    NSString *_installationID;
    NSData *_secret;
    dispatch_queue_t _queue;
    nw_browser_t _browser;
    nw_connection_t _connection;
    NSMutableArray *_pending; // nw_endpoint_t found and not tried yet
    NSMutableArray *_found;   // every nw_endpoint_t found, to try again (patient)
    NSMutableArray *_refused; // those that answered "rejected": not tried again
    nw_endpoint_t _current;   // the one being tried
    BOOL _retryScheduled;
    BOOL _toldWaiting;
    NSString *_nonce;
    NSMutableData *_buffer;
    NSUInteger _generation; // bumped when a connection is dropped: its late callbacks are ignored
    BOOL _answered;         // the current connection gave its first signed line
    BOOL _accepted;         // a refresh was accepted: waiting for its outcome
    BOOL _denied;
    BOOL _sawRejected;
    BOOL _finished;
}

- (instancetype)initWithBody:(NSDictionary *)body findTimeout:(NSTimeInterval)findTimeout
              waitsOutcome:(BOOL)waitsOutcome handler:(XSChannelHandler)handler {
    if ((self = [super init])) {
        _body = body;
        _findTimeout = findTimeout;
        _waitsOutcome = waitsOutcome;
        _handler = [handler copy];
        _installationID = XSInstallationID();
        _secret = XSChannelSecret();
        _queue = dispatch_queue_create("io.github.xside.welcome.channel", DISPATCH_QUEUE_SERIAL);
        _pending = [NSMutableArray array];
        _found = [NSMutableArray array];
        _refused = [NSMutableArray array];
    }
    return self;
}

- (void)start {
    if (!XSExchanges) XSExchanges = [NSMutableSet set];
    [XSExchanges addObject:self];
    dispatch_async(_queue, ^{ [self browse]; });
}

- (void)deliver:(XSChannelResult)result reply:(NSDictionary *)reply final:(BOOL)final {
    XSChannelHandler handler = _handler;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(result, reply, final);
        if (final) [XSExchanges removeObject:self];
    });
}

- (void)finish:(XSChannelResult)result reply:(NSDictionary *)reply {
    if (_finished) return;
    _finished = YES;
    _generation++;
    if (_browser) nw_browser_cancel(_browser);
    if (_connection) nw_connection_cancel(_connection);
    _browser = nil;
    _connection = nil;
    [_pending removeAllObjects];
    [self deliver:result reply:reply final:YES];
}

/// Nobody answered: why, as far as we can tell.
- (void)finishUnanswered {
    [self finish:_sawRejected ? XSChannelUnknownInstallation : _denied ? XSChannelDenied : XSChannelNotFound reply:nil];
}

static BOOL XSIsPolicyDenied(nw_error_t error) {
    return error && nw_error_get_error_domain(error) == nw_error_domain_dns && nw_error_get_error_code(error) == XSPolicyDenied;
}

- (void)browse {
    if (!_installationID || !_secret) { [self finish:XSChannelNotFound reply:nil]; return; }
    nw_browse_descriptor_t descriptor = nw_browse_descriptor_create_bonjour_service("_xside._tcp", NULL);
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                                 NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_browser_t browser = nw_browser_create(descriptor, parameters);
    _browser = browser;
    nw_browser_set_queue(browser, _queue);
    nw_browser_set_browse_results_changed_handler(browser, ^(nw_browse_result_t old, nw_browse_result_t current, bool batchComplete) {
        if (self->_finished) return;
        if (!old && current) {
            self->_denied = NO; // results only come once the local network is allowed
            nw_endpoint_t endpoint = nw_browse_result_copy_endpoint(current);
            if (endpoint) {
                [self->_pending addObject:endpoint];
                [self->_found addObject:endpoint];
            }
            // Results only come once the person allowed the local network.
            dispatch_async(dispatch_get_main_queue(), ^{ XSSetChannelGranted(); });
        }
        if (batchComplete) [self tryNext];
    });
    nw_browser_set_state_changed_handler(browser, ^(nw_browser_state_t state, nw_error_t error) {
        if (self->_finished) return;
        if (XSIsPolicyDenied(error)) self->_denied = YES;
        else if (state == nw_browser_state_ready) self->_denied = NO; // allowed meanwhile
        if (state == nw_browser_state_failed && !self->_connection && self->_pending.count == 0) [self finishUnanswered];
    });
    nw_browser_start(browser);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_findTimeout * NSEC_PER_SEC)), _queue, ^{
        if (!self->_finished && !self->_accepted) [self finishUnanswered];
    });
    if (_patient) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(XSWaitingNotice * NSEC_PER_SEC)), _queue, ^{
            [self tellWaiting];
        });
    }
}

/// Once, while nothing answered yet: the person sees why it takes a while.
- (void)tellWaiting {
    if (!_patient) return;
    if (_finished || _answered || _toldWaiting) return;
    _toldWaiting = YES;
    [self deliver:XSChannelWaiting reply:nil final:NO];
}

/// Patient: every XSide found failed to answer; another round in a moment (never a tight loop:
/// one round at a time, XSRetryDelay apart, until the overall timeout).
- (void)scheduleRetry {
    if (!_patient || _retryScheduled || _finished || _connection || _pending.count) return;
    _retryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(XSRetryDelay * NSEC_PER_SEC)), _queue, ^{
        self->_retryScheduled = NO;
        if (self->_finished || self->_connection || self->_pending.count) return;
        for (id endpoint in self->_found) {
            if (![self->_refused containsObject:endpoint]) [self->_pending addObject:endpoint];
        }
        NSLog(@"[XSide] channel: trying again (%lu)", (unsigned long)self->_pending.count);
        [self tryNext];
    });
}

- (void)tryNext {
    if (_finished || _connection || _pending.count == 0) return;
    nw_endpoint_t endpoint = _pending.firstObject;
    [_pending removeObjectAtIndex:0];
    _current = endpoint;
    _nonce = XSNewNonce();
    NSData *line = XSSealRequest(_body, _installationID, _secret, XSMillis(NSDate.date), _nonce);
    if (!line) { [self finish:XSChannelNotFound reply:nil]; return; }
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                                 NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_connection_t connection = nw_connection_create(endpoint, parameters);
    _connection = connection;
    _buffer = [NSMutableData data];
    _answered = NO;
    NSUInteger generation = ++_generation;
    nw_connection_set_queue(connection, _queue);
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        if (generation != self->_generation || self->_finished) return;
        if (state == nw_connection_state_ready) {
            dispatch_data_t data = dispatch_data_create(line.bytes, line.length, self->_queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            nw_connection_send(connection, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t sendError) {});
            [self receiveOn:connection generation:generation];
        } else if (state == nw_connection_state_waiting || state == nw_connection_state_failed) {
            if (XSIsPolicyDenied(error)) self->_denied = YES;
            [self dropConnection];
        }
    });
    nw_connection_start(connection);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(XSFirstLineTimeout * NSEC_PER_SEC)), _queue, ^{
        if (generation == self->_generation && !self->_answered) [self dropConnection];
    });
}

/// This XSide didn't do: the next one, or (after `accepted`) the end without an outcome.
- (void)dropConnection {
    if (_finished) return;
    if (_connection) nw_connection_cancel(_connection);
    _connection = nil;
    _generation++;
    if (_accepted) { [self finish:XSChannelNoOutcome reply:nil]; return; }
    [self tellWaiting];
    [self tryNext];
    [self scheduleRetry]; // when there was no other one to try
}

- (void)receiveOn:(nw_connection_t)connection generation:(NSUInteger)generation {
    nw_connection_receive(connection, 1, 65536, ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        if (generation != self->_generation || self->_finished) return;
        if (content) {
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *bytes, size_t size) {
                [self->_buffer appendBytes:bytes length:size];
                return true;
            });
        }
        while (generation == self->_generation && !self->_finished) {
            NSRange newline = [self->_buffer rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0
                                                   range:NSMakeRange(0, self->_buffer.length)];
            if (newline.location == NSNotFound) break;
            NSData *line = [self->_buffer subdataWithRange:NSMakeRange(0, newline.location)];
            [self->_buffer replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
            [self handleLine:line];
        }
        if (generation != self->_generation || self->_finished) return;
        if (self->_buffer.length > 64 * 1024 || complete || error) { [self dropConnection]; return; }
        [self receiveOn:connection generation:generation];
    });
}

- (void)handleLine:(NSData *)line {
    NSDictionary *reply = nil;
    switch (XSOpenReply(line, _secret, _installationID, _nonce, &reply)) {
        case XSReplyUnknownInstallation:
            _sawRejected = YES;
            if (_current) [_refused addObject:_current]; // this XSide doesn't know us: not asked again
            [self dropConnection];
            return;
        case XSReplyInvalid:
            [self dropConnection];
            return;
        case XSReplyOK:
            break;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ XSSetChannelGranted(); });
    if (!_answered) {
        _answered = YES;
        if (_waitsOutcome && [reply[@"type"] isEqual:@"accepted"]) {
            // The refresh started: no other XSide is needed; the outcome comes on this connection.
            _accepted = YES;
            if (_browser) nw_browser_cancel(_browser);
            _browser = nil;
            [_pending removeAllObjects];
            [self deliver:XSChannelReplied reply:reply final:NO];
            NSUInteger generation = _generation;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(XSOutcomeTimeout * NSEC_PER_SEC)), _queue, ^{
                if (generation == self->_generation) [self finish:XSChannelNoOutcome reply:nil];
            });
            return;
        }
    }
    [self finish:XSChannelReplied reply:reply];
}
@end

// MARK: - Check-in at launch

static BOOL XSCheckInRunning;

void XSCheckIn(void (^done)(void)) {
    if (XSCheckInRunning || !XSChannelGranted() || !XSInstallationID() || !XSChannelSecret()) {
        if (done) dispatch_async(dispatch_get_main_queue(), done);
        return;
    }
    XSCheckInRunning = YES;
    NSDictionary *body = XSCheckInBody(XSCurrentSettings(), XSLastRefresh(), XSAppVersion());
    // Silent and short (spec: ≤ 3 s): nothing is shown, whatever happens.
    [[[XSChannelExchange alloc] initWithBody:body findTimeout:3 waitsOutcome:NO
                                     handler:^(XSChannelResult result, NSDictionary *reply, BOOL final) {
        XSCheckInRunning = NO;
        NSDictionary *settings = result == XSChannelReplied && [reply[@"type"] isEqual:@"settings"]
            ? XSSettingsFromJSONObject(reply[@"settings"]) : nil;
        if (settings) {
            XSAdoptSettings(settings);
            XSRecordCheckIn(NSDate.date);
            // How the last refresh went, as XSide knows it (it may have ended while the app was away).
            NSDictionary *outcome = XSRefreshOutcomeFromJSONObject(reply[@"lastRefresh"]);
            if (outcome) XSAdoptRefreshOutcome(outcome);
            NSDate *expiry = XSExpirationDate();
            if (expiry) XSScheduleReminder(expiry, NO); // the reminder switch may have changed
        }
        if (done) done();
    }] start];
}

// MARK: - Refresh from the phone

/// An exchange the person asked for: patient (macOS may be asking whether XSide may accept the
/// connection), a little longer the first time (iOS asks for the local network while browsing).
static XSChannelExchange *XSPatientExchange(NSDictionary *body, BOOL waitsOutcome, XSChannelHandler handler) {
    NSTimeInterval find = XSChannelGranted() ? XSPatientTimeout : 30;
    XSChannelExchange *exchange = [[XSChannelExchange alloc] initWithBody:body findTimeout:find
                                                             waitsOutcome:waitsOutcome handler:handler];
    exchange.patient = YES;
    return exchange;
}

/// "XSide : en attente du Mac…": no answer after a few seconds, still trying.
static void XSShowWaitingPill(void) {
    BOOL fr = XSFrench();
    XSPillContent *c = [XSPillContent new];
    c.lead = fr ? @"En attente du Mac…" : @"Waiting for the Mac…";
    c.hint = fr ? @"Accepte la connexion sur ton Mac si macOS le demande."
                : @"Accept the connection on your Mac if macOS asks.";
    c.busy = YES;
    XSShowPill(c);
}

static XSPillContent *XSPill(NSString *lead, NSString *hint, XSPillTone tone, NSTimeInterval duration) {
    XSPillContent *c = [XSPillContent new];
    c.lead = lead;
    c.hint = hint;
    c.tone = tone;
    c.duration = duration;
    return c;
}

/// The pill for a request no XSide answered.
static XSPillContent *XSUnansweredPill(XSChannelResult result) {
    BOOL fr = XSFrench();
    switch (result) {
        case XSChannelDenied: {
            XSPillContent *c = XSPill(fr ? @"Réseau local non autorisé" : @"Local network not allowed",
                                      [NSString stringWithFormat:fr ? @"Autorise le réseau local dans %@" : @"Allow Local Network in %@",
                                       XSSettingsPath()], XSPillToneOrange, 8);
            c.buttonTitle = fr ? @"Réglages" : @"Settings";
            c.action = ^{ XSOpenAppSettings(); };
            return c;
        }
        case XSChannelUnknownInstallation:
            return XSPill(fr ? @"XSide sur ton Mac ne reconnaît pas cette app" : @"XSide on your Mac doesn't know this app",
                          fr ? @"Rafraîchis-la une fois depuis XSide sur le Mac qui l'a installée."
                             : @"Refresh it once from XSide on the Mac that installed it.", XSPillToneOrange, 8);
        default:
            return XSPill(fr ? @"Mac introuvable : XSide est-il ouvert, sur le même Wi-Fi ?"
                             : @"Mac not found: is XSide open, on the same Wi-Fi?", nil, XSPillToneOrange, 8);
    }
}

/// A refresh that failed: a notification (seen even if the app was left), and the pill when the
/// app is on screen, else at the next launch.
static void XSTellFailure(NSString *reasonKey) {
    BOOL fr = XSFrench();
    NSString *text = [NSString stringWithFormat:fr ? @"Rafraîchissement impossible : %@" : @"Couldn't refresh: %@",
                      XSReasonText(reasonKey, fr)];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        XSShowPill(XSPill(text, nil, XSPillToneOrange, 8));
    } else {
        XSSetPendingFailure(reasonKey ?: @"unknown", NSDate.date);
    }
    UNUserNotificationCenter *center = XSCenter();
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        if (settings.authorizationStatus != UNAuthorizationStatusAuthorized
            && settings.authorizationStatus != UNAuthorizationStatusProvisional) return;
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = XSAppName();
        content.body = text;
        content.sound = UNNotificationSound.defaultSound;
        [center addNotificationRequest:[UNNotificationRequest requestWithIdentifier:@"io.github.xside.welcome.refreshFailed"
                                                                            content:content trigger:nil]
                 withCompletionHandler:^(NSError *error) { NSLog(@"[XSide] refresh failure notified, error %@", error); }];
    }];
}

static void XSResumeAutoRefresh(void);

static BOOL XSRefreshRunning;
static UIBackgroundTaskIdentifier XSRefreshTask;
static BOOL XSHasRefreshTask;

static void XSEndRefreshTask(void) {
    if (!XSHasRefreshTask) return;
    XSHasRefreshTask = NO;
    [UIApplication.sharedApplication endBackgroundTask:XSRefreshTask];
}

/// When XSide accepted the refresh in progress (what its later outcome is matched against).
static NSDate *XSAcceptedAt;

static void XSStartRefresh(void);

void XSRequestRefresh(void) {
    if (XSRefreshRunning) return;
    BOOL fr = XSFrench();
    if (!XSInstallationID() || !XSChannelSecret()) {
        XSShowPill(XSPill(fr ? @"Pas encore de lien avec XSide" : @"No link with XSide yet",
                          fr ? @"Rafraîchis-la une fois depuis XSide sur ton Mac pour pouvoir le faire d'ici."
                             : @"Refresh it once from XSide on your Mac to be able to do it from here.", XSPillToneNeutral, 6));
        return;
    }
    XSRefreshRunning = YES;
    if ([XSDerivedLevel(XSCurrentSettings()) isEqual:@"none"]) { XSStartRefresh(); return; } // "Aucun": never ask
    // A failure is told by a notification: the first Refresh is the moment to ask for them,
    // saying why, before the request (one iOS prompt at a time).
    [XSCenter() getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        BOOL ask = settings.authorizationStatus == UNAuthorizationStatusNotDetermined;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ask) { XSStartRefresh(); return; }
            BOOL french = XSFrench();
            XSPillContent *why = XSPill(french ? @"Autorise les notifications" : @"Allow notifications",
                                        french ? @"XSide s'en sert pour te dire si le rafraîchissement échoue."
                                               : @"XSide uses them to tell you if the refresh fails.", XSPillToneNeutral, 0);
            XSShowPill(why);
            [XSCenter() requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                                      completionHandler:^(BOOL granted, NSError *error) {
                NSLog(@"[XSide] notifications: asked before a refresh, granted %d, error %@", granted, error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSDate *expiry = XSExpirationDate();
                    if (granted && expiry) XSScheduleReminder(expiry, NO);
                    XSStartRefresh();
                });
            }];
        });
    }];
}

static void XSStartRefresh(void) {
    BOOL fr = XSFrench();
    XSPillContent *asking = XSPill(fr ? @"Demande à XSide sur ton Mac…" : @"Asking XSide on your Mac…",
                                   fr ? @"L'app va se fermer quelques secondes pendant le rafraîchissement."
                                      : @"The app will close for a few seconds while it refreshes.", XSPillToneNeutral, 0);
    asking.busy = YES;
    XSShowPill(asking);
    [XSPatientExchange(XSRefreshBody(), YES, ^(XSChannelResult result, NSDictionary *reply, BOOL final) {
        BOOL french = XSFrench();
        NSString *type = reply[@"type"];
        if (result == XSChannelWaiting) { XSShowWaitingPill(); return; }
        if (final) {
            XSRefreshRunning = NO;
            XSEndRefreshTask();
        }
        if (result == XSChannelNoOutcome) {
            // Accepted, then silence (app suspended, connection lost, 2 min passed). A success
            // replaces the app, whose new signature clears this; otherwise it must not vanish:
            // remembered, and XSide asked at once how it went.
            XSSetPendingFailure(XSNoOutcomeKey, XSAcceptedAt ?: NSDate.date);
            XSCheckIn(^{ XSShowPendingPill(); });
            return;
        }
        if (result != XSChannelReplied) {
            XSShowPill(XSUnansweredPill(result));
            return;
        }
        if ([type isEqual:@"accepted"]) {
            XSAcceptedAt = NSDate.date;
            XSShowPill(XSPill(french ? @"Demande envoyée, l'app va se fermer quelques secondes"
                                     : @"Request sent, the app will close for a few seconds", nil, XSPillToneNeutral, 6));
            // Keeps the connection a little if the person leaves the app, to hear a failure.
            XSEndRefreshTask();
            XSRefreshTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"XSide refresh"
                                                                     expirationHandler:^{ XSEndRefreshTask(); }];
            XSHasRefreshTask = XSRefreshTask != UIBackgroundTaskInvalid;
        } else if ([type isEqual:@"refreshed"]) {
            XSRecordRefresh(YES, nil, NSDate.date); // the new app replaces this one right after
        } else if ([type isEqual:@"failed"]) {
            NSString *reason = [reply[@"reasonKey"] isKindOfClass:NSString.class] ? reply[@"reasonKey"] : @"unknown";
            XSRecordRefresh(NO, reason, NSDate.date);
            XSTellFailure(reason);
        } else if ([type isEqual:@"busy"]) {
            XSShowPill(XSPill(french ? @"XSide la rafraîchit déjà, ou vient de le faire"
                                     : @"XSide is already refreshing it, or just did",
                              french ? @"Une demande depuis l'iPhone toutes les 10 minutes au plus. Réessaie un peu plus tard."
                                     : @"One request from the phone every 10 minutes at most. Try again a little later.",
                              XSPillToneNeutral, 6));
        } else if ([type isEqual:@"deviceUnreachable"]) {
            NSString *device = XSDeviceKind();
            XSShowPill(XSPill([NSString stringWithFormat:french ? @"Ton Mac ne voit pas cet %@" : @"Your Mac can't see this %@", device],
                              french ? @"Déverrouille-le, et vérifie qu'il est sur le même Wi-Fi que le Mac ou branché en USB."
                                     : @"Unlock it, and check it's on the same Wi-Fi as the Mac or plugged in over USB.",
                              XSPillToneOrange, 8));
        } else if ([type isEqual:@"paused"]) {
            BOOL byDevice = [reply[@"by"] isEqual:@"device"];
            NSString *who = byDevice ? [NSString stringWithFormat:french ? @"cet %@" : @"this %@", XSDeviceKind()]
                                     : (french ? @"le Mac" : @"the Mac");
            XSPillContent *c = XSPill(french ? @"Rafraîchissement automatique désactivé pour cette app"
                                             : @"Automatic refresh is off for this app",
                                      [NSString stringWithFormat:french ? @"Désactivé depuis %@. Réactive-le pour que XSide la rafraîchisse."
                                                                        : @"Turned off from %@. Turn it back on for XSide to refresh it.", who],
                                      XSPillToneOrange, 8);
            c.buttonTitle = french ? @"Réactiver" : @"Turn on";
            c.action = ^{ XSResumeAutoRefresh(); };
            XSShowPill(c);
        } else {
            XSShowPill(XSPill(french ? @"XSide n'a pas pu lancer le rafraîchissement" : @"XSide couldn't start the refresh",
                              nil, XSPillToneOrange, 6));
        }
    }) start];
}

/// "Réactiver" after a refresh refused as paused: on at once on the phone, then told to XSide.
static void XSResumeAutoRefresh(void) {
    XSSetDeviceSetting(@"autoRefresh", @YES);
    [XSPatientExchange(XSSetAutoRefreshBody(YES), NO, ^(XSChannelResult result, NSDictionary *reply, BOOL final) {
        BOOL fr = XSFrench();
        if (result == XSChannelWaiting) { XSShowWaitingPill(); return; }
        if (result != XSChannelReplied) {
            XSPillContent *c = XSUnansweredPill(result);
            c.hint = c.hint ?: (fr ? @"Réactivé sur l'iPhone : XSide le saura à la prochaine connexion."
                                   : @"Turned on here: XSide will know at the next connection.");
            XSShowPill(c);
            return;
        }
        NSDictionary *settings = [reply[@"type"] isEqual:@"settings"] ? XSSettingsFromJSONObject(reply[@"settings"]) : nil;
        if (settings) XSAdoptSettings(settings);
        XSPillContent *c = XSPill(fr ? @"Rafraîchissement automatique réactivé" : @"Automatic refresh turned back on",
                                  nil, XSPillToneNeutral, 6);
        c.buttonTitle = fr ? @"Rafraîchir" : @"Refresh";
        c.action = ^{ XSRequestRefresh(); };
        XSShowPill(c);
    }) start];
}
