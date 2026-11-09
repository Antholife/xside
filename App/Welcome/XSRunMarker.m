// See XSRunMarker.h.

#import "XSRunMarker.h"
#import "XSRunMarkerCore.h"
#import <os/lock.h>

static dispatch_queue_t XSMarkerQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("io.github.xside.welcome.runmarker", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

/// The marker as last written; only touched on XSMarkerQueue().
static NSDictionary *XSMarker;

/// The report the marker holds (`XSRunMarkerReport(XSMarker)`), kept apart under a lock so a
/// check-in reads it without waiting on the queue's file I/O (AGENTS rule 4: never block main).
static os_unfair_lock XSPendingLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary *XSPending;

/// On the queue, whenever XSMarker changes.
static void XSPublishPending(void) {
    NSDictionary *report = XSMarker ? XSRunMarkerReport(XSMarker) : nil;
    os_unfair_lock_lock(&XSPendingLock);
    XSPending = report;
    os_unfair_lock_unlock(&XSPendingLock);
}

static NSURL *XSMarkerFile(void) {
    NSURL *home = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
    return [home URLByAppendingPathComponent:@"Library/Application Support/io.github.xside.welcome/run-marker.plist"];
}

/// On the queue: writes `marker` when it changed (atomically: never half a file).
static void XSMarkerStore(NSDictionary *marker) {
    if (!marker || [marker isEqual:XSMarker]) return;
    XSMarker = marker;
    XSPublishPending();
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:XSRunMarkerPlist(marker)
                                                              format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    NSURL *file = XSMarkerFile();
    NSURL *folder = file.URLByDeletingLastPathComponent;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:folder.path]) {
        if (![fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:NULL]) return;
        [folder setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];
    }
    if (![data writeToURL:file options:NSDataWritingAtomic error:NULL]) NSLog(@"XSide: run marker: not written");
}

void XSRunMarkerLaunched(void) {
    NSDate *now = NSDate.date;
    dispatch_async(XSMarkerQueue(), ^{
        NSData *data = [NSData dataWithContentsOfURL:XSMarkerFile() options:0 error:NULL];
        id previous = data.length && data.length < 4096
            ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL] : nil;
        NSDictionary *marker = XSRunMarkerAtLaunch(previous, now);
        NSDictionary *report = XSRunMarkerReport(marker);
        if (report) NSLog(@"XSide: run marker: previous run %@ (in front since %@)", report[@"ended"], report[@"since"]);
        XSMarkerStore(marker);
    });
}

void XSRunMarkerInFront(BOOL inFront, BOOL wait) {
    NSDate *now = NSDate.date;
    dispatch_block_t change = ^{
        if (!XSMarker) return; // not launched through the constructor: nothing to compare with
        XSMarkerStore(XSRunMarkerWithState(XSMarker, inFront, now));
    };
    if (!wait) {
        dispatch_async(XSMarkerQueue(), change);
        return;
    }
    // Terminating: best effort, bounded. The write usually takes a millisecond; a queue stuck in
    // I/O never holds the app's exit for more than a fifth of a second (the marker then says the
    // app was in front, and the next launch reports a stop that wasn't a crash: a look, nothing found).
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(XSMarkerQueue(), ^{
        change();
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0)
        NSLog(@"XSide: run marker: not written before exit");
}

NSDictionary *XSRunMarkerPendingReport(void) {
    os_unfair_lock_lock(&XSPendingLock);
    NSDictionary *report = XSPending;
    os_unfair_lock_unlock(&XSPendingLock);
    return report;
}

void XSRunMarkerSent(NSDictionary *report) {
    if (!report) return;
    dispatch_async(XSMarkerQueue(), ^{
        if (!XSMarker) return;
        NSDictionary *next = XSRunMarkerAcknowledged(XSMarker, report);
        if (![next isEqual:XSMarker]) NSLog(@"XSide: run marker: report delivered to XSide");
        XSMarkerStore(next);
    });
}
