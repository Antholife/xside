// See XSRunMarker.h.

#import "XSRunMarker.h"
#import "XSRunMarkerCore.h"

static dispatch_queue_t XSMarkerQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("io.github.xside.welcome.runmarker", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

/// The marker as last written; only touched on XSMarkerQueue().
static NSDictionary *XSMarker;

static NSURL *XSMarkerFile(void) {
    NSURL *home = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
    return [home URLByAppendingPathComponent:@"Library/Application Support/io.github.xside.welcome/run-marker.plist"];
}

/// On the queue: writes `marker` when it changed (atomically: never half a file).
static void XSMarkerStore(NSDictionary *marker) {
    if (!marker || [marker isEqual:XSMarker]) return;
    XSMarker = marker;
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
    if (wait) dispatch_sync(XSMarkerQueue(), change);
    else dispatch_async(XSMarkerQueue(), change);
}

NSDictionary *XSRunMarkerPendingReport(void) {
    __block NSDictionary *report = nil;
    dispatch_sync(XSMarkerQueue(), ^{ report = XSMarker ? XSRunMarkerReport(XSMarker) : nil; });
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
