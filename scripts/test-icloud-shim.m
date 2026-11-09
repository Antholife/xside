// Checks XSideICloud.dylib (App/ICloud) on the Mac: its pure part (the default container from the
// Info.plist), then the library itself loaded into this process, which links CloudKit and has no
// iCloud entitlement: every probe must answer "signed out", nothing may crash or hang.
// Built and run by scripts/test-icloud-shim.sh (an Info.plist sits next to this executable).
#import <Foundation/Foundation.h>
#import <CloudKit/CloudKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "XSICloudCore.h"

@interface CKContainer (XSideTestPrivate)
- (instancetype)_initWithContainerIdentifier:(NSString *)identifier;
@end

static int failures = 0;

static void check(BOOL ok, NSString *what) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", what.UTF8String);
    if (!ok) failures++;
}

static BOOL waitFor(dispatch_semaphore_t s) {
    return dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
}

static BOOL notAuthenticated(NSError *e) {
    return [e.domain isEqualToString:CKErrorDomain] && e.code == CKErrorNotAuthenticated;
}

static void testCore(void) {
    check([XSICloudDefaultContainer(@{@"XSideICloudContainers": @[@"iCloud.com.vendor.app"],
                                      @"XSideOriginalBundleID": @"com.vendor.other"}) isEqualToString:@"iCloud.com.vendor.app"],
          @"core: the first declared container");
    check([XSICloudDefaultContainer(@{@"XSideICloudContainers": @[@42, @"", @"nope", @"iCloud.", @"iCloud.ok"]}) isEqualToString:@"iCloud.ok"],
          @"core: containers of the wrong shape are skipped");
    check([XSICloudDefaultContainer(@{@"XSideOriginalBundleID": @"com.vendor.app",
                                      @"CFBundleIdentifier": @"com.vendor.app.TEAM123456"}) isEqualToString:@"iCloud.com.vendor.app"],
          @"core: the original bundle id, not the signed one");
    check([XSICloudDefaultContainer(@{@"CFBundleIdentifier": @"com.vendor.app"}) isEqualToString:@"iCloud.com.vendor.app"],
          @"core: the bundle id when XSide wrote nothing");
    check([XSICloudDefaultContainer(@{@"XSideOriginalBundleID": @[@"x"], @"XSideICloudContainers": @"iCloud.x"}) isEqualToString:@"iCloud.unknown"],
          @"core: wrong types ignored");
    check([XSICloudDefaultContainer((NSDictionary *)@[]) isEqualToString:@"iCloud.unknown"], @"core: not a dictionary");
    check([XSICloudStoreSuite(nil) isEqualToString:@"io.github.xside.icloud-kvs.default"], @"core: default store suite");
    check([XSICloudStoreSuite(@"other") isEqualToString:@"io.github.xside.icloud-kvs.other"], @"core: additional store suite");
}

static void testShim(void) {
    CKContainer *container = [CKContainer defaultContainer];
    check([container.containerIdentifier isEqualToString:@"iCloud.com.example.icloudtest"],
          [NSString stringWithFormat:@"defaultContainer is the original app's (%@)", container.containerIdentifier]);
    check([[CKContainer containerWithIdentifier:@"iCloud.other"].containerIdentifier isEqualToString:@"iCloud.other"],
          @"containerWithIdentifier keeps its identifier");
    check([CKContainer defaultContainer] == container, @"one stub per container");
    if (class_getInstanceMethod([CKContainer class], @selector(_initWithContainerIdentifier:))) {
        __weak id receiver = nil;
        CKContainer *initialised = nil;
        for (int i = 0; i < 3; i++) @autoreleasepool {
            CKContainer *allocated = [CKContainer alloc];
            receiver = allocated;
            initialised = [allocated _initWithContainerIdentifier:@"iCloud.init"];
        }
        check([initialised.containerIdentifier isEqualToString:@"iCloud.init"], @"private init path: a stub");
        check(receiver == nil, @"private init path: the allocated receiver is freed, not kept");
    } else {
        printf("skip private init path (not on this macOS)\n");
    }

    __block CKAccountStatus status = CKAccountStatusAvailable;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    [container accountStatusWithCompletionHandler:^(CKAccountStatus st, NSError *e) { status = st; dispatch_semaphore_signal(s); }];
    check(waitFor(s) && status == CKAccountStatusNoAccount, @"accountStatus: no account");

    SEL accountInfo = NSSelectorFromString(@"accountInfoWithCompletionHandler:");
    if ([container respondsToSelector:accountInfo]) {
        __block id info = nil; __block NSError *error = (NSError *)@"unset";
        s = dispatch_semaphore_create(0);
        void (^handler)(id, NSError *) = ^(id i, NSError *e) { info = i; error = e; dispatch_semaphore_signal(s); };
        ((void (*)(id, SEL, id))objc_msgSend)(container, accountInfo, handler);
        BOOL answered = waitFor(s);
        BOOL noAccount = info && [info respondsToSelector:@selector(accountStatus)]
            && ((NSInteger (*)(id, SEL))objc_msgSend)(info, @selector(accountStatus)) == CKAccountStatusNoAccount;
        check(answered && noAccount && error == nil, @"accountInfo (private): no account, no error");
    } else {
        printf("skip accountInfo (not on this macOS)\n");
    }

    __block NSError *userError = nil;
    s = dispatch_semaphore_create(0);
    [container fetchUserRecordIDWithCompletionHandler:^(CKRecordID *r, NSError *e) { userError = e; dispatch_semaphore_signal(s); }];
    check(waitFor(s) && notAuthenticated(userError), @"fetchUserRecordID: not authenticated");

    __block NSError *zonesError = nil;
    s = dispatch_semaphore_create(0);
    [container.privateCloudDatabase fetchAllRecordZonesWithCompletionHandler:^(NSArray *z, NSError *e) {
        zonesError = e; dispatch_semaphore_signal(s);
    }];
    check(waitFor(s) && notAuthenticated(zonesError), @"database convenience call: not authenticated");

    __block NSError *opError = nil;
    dispatch_semaphore_t blockDone = dispatch_semaphore_create(0), opDone = dispatch_semaphore_create(0);
    CKFetchRecordZonesOperation *op = [CKFetchRecordZonesOperation fetchAllRecordZonesOperation];
    op.fetchRecordZonesCompletionBlock = ^(NSDictionary *zones, NSError *e) { opError = e; dispatch_semaphore_signal(blockDone); };
    op.completionBlock = ^{ dispatch_semaphore_signal(opDone); };
    [container.privateCloudDatabase addOperation:op];
    check(waitFor(blockDone) && notAuthenticated(opError), @"operation: completion block gets not authenticated");
    check(waitFor(opDone), @"operation: NSOperation finishes");

    NSUbiquitousKeyValueStore *kvs = [NSUbiquitousKeyValueStore defaultStore];
    [kvs setString:@"value" forKey:@"xside.test"];
    check([[kvs stringForKey:@"xside.test"] isEqualToString:@"value"] && [kvs synchronize], @"key-value store: local");
    [kvs setObject:[NSObject new] forKey:@"xside.bad"]; // not a property list value: ignored, no exception
    check([kvs objectForKey:@"xside.bad"] == nil, @"key-value store: a bad value is ignored");
    [kvs removeObjectForKey:@"xside.test"];
    check([kvs stringForKey:@"xside.test"] == nil, @"key-value store: remove");
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:XSICloudStoreSuite(nil)];

    check(NSFileManager.defaultManager.ubiquityIdentityToken == nil, @"ubiquityIdentityToken: nil");
    check([NSFileManager.defaultManager URLForUbiquityContainerIdentifier:nil] == nil, @"ubiquity container: nil");
}

int main(void) {
    @autoreleasepool {
        testCore();
        testShim();
        printf(failures ? "%d failure(s)\n" : "all iCloud shim checks passed\n", failures);
        return failures ? 1 : 0;
    }
}
