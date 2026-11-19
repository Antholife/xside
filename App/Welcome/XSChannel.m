// See XSChannel.h. The wire format (frames, MACs, exchanges) is in Sources/XSideCore/Channel.swift;
// the frames themselves are built and checked by XSChannelCore.

#import "XSChannel.h"
#import "XSChannelCore.h"
#import "XSSettingsCore.h"
#import "XSPill.h"
#import "XSRunMarker.h"
#import "XSRefreshModal.h"
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
    /// (Watches, final) the watch that answered is over: XSide closed it (its 5 min, or a newer
    /// one), the network went, no line for XSWatchKeepAliveTimeout, a line didn't check out, or
    /// the app closed it.
    XSChannelWatchEnded,
};

/// Called on the main queue; `final` is NO for a refresh's `accepted` (the outcome follows), for
/// `XSChannelWaiting`, and for each line of a watch (until `XSChannelWatchEnded`).
typedef void (^XSChannelHandler)(XSChannelResult result, NSDictionary *_Nullable reply, BOOL final);

/// One request: browse for XSide, try each one found until one answers with a signed reply.
/// Everything runs on its own serial queue; the handler gets results on the main queue.
@interface XSChannelExchange : NSObject
- (instancetype)initWithBody:(NSDictionary *)body findTimeout:(NSTimeInterval)findTimeout
              waitsOutcome:(BOOL)waitsOutcome handler:(XSChannelHandler)handler;
/// Keeps retrying the XSides found (every XSRetryDelay) until one answers or `findTimeout`
/// passes, and says `XSChannelWaiting` once after XSWaitingNotice. For requests the person made.
@property (nonatomic) BOOL patient;
/// A watch (device feedback 4): after its first signed reply, the connection stays open and each
/// later line is delivered (not final) once XSOpenWatchLineV2 accepts it; the first one that doesn't,
/// a silence of XSWatchKeepAliveTimeout, or the connection's end finishes it (XSChannelWatchEnded).
@property (nonatomic) BOOL watches;
- (void)start;
/// Ends it now (the app left the foreground): closes the connection; the handler gets the end.
- (void)cancel;
/// A watch that answered: writes `bye` on it (a sealed request, so XSide knows the app left the
/// front and didn't vanish), then ends it like `cancel`. Anything else: `cancel`.
- (void)closeSayingBye;
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
    BOOL _watching;          // a watch that answered: later lines are watch lines
    int64_t _seq;            // the last watch line taken
    CFAbsoluteTime _lastLine; // when the last watch line came
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

- (void)cancel {
    dispatch_async(_queue, ^{
        if (self->_watching) [self finish:XSChannelWatchEnded reply:nil];
        else [self finish:XSChannelNotFound reply:nil];
    });
}

- (void)closeSayingBye {
    dispatch_async(_queue, ^{
        nw_connection_t connection = self->_connection;
        if (!self->_watching || !connection || self->_finished) {
            [self finish:self->_watching ? XSChannelWatchEnded : XSChannelNotFound reply:nil];
            return;
        }
        NSData *line = XSSealRequestV2(XSByeBody(), self->_secret, XSMillis(NSDate.date), XSNewNonce());
        if (!line) { [self finish:XSChannelWatchEnded reply:nil]; return; }
        dispatch_data_t data = dispatch_data_create(line.bytes, line.length, self->_queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        nw_connection_send(connection, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
            [self finish:XSChannelWatchEnded reply:nil];
        });
        // The network may not take it: closed all the same, a second later.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), self->_queue, ^{
            [self finish:XSChannelWatchEnded reply:nil];
        });
    });
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
        if (!self->_finished && !self->_accepted && !self->_watching) [self finishUnanswered];
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
        NSLog(@"XSide: channel: trying again (%lu)", (unsigned long)self->_pending.count);
        [self tryNext];
    });
}

- (void)tryNext {
    if (_finished || _connection || _pending.count == 0) return;
    nw_endpoint_t endpoint = _pending.firstObject;
    [_pending removeObjectAtIndex:0];
    _current = endpoint;
    _nonce = XSNewNonce();
    // Channel v2 only (encrypted, a token instead of the installation id; mega review C2): XSide
    // answers in the version it gets, and this library opens v2 replies only.
    NSData *line = XSSealRequestV2(_body, _secret, XSMillis(NSDate.date), _nonce);
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
            // Tell the modal's hero which transport this connection actually uses (Wi-Fi, else USB).
            nw_path_t path = nw_connection_copy_current_path(connection);
            if (path) XSSetLinkKind(nw_path_uses_interface_type(path, nw_interface_type_wifi) ? XSLinkWiFi : XSLinkUSB);
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
    if (_watching) { [self finish:XSChannelWatchEnded reply:nil]; return; }
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

/// A watch's dead-connection check: no line for XSWatchKeepAliveTimeout ends it.
- (void)checkKeepAlive:(NSUInteger)generation {
    if (generation != _generation || _finished) return;
    CFAbsoluteTime quiet = CFAbsoluteTimeGetCurrent() - _lastLine;
    if (quiet >= XSWatchKeepAliveTimeout) {
        NSLog(@"XSide: watch: no line for %.0f s, closed", quiet);
        [self dropConnection];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((XSWatchKeepAliveTimeout - quiet + 0.5) * NSEC_PER_SEC)), _queue, ^{
        [self checkKeepAlive:generation];
    });
}

/// After « accepted », give up only once XSOutcomeTimeout has passed since the LAST line: every
/// progress frame (Slice 2) pushes `_lastLine` forward, so streaming re-arms this instead of tripping it.
- (void)scheduleOutcomeTimeout:(NSUInteger)generation {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(XSOutcomeTimeout * NSEC_PER_SEC)), _queue, ^{
        if (generation != self->_generation || self->_finished) return;
        if (CFAbsoluteTimeGetCurrent() - self->_lastLine >= XSOutcomeTimeout) {
            [self finish:XSChannelNoOutcome reply:nil];
        } else {
            [self scheduleOutcomeTimeout:generation];
        }
    });
}

- (void)handleLine:(NSData *)line {
    NSDictionary *reply = nil;
    if (_watching) {
        // Every line is checked: signed for this watch, the next one. The first that isn't ends it.
        if (XSOpenWatchLineV2(line, _secret, _nonce, _seq, &reply) != XSReplyOK) {
            NSLog(@"XSide: watch: a line didn't check out (after %lld), closed", (long long)_seq);
            [self dropConnection];
            return;
        }
        _seq++;
        _lastLine = CFAbsoluteTimeGetCurrent();
        if ([reply[@"type"] isEqual:@"live"]) [self deliver:XSChannelReplied reply:reply final:NO];
        return;
    }
    switch (XSOpenReplyV2(line, _secret, _nonce, &reply)) {
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
            _lastLine = CFAbsoluteTimeGetCurrent();
            if (_browser) nw_browser_cancel(_browser);
            _browser = nil;
            [_pending removeAllObjects];
            [self deliver:XSChannelReplied reply:reply final:NO];
            // The outcome (or a progress frame, Slice 2) must come within XSOutcomeTimeout of the
            // last line, not of « accepted »: streaming keeps pushing _lastLine forward.
            [self scheduleOutcomeTimeout:_generation];
            return;
        }
        if (_watches && [reply[@"type"] isEqual:@"settings"]) {
            // The watch's check-in answer: no other XSide is needed; the connection stays open.
            _watching = YES;
            _seq = 0;
            _lastLine = CFAbsoluteTimeGetCurrent();
            if (_browser) nw_browser_cancel(_browser);
            _browser = nil;
            [_pending removeAllObjects];
            [self deliver:XSChannelReplied reply:reply final:NO];
            [self checkKeepAlive:_generation];
            return;
        }
    }
    if (_accepted && [reply[@"type"] isEqual:@"progress"]) {
        // A live step of the running refresh (Slice 2): keep the connection open for the next line
        // and feed the modal. Not final; the outcome (or the app being replaced) ends the exchange.
        _lastLine = CFAbsoluteTimeGetCurrent();
        [self deliver:XSChannelReplied reply:reply final:NO];
        return;
    }
    if (_accepted && [reply[@"type"] isEqual:@"update"]) {
        // The update flow (Slice 3): « downloading »/« installing » keep streaming; every other
        // state (upToDate, available, installed, needsMac) is the end of this exchange.
        NSString *state = reply[@"state"];
        if ([state isEqual:@"downloading"] || [state isEqual:@"installing"]) {
            _lastLine = CFAbsoluteTimeGetCurrent();
            [self deliver:XSChannelReplied reply:reply final:NO];
            return;
        }
        [self finish:XSChannelReplied reply:reply];
        return;
    }
    [self finish:XSChannelReplied reply:reply];
}
@end

// MARK: - Check-in at launch

static BOOL XSCheckInRunning;
/// A Refresh asked from here is in progress.
static BOOL XSRefreshRunning;
/// An "Rafraîchissement automatique" change to tell once the running check-in ends (mega review
/// minor 2: that check-in may have been built before the change was loaded, so it can't be
/// trusted to carry it).
static BOOL XSTellQueued;
static void XSTellAutoRefreshChangeNow(void);

/// The running check-in (or tell) is over: a tell that waited for it goes now, after the caller
/// adopted the reply (dispatched, so it runs after the rest of the caller's handler).
static void XSCheckInEnded(void) {
    XSCheckInRunning = NO;
    if (!XSTellQueued) return;
    XSTellQueued = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ XSTellAutoRefreshChangeNow(); });
}
static XSPillContent *XSUnansweredPill(XSChannelResult result);

/// "Touche pour voir Réglages > Apps > YouTube > Réglages XSide.": where the settings are.
static NSString *XSWhereHint(BOOL fr) {
    return [NSString stringWithFormat:fr ? @"Touche pour voir %@ > %@." : @"Tap to see %@ > %@.",
            XSSettingsPath(), XSSettingsRowShown()];
}

/// The one pill for a change of settings (device feedback round 2, P2): which one and how when it
/// is one ("XSide : rafraîchissement automatique réactivé depuis XSide sur ton Mac"), else the
/// list. From the Mac (`byMac`) a tap (or Voir) opens the app's page in iOS Settings, where XSide's
/// row is. `others`: fields the Mac changed in the reply to the phone's own change.
/// The end of the Mac's pause of a while, from the last adopted reply (review D–G, minor 7).
static NSDate *XSMacPauseEnd;

static XSPillContent *XSChangePill(NSArray<NSString *> *fields, BOOL byMac, NSArray<NSString *> *others) {
    BOOL fr = XSFrench();
    NSDictionary *now = XSCurrentSettings();
    NSDictionary *texts = XSChangeTexts(fields, now, byMac, fr);
    XSPillContent *c = [XSPillContent new];
    c.lead = texts[@"lead"];
    NSMutableArray<NSString *> *hint = [NSMutableArray array];
    if (texts[@"list"]) [hint addObject:texts[@"list"]];
    // Paused from the Mac for a while: say it comes back by itself, and when.
    BOOL macPause = (byMac && [fields containsObject:@"autoRefresh"]) || [others containsObject:@"autoRefresh"];
    if (macPause && ![XSSettingValue(now, @"autoRefresh") boolValue] && XSMacPauseEnd.timeIntervalSinceNow > 0) {
        [hint addObject:XSPauseEndHint(XSMacPauseEnd, fr, NSTimeZone.localTimeZone)];
    }
    if (others.count) {
        // One: "« Rappel avant l'expiration » désactivé depuis ton Mac"; several: listed.
        NSDictionary *more = XSChangeTexts(others, now, YES, fr);
        [hint addObject:more[@"list"] ? [NSString stringWithFormat:fr ? @"Mis à jour depuis ton Mac : %@" : @"Updated from your Mac: %@",
                                         more[@"list"]]
                                      : more[@"lead"]];
    }
    BOOL opens = byMac || others.count;
    if (opens) [hint addObject:XSWhereHint(fr)];
    c.hint = hint.count ? [hint componentsJoinedByString:@"\n"] : nil;
    c.duration = opens ? 7 : 5;
    if (opens) {
        c.buttonTitle = fr ? @"Voir" : @"See";
        c.action = ^{ XSOpenAppSettings(); };
        c.tapAction = c.action;
    }
    return c;
}

/// A check-in's answer: the merged settings and the last refresh adopted. Returns the fields whose
/// value the Mac changed (nil when the reply wasn't a valid `settings`).
/// The settings just before the last adopted reply (for the pill's decision, XSMacChangePill).
static NSDictionary *XSSettingsBeforeAdopt;

/// "refreshCard=0 (mac 2026-11-08 17:27:03 +0000)" for each field, for the log.
static NSString *XSDescribeFields(NSArray<NSString *> *fields, NSDictionary *s) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *f in fields) {
        NSDictionary *field = s[f];
        [parts addObject:[NSString stringWithFormat:@"%@=%@ (%@ %@)", f, field[@"value"], field[@"changedBy"], field[@"changedAt"]]];
    }
    return parts.count ? [parts componentsJoinedByString:@", "] : @"none";
}

static NSArray<NSString *> *XSAdoptCheckInReply(XSChannelResult result, NSDictionary *reply) {
    // `live`: a watch line, carrying what a check-in's answer carries (device feedback 4).
    NSDictionary *settings = result == XSChannelReplied && ([reply[@"type"] isEqual:@"settings"] || [reply[@"type"] isEqual:@"live"])
        ? XSSettingsFromJSONObject(reply[@"settings"]) : nil;
    if (!settings) {
        NSLog(@"XSide: sync: no settings in the answer (result %ld, reply %@)", (long)result, reply[@"type"] ?: @"none");
        return nil;
    }
    NSDictionary *before = XSCurrentSettings();
    XSSettingsBeforeAdopt = before;
    XSAdoptSettings(settings);
    XSRecordCheckIn(NSDate.date);
    XSMacPauseEnd = XSPausedUntilFromReply(reply);
    // How the last refresh went, as XSide knows it (it may have ended while the app was away).
    NSDictionary *outcome = XSRefreshOutcomeFromJSONObject(reply[@"lastRefresh"]);
    if (outcome) XSAdoptRefreshOutcome(outcome);
    NSDate *expiry = XSExpirationDate();
    if (expiry) XSScheduleReminder(expiry, NO); // the reminder switch may have changed
    NSDictionary *after = XSCurrentSettings();
    NSArray<NSString *> *byMac = XSFieldsChangedByMac(before, after);
    NSLog(@"XSide: sync: settings reply adopted; changed by the Mac: %@; written to the iOS Settings rows",
          XSDescribeFields(byMac, after));
    return byMac;
}

/// The one pill for what the Mac changed (nil when nothing changed, or every message is off before
/// and after: XSShowsMacUpdatePill). Told even when the change itself turned every message off.
static XSPillContent *XSMacChangePill(NSArray<NSString *> *byMac) {
    if (!byMac.count) return nil;
    NSDictionary *after = XSCurrentSettings();
    if (!XSShowsMacUpdatePill(XSSettingsBeforeAdopt ?: after, after)) {
        NSLog(@"XSide: pill: change from the Mac not shown, every XSide message is off");
        return nil;
    }
    XSPillContent *c = XSChangePill(byMac, YES, nil);
    c.answer = !XSShowsPills(after); // the last one before "Aucun": said all the same
    return c;
}

/// The poll interval a check-in states (device feedback 5, G3): the foreground one while the app is
/// in front (it polls when no watch is open), none in the background (no poll follows).
static NSTimeInterval XSPollEveryNow(void) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return 0;
    return XSForegroundPollInterval(NSProcessInfo.processInfo.lowPowerModeEnabled);
}

/// A check-in exchange; `anyway`: browses even before the local network was allowed (right after
/// the "Réseau local" page, which says iOS will ask).
static void XSRunCheckIn(NSTimeInterval find, BOOL anyway, void (^handler)(XSChannelResult result, NSArray *byMac)) {
    if (XSCheckInRunning || (!anyway && !XSChannelGranted()) || !XSHasChannel()) {
        dispatch_async(dispatch_get_main_queue(), ^{ handler(XSChannelNotFound, nil); });
        return;
    }
    XSCheckInRunning = YES;
    // How the previous run ended rides along until XSide acknowledges it (a signed reply).
    NSDictionary *report = XSRunMarkerPendingReport();
    NSDictionary *body = XSWithRunReport(XSCheckInBody(XSCurrentSettings(), XSLastRefresh(), XSAppVersion(), XSPollEveryNow()),
                                         report);
    [[[XSChannelExchange alloc] initWithBody:body findTimeout:find waitsOutcome:NO
                                     handler:^(XSChannelResult result, NSDictionary *reply, BOOL final) {
        XSCheckInEnded();
        if (result == XSChannelReplied) XSRunMarkerSent(report);
        handler(result, XSAdoptCheckInReply(result, reply));
    }] start];
}

void XSCheckIn(void (^done)(XSPillContent *news)) {
    // Silent and short (spec: ≤ 3 s): nothing is shown here; the caller shows what the Mac changed.
    XSRunCheckIn(3, NO, ^(XSChannelResult result, NSArray *byMac) {
        XSPillContent *news = XSMacChangePill(byMac);
        if (done) done(news);
    });
}

void XSStartLocalNetwork(void) {
    // iOS asks while this browses (up to 30 s to answer); silent whatever happens.
    NSLog(@"XSide: local network: first access by XSide, right after its page");
    XSRunCheckIn(30, YES, ^(XSChannelResult result, NSArray *byMac) {
        NSLog(@"XSide: local network: first check-in, result %ld", (long)result);
    });
}

void XSProbeLocalNetwork(void (^done)(XSNetworkProbe probe)) {
    // A plain check-in, short (the Mac answers within a second when it is there).
    XSRunCheckIn(4, YES, ^(XSChannelResult result, NSArray *byMac) {
        XSNetworkProbe probe = result == XSChannelReplied || result == XSChannelUnknownInstallation ? XSNetworkProbeAllowed
                             : result == XSChannelDenied ? XSNetworkProbeDenied : XSNetworkProbeUnknown;
        NSLog(@"XSide: local network: silent check, result %ld", (long)result);
        done(probe);
    });
}

void XSSendSettings(NSArray<NSString *> *fields, void (^done)(XSPillContent *result)) {
    // Not before the local network was allowed: the next connection carries them (nothing to say).
    // No "sending…" pill first: one pill for the change, the one that says how it went (device
    // feedback round 2, P1/P2).
    if (!XSChannelGranted() || !XSHasChannel() || XSCheckInRunning) {
        done(nil);
        return;
    }
    XSRunCheckIn(5, NO, ^(XSChannelResult result, NSArray *byMac) {
        BOOL fr = XSFrench(); // the language may just have changed
        if (result == XSChannelReplied && byMac) {
            done(XSChangePill(fields, NO, byMac));
            return;
        }
        XSPillContent *c;
        if (result == XSChannelDenied) {
            c = XSUnansweredPill(result); // with Réglages
            c.hint = [NSString stringWithFormat:fr
                ? @"Tes réglages seront envoyés à la prochaine connexion. Autorise le réseau local dans %@."
                : @"Your settings will be sent at the next connection. Allow Local Network in %@.", XSSettingsPath()];
        } else {
            c = [XSPillContent new];
            c.lead = fr ? @"Mac injoignable" : @"Mac unreachable";
            c.hint = [NSString stringWithFormat:fr
                ? @"Tes réglages seront envoyés à la prochaine connexion ; ils s'appliquent déjà sur cet %@."
                : @"Your settings will be sent at the next connection; they already apply on this %@.", XSDeviceKind()];
            c.tone = XSPillToneOrange;
            c.duration = 6;
        }
        done(c);
    });
}

// MARK: - Live updates while the app is in front (device feedback round 2, P3; feedback 4)
//
// A watch first: a signed `watch` request (a check-in that keeps its connection open), on which
// XSide writes each change made on the Mac the moment it is stored. Every line is checked
// (XSOpenWatchLineV2: signed for this installation and this watch's fresh nonce, the next seq), the
// first one that doesn't check out closes it, and so does a silence of XSWatchKeepAliveTimeout
// (XSide writes at least every 25 s). XSide closes it after 5 min and another opens at once; the
// app closes it when it leaves the foreground. While no watch is open (it couldn't open: an older
// XSide, no slot left, the Mac away), the app polls as before: a signed check-in every 15 s (45 s
// in Low Power Mode), and it tries the watch again a minute later. Never before the local network
// was allowed, never in the background.

static NSTimer *XSPollTimer;
/// The last poll that got no answer: the next waits a minute (the Mac is off or away), so the
/// phone doesn't browse in vain every few seconds.
static NSDate *XSPollQuietUntil;
static const NSTimeInterval XSPollQuietTime = 60;
/// When the last poll started (a check-in that failed records no check-in date).
static NSDate *XSLastPoll;
/// The watch open or opening, nil when none.
static XSChannelExchange *XSWatch;
/// No watch before then (nil: whenever): set when one fails, so the app polls meanwhile.
static NSDate *XSWatchRetryAt;
static void XSPollNow(void);

/// What the Mac changed, told once (the same pill as a poll's).
static void XSTellLiveChange(NSArray<NSString *> *byMac, NSString *how) {
    if (!byMac.count) return;
    NSLog(@"XSide: %@: live update from the Mac: %@", how, byMac);
    XSPillContent *pill = XSMacChangePill(byMac);
    if (pill) XSShowPillWhenFree(pill);
}

static void XSOpenWatch(void) {
    XSCheckInRunning = YES; // its first line is a check-in's answer (see XSCheckInEnded)
    NSDate *opened = NSDate.date;
    __block BOOL first = YES;
    __block BOOL answered = NO;
    NSDictionary *report = XSRunMarkerPendingReport();
    NSDictionary *body = XSWithRunReport(XSWatchBody(XSCurrentSettings(), XSLastRefresh(), XSAppVersion(), YES), report);
    __block __weak XSChannelExchange *weakExchange = nil;
    XSChannelHandler handler = ^(XSChannelResult result, NSDictionary *reply, BOOL final) {
        if (first) {
            first = NO;
            XSCheckInEnded();
            answered = result == XSChannelReplied;
            if (answered) XSRunMarkerSent(report);
            NSArray<NSString *> *byMac = answered ? XSAdoptCheckInReply(result, reply) : nil;
            NSLog(@"XSide: watch: %@ (result %ld)", answered ? @"open" : @"not open, polling", (long)result);
            XSTellLiveChange(byMac, @"watch");
        } else if (result == XSChannelReplied) {
            // A change made on the Mac, written on the watch as it was stored.
            NSArray<NSString *> *byMac = XSAdoptCheckInReply(result, reply);
            XSTellLiveChange(byMac, @"watch");
            // Confirmed with an ordinary check-in, so the Mac can say the device has it.
            if (byMac.count) {
                XSRunCheckIn(3, NO, ^(XSChannelResult r, NSArray *more) { XSTellLiveChange(more, @"confirm"); });
            }
        }
        if (!final) return;
        XSChannelExchange *ended = weakExchange;
        if (ended && XSWatch != ended) return; // closed by the app (left the foreground)
        XSWatch = nil;
        NSTimeInterval lived = -[opened timeIntervalSinceNow];
        NSTimeInterval delay = XSWatchRetryDelay(answered, lived);
        NSLog(@"XSide: watch: ended after %.0f s (result %ld), next in %.0f s", lived, (long)result, delay);
        XSWatchRetryAt = [NSDate dateWithTimeIntervalSinceNow:delay];
        if (delay == 0) dispatch_async(dispatch_get_main_queue(), ^{ XSPollNow(); });
    };
    XSChannelExchange *exchange = [[XSChannelExchange alloc] initWithBody:body findTimeout:3 waitsOutcome:NO
                                                                  handler:handler];
    weakExchange = exchange;
    exchange.watches = YES;
    XSWatch = exchange;
    [exchange start];
}

static void XSPollNow(void) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        XSStopForegroundUpdates();
        return;
    }
    if (!XSPollTimer) return; // stopped meanwhile
    NSDate *now = NSDate.date;
    if (XSCheckInRunning || XSRefreshRunning) return;
    if (XSShouldOpenWatch(XSHasChannel(), XSChannelGranted(), XSWatch != nil, XSWatchRetryAt, now)) {
        XSOpenWatch();
        return;
    }
    if (XSPollQuietUntil && [now compare:XSPollQuietUntil] == NSOrderedAscending) return;
    NSDate *last = XSLastCheckIn();
    if (XSLastPoll && (!last || [XSLastPoll compare:last] == NSOrderedDescending)) last = XSLastPoll;
    if (!XSShouldPoll(XSHasChannel(), XSChannelGranted(), last, now, NSProcessInfo.processInfo.lowPowerModeEnabled,
                      XSWatch != nil)) return;
    XSLastPoll = now;
    XSRunCheckIn(3, NO, ^(XSChannelResult result, NSArray *byMac) {
        if (result != XSChannelReplied || !byMac) {
            NSLog(@"XSide: poll: no answer (result %ld), quiet for %.0f s", (long)result, XSPollQuietTime);
            XSPollQuietUntil = [NSDate dateWithTimeIntervalSinceNow:XSPollQuietTime];
            return;
        }
        XSPollQuietUntil = nil;
        XSTellLiveChange(byMac, @"poll");
    });
}

void XSStartForegroundUpdates(void) {
    if (XSPollTimer || !XSHasChannel()) return;
    XSPollQuietUntil = nil;
    XSWatchRetryAt = nil;
    // Ticks often and lets XSShouldOpenWatch / XSShouldPoll decide, so Low Power Mode turned on or
    // off applies at once and a watch opens within seconds of the return.
    XSPollTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer) { XSPollNow(); }];
    XSPollTimer.tolerance = 2;
}

void XSStopForegroundUpdates(void) {
    [XSPollTimer invalidate];
    XSPollTimer = nil;
    // The Mac sees the connection close and stops saying the app is open; the goodbye tells it the
    // app left the front rather than vanished (a crash, which it then looks at at once).
    XSChannelExchange *watch = XSWatch;
    XSWatch = nil;
    [watch closeSayingBye];
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

/// "XSide : en attente du Mac…": no answer after a few seconds, still trying. `answer`: waiting
/// on something the person just asked (XSPillContent.answer).
static void XSShowWaitingPill(BOOL answer) {
    BOOL fr = XSFrench();
    XSPillContent *c = [XSPillContent new];
    c.lead = fr ? @"En attente du Mac…" : @"Waiting for the Mac…";
    c.hint = fr ? @"Accepte la connexion sur ton Mac si macOS le demande."
                : @"Accept the connection on your Mac if macOS asks.";
    c.busy = YES;
    c.answer = answer;
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

/// A pill answering something the person just asked (a Refresh and its outcome, a pill's button):
/// shown even with every message off (ledger ruling).
static void XSShowAnswer(XSPillContent *c) {
    c.answer = YES;
    XSShowPill(c);
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
            // The Mac also refuses a request more than 2 minutes off its own clock, with the same
            // answer: the date and time are a possible cause (final review minor 5).
            return XSPill(fr ? @"XSide sur ton Mac ne reconnaît pas cette app" : @"XSide on your Mac doesn't know this app",
                          [NSString stringWithFormat:fr
                              ? @"Vérifie que la date et l'heure de cet %@ et du Mac sont à l'heure (réglage automatique). Sinon, rafraîchis-la une fois depuis XSide sur le Mac qui l'a installée."
                              : @"Check that the date and time of this %@ and of the Mac are right (set automatically). Otherwise, refresh it once from XSide on the Mac that installed it.",
                           XSDeviceKind()], XSPillToneOrange, 10);
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
        XSShowAnswer(XSPill(text, fr ? @"Rien n'a changé dans l'app. Le détail est dans XSide sur ton Mac."
                                   : @"Nothing changed in the app. XSide on your Mac has the details.", XSPillToneOrange, 8));
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
                 withCompletionHandler:^(NSError *error) { NSLog(@"XSide: refresh failure notified, error %@", error); }];
    }];
}

static void XSResumeAutoRefresh(void);
static void XSResumeAutoRefreshNow(void);

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
static void XSStartRefreshExchange(void);

static void XSRequestRefreshNow(void);

void XSRequestRefresh(void) {
    // Never over the first-launch sheet (a quick action at the first launch): after it, the
    // notification prompt and then the local network one each come after their page.
    XSAfterSheet(^{ XSRequestRefreshNow(); });
}

static void XSRequestRefreshNow(void) {
    if (XSRefreshRunning) return;
    BOOL fr = XSFrench();
    if (!XSInstallationID() || !XSChannelSecret()) {
        XSShowAnswer(XSPill(fr ? @"Pas encore de lien avec XSide" : @"No link with XSide yet",
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
            XSShowAnswer(why);
            [XSCenter() requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                                      completionHandler:^(BOOL granted, NSError *error) {
                NSLog(@"XSide: notifications: asked before a refresh, granted %d, error %@", granted, error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSDate *expiry = XSExpirationDate();
                    if (granted && expiry) XSScheduleReminder(expiry, NO);
                    XSStartRefresh();
                });
            }];
        });
    }];
}

/// "Mac not found" after a Refresh: what to do, and Réessayer.
static XSPillContent *XSRefreshUnansweredPill(XSChannelResult result) {
    BOOL fr = XSFrench();
    XSPillContent *c = XSUnansweredPill(result);
    if (result == XSChannelNotFound) {
        c.hint = [NSString stringWithFormat:fr
            ? @"Ouvre XSide sur ton Mac, avec cet %@ sur le même Wi-Fi ou branché en USB, puis réessaie."
            : @"Open XSide on your Mac, with this %@ on the same Wi-Fi or plugged in over USB, then try again.", XSDeviceKind()];
        c.buttonTitle = fr ? @"Réessayer" : @"Try again";
        c.action = ^{ XSRequestRefresh(); };
    }
    return c;
}

static void XSStartRefresh(void) {
    // The first time, the local network page comes first (iOS asks while this browses).
    XSExplainNetworkThenOr(^{
        // A real modal (Anthony): connexion à ton Mac → sauvegarde (si activée) → rafraîchissement.
        BOOL backs = XSSettingBool(XSCurrentSettings(), @"backupData");
        XSRefreshModalShow(backs);
        XSStartRefreshExchange();
    }, ^{
        // Its "Réseau local" page had no screen: no refresh asked, the next Refresh can start
        // (mega review D4: it stayed "running", Refresh and the live updates dead until relaunch).
        XSRefreshRunning = NO;
    });
}

/// A user-facing name for a refresh step, by its stable key (XSideCore's `ProgressStep.key`), in the
/// device's language. Word for word the Mac's own step labels (install.step.* in Localizable.strings),
/// so the modal reads exactly like the install list on the Mac (Anthony: « faut les mêmes steps que
/// l'install sur le Mac »). Keep these in sync with ProgressStep.label.
static NSString *XSRefreshStepName(NSString *stage, BOOL french) {
    if ([stage isEqual:@"profile"]) return french ? @"Autorisation d'Apple" : @"Apple permission";
    if ([stage isEqual:@"welcome"]) return french ? @"Injection du module XSide" : @"Injecting the XSide module";
    if ([stage isEqual:@"legacy32"]) return french ? @"Retrait de l'ancienne version 32 bits" : @"Removing the old 32-bit code";
    if ([stage isEqual:@"duo"]) return french ? @"Ajout de la compatibilité iPhone Duo" : @"Adding iPhone Duo compatibility";
    if ([stage isEqual:@"icloud"]) return french ? @"Ajout du mode iCloud déconnecté" : @"Adding signed-out iCloud";
    if ([stage isEqual:@"tweaks"]) return french ? @"Ajout des tweaks" : @"Adding tweaks";
    if ([stage isEqual:@"backingUp"]) return french ? @"Sauvegarde des données" : @"Backing up data";
    if ([stage isEqual:@"signing"]) return french ? @"Signature" : @"Signing";
    if ([stage isEqual:@"installing"]) return french ? @"Installation" : @"Installing";
    if ([stage isEqual:@"restoring"]) return french ? @"Restauration des données" : @"Restoring data";
    return french ? @"Préparation" : @"Preparing"; // preparing, or an unknown key
}

static void XSStartRefreshExchange(void) {
    [XSPatientExchange(XSRefreshBody(), YES, ^(XSChannelResult result, NSDictionary *reply, BOOL final) {
        BOOL french = XSFrench();
        NSString *type = reply[@"type"];
        void (^retry)(void) = ^{ XSRequestRefresh(); };
        if (result == XSChannelWaiting) { return; } // the modal already shows « connexion… »
        if (final) {
            XSRefreshRunning = NO;
            XSEndRefreshTask();
        }
        if (result == XSChannelNoOutcome) {
            // Accepted, then silence (app suspended, connection lost, 2 min passed). Ambiguous: a
            // success replaces the app (its new signature clears this), otherwise the next launch
            // resolves it. The modal can't say; drop it and keep the pending-failure pill flow.
            XSRefreshModalDismiss();
            XSSetPendingFailure(XSNoOutcomeKey, XSAcceptedAt ?: NSDate.date);
            XSCheckIn(^(XSPillContent *news) {
                XSShowPendingPill();
                if (news) XSShowPillWhenFree(news);
            });
            return;
        }
        if (result != XSChannelReplied) {
            XSPillContent *u = XSRefreshUnansweredPill(result);
            XSRefreshModalError(u.lead, u.hint, retry);
            return;
        }
        if ([type isEqual:@"accepted"]) {
            XSAcceptedAt = NSDate.date;
            XSRefreshModalWorking();
            // Keeps the connection a little if the person leaves the app, to hear a failure.
            XSEndRefreshTask();
            XSRefreshTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"XSide refresh"
                                                                     expirationHandler:^{ XSEndRefreshTask(); }];
            XSHasRefreshTask = XSRefreshTask != UIBackgroundTaskInvalid;
        } else if ([type isEqual:@"progress"]) {
            // A live step of the running refresh (Slice 2), shown as « nom · étape X/Y · % ». The Mac
            // sends the step's 1-based place and the run's total (it alone knows which optional steps
            // this refresh includes), so the phone just names the stage and fills the ring from X/Y
            // plus the step's own % when it reports one.
            NSString *stage = [reply[@"stageKey"] isKindOfClass:NSString.class] ? reply[@"stageKey"] : @"";
            NSNumber *pct = [reply[@"percent"] isKindOfClass:NSNumber.class] ? reply[@"percent"] : nil;
            int idx = [reply[@"index"] isKindOfClass:NSNumber.class] ? [reply[@"index"] intValue] : 1;
            int total = [reply[@"total"] isKindOfClass:NSNumber.class] ? [reply[@"total"] intValue] : 1;
            if (total < 1) total = 1;
            if (idx < 1) idx = 1;
            if (idx > total) idx = total;
            NSString *name = XSRefreshStepName(stage, french);
            double stepFrac = pct ? pct.doubleValue / 100.0 : 0.5;
            double overall = ((idx - 1) + stepFrac) / total;
            // The overall % now sits big in the ring's centre (XSRefreshModal); the sub just numbers
            // the step, so the two don't show two different numbers.
            NSString *sub = [NSString stringWithFormat:(french ? @"Étape %d/%d" : @"Step %d/%d"), idx, total];
            XSRefreshModalStep(name, sub, overall);
        } else if ([type isEqual:@"refreshed"]) {
            XSRecordRefresh(YES, nil, NSDate.date); // the new app replaces this one right after
            XSRefreshModalStep(french ? @"Rafraîchie ✓" : @"Refreshed ✓",
                               french ? @"L’app va se fermer, rouvre-la ensuite." : @"The app will close, open it again then.", 1.0);
        } else if ([type isEqual:@"failed"]) {
            NSString *reason = [reply[@"reasonKey"] isKindOfClass:NSString.class] ? reply[@"reasonKey"] : @"unknown";
            XSRecordRefresh(NO, reason, NSDate.date);
            XSRefreshModalError(french ? @"Le rafraîchissement a échoué" : @"The refresh failed", XSReasonText(reason, french), retry);
        } else if ([type isEqual:@"busy"]) {
            XSRefreshModalError(french ? @"XSide la rafraîchit déjà, ou vient de le faire" : @"XSide is already refreshing it, or just did",
                [NSString stringWithFormat:french ? @"Une demande depuis l'%@ toutes les 10 minutes au plus. Réessaie un peu plus tard."
                                                  : @"One request from the %@ every 10 minutes at most. Try again a little later.", XSDeviceKind()], retry);
        } else if ([type isEqual:@"deviceUnreachable"]) {
            XSRefreshModalError([NSString stringWithFormat:french ? @"Ton Mac ne voit pas cet %@" : @"Your Mac can't see this %@", XSDeviceKind()],
                french ? @"Déverrouille-le, et vérifie qu'il est sur le même Wi-Fi que le Mac ou branché en USB."
                       : @"Unlock it, and check it's on the same Wi-Fi as the Mac or plugged in over USB.", retry);
        } else if ([type isEqual:@"paused"]) {
            BOOL byDevice = [reply[@"by"] isEqual:@"device"];
            NSString *who = byDevice ? [NSString stringWithFormat:french ? @"cet %@" : @"this %@", XSDeviceKind()]
                                     : (french ? @"le Mac" : @"the Mac");
            XSRefreshModalError(french ? @"Rafraîchissement automatique désactivé pour cette app" : @"Automatic refresh is off for this app",
                [NSString stringWithFormat:french ? @"Désactivé depuis %@. Réactive-le dans les Réglages XSide." : @"Turned off from %@. Turn it back on in XSide Settings.", who],
                ^{ XSResumeAutoRefresh(); });
        } else {
            XSRefreshModalError(french ? @"XSide n'a pas pu lancer le rafraîchissement" : @"XSide couldn't start the refresh", nil, retry);
        }
    }) start];
}

void XSTellAutoRefreshChange(void) {
    if (!XSHasChannel()) return; // no link with XSide yet: the next signing carries it
    // The first time, the "Réseau local" page comes first (this browses: iOS asks).
    XSExplainNetworkThen(^{ XSTellAutoRefreshChangeNow(); });
}

static void XSTellAutoRefreshChangeNow(void) {
    if (XSCheckInRunning) { XSTellQueued = YES; return; } // told once it ends (mega review minor 2)
    XSCheckInRunning = YES;
    BOOL on = XSSettingBool(XSCurrentSettings(), @"autoRefresh");
    NSDictionary *report = XSRunMarkerPendingReport();
    NSDictionary *body = XSWithRunReport(XSCheckInBody(XSCurrentSettings(), XSLastRefresh(), XSAppVersion(), XSPollEveryNow()),
                                         report);
    [XSPatientExchange(body, NO, ^(XSChannelResult result, NSDictionary *reply, BOOL final) {
        BOOL fr = XSFrench();
        if (result == XSChannelWaiting) { XSShowWaitingPill(NO); return; }
        XSCheckInEnded();
        if (result == XSChannelReplied) XSRunMarkerSent(report);
        NSArray<NSString *> *byMac = XSAdoptCheckInReply(result, reply);
        if (!byMac) {
            XSPillContent *c = result == XSChannelReplied
                ? XSPill(fr ? @"XSide n'a pas pu enregistrer le changement" : @"XSide couldn't record the change", nil, XSPillToneOrange, 8)
                : XSUnansweredPill(result);
            c.hint = c.hint ?: [NSString stringWithFormat:fr ? @"Changé sur l'%@ : XSide l'appliquera à la prochaine connexion."
                                                             : @"Changed on this %@: XSide will apply it at the next connection.",
                                XSDeviceKind()];
            XSShowPill(c);
            return;
        }
        // One pill for the change (device feedback round 2, P1): what XSide now knows, unless the
        // Mac held a newer change of its own, which then is what applies.
        BOOL now = XSSettingBool(XSCurrentSettings(), @"autoRefresh");
        if (now != on) {
            XSShowPill(XSPill(now ? (fr ? @"Réactivé entre-temps depuis le Mac" : @"Turned back on from the Mac meanwhile")
                                  : (fr ? @"Désactivé entre-temps depuis le Mac" : @"Turned off from the Mac meanwhile"),
                              fr ? @"Rafraîchissement automatique : c'est le changement le plus récent qui compte."
                                 : @"Automatic refresh: the most recent change wins.", XSPillToneNeutral, 6));
            return;
        }
        NSMutableArray<NSString *> *others = [byMac mutableCopy];
        [others removeObject:@"autoRefresh"];
        XSShowPill(XSChangePill(@[@"autoRefresh"], NO, others));
    }) start];
}

/// "Réactiver" after a refresh refused as paused: on at once on the phone, then told to XSide.
static void XSResumeAutoRefresh(void) {
    XSSetDeviceSetting(@"autoRefresh", @YES);
    // Only offered after XSide answered (so the network was allowed); gated all the same, as every
    // access is (device feedback round 2, P4).
    XSExplainNetworkThen(^{ XSResumeAutoRefreshNow(); });
}

static void XSResumeAutoRefreshNow(void) {
    [XSPatientExchange(XSSetAutoRefreshBody(YES), NO, ^(XSChannelResult result, NSDictionary *reply, BOOL final) {
        BOOL fr = XSFrench();
        if (result == XSChannelWaiting) { XSShowWaitingPill(YES); return; }
        if (result != XSChannelReplied) {
            XSPillContent *c = XSUnansweredPill(result);
            c.hint = c.hint ?: [NSString stringWithFormat:fr ? @"Réactivé sur l'%@ : XSide le saura à la prochaine connexion."
                                                             : @"On again on this %@: XSide will know at the next connection.",
                                XSDeviceKind()];
            XSShowAnswer(c);
            return;
        }
        NSDictionary *settings = [reply[@"type"] isEqual:@"settings"] ? XSSettingsFromJSONObject(reply[@"settings"]) : nil;
        if (settings) XSAdoptSettings(settings);
        XSPillContent *c = XSPill(fr ? @"Rafraîchissement automatique réactivé" : @"Automatic refresh turned back on",
                                  nil, XSPillToneNeutral, 6);
        c.buttonTitle = fr ? @"Rafraîchir" : @"Refresh";
        c.action = ^{ XSRequestRefresh(); };
        XSShowAnswer(c);
    }) start];
}

static void XSRequestCheckUpdatesNow(void);

void XSRequestCheckUpdates(void) {
    if (!XSInstallationID() || !XSChannelSecret()) return; // no link with XSide yet: nothing to ask
    XSAfterSheet(^{ XSExplainNetworkThen(^{ XSRequestCheckUpdatesNow(); }); });
}

static void XSStartInstallUpdateExchange(NSString *tag, NSString *asset);

static void XSRequestCheckUpdatesNow(void) {
    // A real modal (Slice 3), like the refresh: connexion → recherche → « à jour » / une version
    // proposée (« Télécharger et installer ») / « à regarder sur le Mac ».
    XSUpdateModalShow();
    [XSPatientExchange(XSCheckUpdatesBody(), YES, ^(XSChannelResult result, NSDictionary *reply, BOOL final) {
        BOOL f = XSFrench();
        NSString *type = reply[@"type"];
        if (result == XSChannelWaiting) { return; } // the modal already shows « connexion… »
        if (result == XSChannelNoOutcome) {
            XSUpdateModalDone(f ? @"Pas de réponse de ton Mac" : @"No answer from your Mac",
                              f ? @"Réessaie dans un instant." : @"Try again in a moment.", NO);
            return;
        }
        if (result != XSChannelReplied) {
            XSPillContent *u = XSUnansweredPill(result);
            XSRefreshModalError(u.lead, u.hint, ^{ XSRequestCheckUpdates(); });
            return;
        }
        if ([type isEqual:@"busy"]) {
            XSUpdateModalDone(f ? @"XSide est occupé" : @"XSide is busy",
                              f ? @"Réessaie dans un instant." : @"Try again in a moment.", NO);
            return;
        }
        if ([type isEqual:@"accepted"]) {
            XSUpdateModalWorking(f ? @"Recherche de mises à jour…" : @"Checking for updates…",
                                 f ? @"XSide regarde le dépôt suivi." : @"XSide is checking the tracked repo.", -1);
            return;
        }
        if ([type isEqual:@"update"]) {
            NSString *state = reply[@"state"];
            NSString *version = [reply[@"version"] isKindOfClass:NSString.class] ? reply[@"version"] : nil;
            if ([state isEqual:@"upToDate"]) {
                XSUpdateModalDone(f ? @"Tu es à jour" : @"You're up to date",
                                  f ? @"Tu as déjà la dernière version." : @"You already have the latest version.", YES);
            } else if ([state isEqual:@"needsMac"]) {
                XSUpdateModalDone(f ? @"À regarder sur ton Mac" : @"Look on your Mac",
                                  f ? @"Un choix de version ou une mise à jour t'attend dans XSide sur le Mac." : @"A version choice or an update is waiting in XSide on the Mac.", YES);
            } else if ([state isEqual:@"available"]) {
                NSString *tag = [reply[@"tag"] isKindOfClass:NSString.class] ? reply[@"tag"] : @"";
                NSString *asset = [reply[@"asset"] isKindOfClass:NSString.class] ? reply[@"asset"] : @"";
                NSString *title = version ? [NSString stringWithFormat:(f ? @"Version %@ disponible" : @"Version %@ available"), version]
                                          : (f ? @"Mise à jour disponible" : @"Update available");
                XSUpdateModalOffer(title,
                    f ? @"XSide va la télécharger dans ton dossier puis l'installer. L'app se fermera à la fin." : @"XSide will download it to your folder then install it. The app closes at the end.",
                    f ? @"Télécharger et installer" : @"Download and install",
                    ^{ XSStartInstallUpdateExchange(tag, asset); });
            }
            return;
        }
    }) start];
}

static void XSStartInstallUpdateExchange(NSString *tag, NSString *asset) {
    [XSPatientExchange(XSInstallUpdateBody(tag, asset), YES, ^(XSChannelResult result, NSDictionary *reply, BOOL final) {
        BOOL f = XSFrench();
        NSString *type = reply[@"type"];
        void (^retry)(void) = ^{ XSStartInstallUpdateExchange(tag, asset); };
        if (result == XSChannelWaiting) { return; }
        if (result == XSChannelNoOutcome) {
            // The app is likely being replaced (success kills it); otherwise the next launch tells.
            XSUpdateModalDone(f ? @"Installation en cours sur ton Mac" : @"Installing on your Mac",
                              f ? @"Si l'app ne se ferme pas, rouvre-la dans un instant." : @"If the app doesn't close, reopen it in a moment.", YES);
            return;
        }
        if (result != XSChannelReplied) {
            XSPillContent *u = XSUnansweredPill(result);
            XSRefreshModalError(u.lead, u.hint, retry);
            return;
        }
        if ([type isEqual:@"busy"]) { XSUpdateModalDone(f ? @"XSide est occupé" : @"XSide is busy", f ? @"Réessaie dans un instant." : @"Try again in a moment.", NO); return; }
        if ([type isEqual:@"accepted"]) { XSUpdateModalWorking(f ? @"Téléchargement…" : @"Downloading…", nil, 0); return; }
        if ([type isEqual:@"failed"]) {
            NSString *r = [reply[@"reasonKey"] isKindOfClass:NSString.class] ? reply[@"reasonKey"] : @"unknown";
            XSRefreshModalError(f ? @"L'installation a échoué" : @"The install failed", XSReasonText(r, f), retry);
            return;
        }
        if ([type isEqual:@"update"]) {
            NSString *state = reply[@"state"];
            NSString *version = [reply[@"version"] isKindOfClass:NSString.class] ? reply[@"version"] : nil;
            if ([state isEqual:@"downloading"]) {
                NSNumber *pct = [reply[@"percent"] isKindOfClass:NSNumber.class] ? reply[@"percent"] : nil;
                XSUpdateModalWorking(f ? @"Téléchargement…" : @"Downloading…", nil, pct ? pct.doubleValue / 100.0 : -1);
            } else if ([state isEqual:@"installing"]) {
                XSUpdateModalWorking(f ? @"Installation…" : @"Installing…", f ? @"L'app va se fermer." : @"The app will close.", -1);
            } else if ([state isEqual:@"installed"]) {
                XSUpdateModalDone(version ? [NSString stringWithFormat:(f ? @"Version %@ installée" : @"Version %@ installed"), version] : (f ? @"Installée" : @"Installed"),
                                  f ? @"L'app va se fermer, rouvre-la ensuite." : @"The app will close, open it again then.", YES);
            } else if ([state isEqual:@"needsMac"]) {
                XSUpdateModalDone(f ? @"À regarder sur ton Mac" : @"Look on your Mac", nil, YES);
            } else if ([state isEqual:@"upToDate"]) {
                XSUpdateModalDone(f ? @"Déjà à jour" : @"Already up to date", nil, YES);
            }
            return;
        }
    }) start];
}

// « Sauvegarder maintenant » / « Restaurer » : light actions, like check-updates. The Mac does the
// work (it pulls or pushes the data over its own tools); the pill just says the request was taken.
static void XSRequestDataActionNow(NSDictionary *body, NSString *askFR, NSString *askEN,
                                   NSString *okFR, NSString *okEN, NSString *hintFR, NSString *hintEN) {
    XSPillContent *asking = XSPill(XSFrench() ? askFR : askEN, nil, XSPillToneNeutral, 0);
    asking.busy = YES;
    XSShowAnswer(asking);
    [XSPatientExchange(body, NO, ^(XSChannelResult result, NSDictionary *reply, BOOL final) {
        BOOL f = XSFrench();
        if (result == XSChannelWaiting) { XSShowWaitingPill(YES); return; }
        if (result != XSChannelReplied) { XSShowAnswer(XSUnansweredPill(result)); return; }
        if ([reply[@"type"] isEqual:@"busy"]) {
            XSShowAnswer(XSPill(f ? @"XSide est occupé" : @"XSide is busy",
                                f ? @"Réessaie dans un instant." : @"Try again in a moment.", XSPillToneNeutral, 6));
            return;
        }
        XSShowAnswer(XSPill(f ? okFR : okEN, f ? hintFR : hintEN, XSPillToneNeutral, 7));
    }) start];
}

void XSRequestBackup(void) {
    if (!XSInstallationID() || !XSChannelSecret()) return;
    XSAfterSheet(^{ XSExplainNetworkThen(^{
        // The Mac backs up then refreshes, so the « Données » page lists the new snapshot: the
        // refresh closes the app once done, like a normal refresh (the hint says so).
        XSRequestDataActionNow(XSBackupNowBody(), @"Sauvegarde des données…", @"Backing up the data…",
                               @"Sauvegarde demandée à ton Mac", @"Backup asked of your Mac",
                               @"XSide rafraîchit l'app pour l'ajouter à la liste ; elle se fermera un instant, rouvre-la ensuite.",
                               @"XSide refreshes the app to add it to the list; it will close for a moment, open it again after.");
    }); });
}

void XSRequestRestore(NSString *backupID) {
    if (!XSInstallationID() || !XSChannelSecret() || backupID.length == 0) return;
    NSDictionary *body = XSRestoreBody(backupID);
    XSAfterSheet(^{ XSExplainNetworkThen(^{
        XSRequestDataActionNow(body, @"Restauration des données…", @"Restoring the data…",
                               @"Restauration demandée à ton Mac", @"Restore asked of your Mac",
                               @"Les données actuelles vont être remplacées par la sauvegarde choisie.",
                               @"The current data will be replaced by the chosen backup.");
    }); });
}
