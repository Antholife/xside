// XSideICloud.dylib: the "Simulate signed-out iCloud" install option (see
// Sources/XSideCore/ICloudSignedOut.swift). An app signed with a free account has no iCloud
// entitlement and CloudKit stops it at its first use; with this library it behaves as on a device
// signed out of iCloud. Independent of XSide's module (App/Welcome); added only when the option
// is on for that installation.
//
// - CKContainer: +defaultContainer, +containerWithIdentifier: and the private init paths return
//   a stub (a runtime subclass of CKContainer, allocated with NSObject's allocator, never
//   initialised by CloudKit; CloudKit warns that subclassing CKContainer/CKDatabase will become an
//   error: when the subclass can't be made or its +initialize throws, an NSProxy stub with the
//   same methods and answers stands in, passing isKindOfClass: for the class it replaces).
//   accountStatus -> CKAccountStatusNoAccount, the private accountInfo
//   -> a CKAccountInfo saying no account (Core Data / SwiftData mirroring and CKSyncEngine wait
//   instead of retrying), every other method with a completion block -> CKErrorNotAuthenticated.
// - CKDatabase: stub databases (same technique); addOperation: and every convenience method
//   complete with CKErrorNotAuthenticated.
// - CKOperation -start: never reaches the daemon; the operation finishes with
//   CKErrorNotAuthenticated through CloudKit's own finish path (its completion blocks, the Swift
//   result blocks layered on them, NSOperation.completionBlock and isFinished all fire).
// - NSUbiquitousKeyValueStore: +defaultStore / +additionalStoreWithIdentifier: return a local
//   store backed by an NSUserDefaults suite. Never posts DidChangeExternally.
// - NSFileManager: ubiquityIdentityToken -> nil, URLForUbiquityContainerIdentifier: -> nil,
//   setUbiquitous:... -> NO + error.
//
// It runs inside apps XSide doesn't know: every hook checks that the class and method exist and
// does nothing otherwise; nothing here throws into the app. CloudKit is linked weakly
// (-weak_framework CloudKit): it is loaded and initialised before this library's constructor,
// which installs every hook at once, even in an app that doesn't link CloudKit itself (Core Data
// and SwiftData load it at runtime and start mirroring on their own queue right away).
// Logs: os_log, prefix "[XSiCloud]".
// The default container comes from the Info.plist file (XSideOriginalBundleID,
// XSideICloudContainers, written by XSide at signing), not from NSBundle. Nothing is installed
// unless that file has XSideICloudSignedOut = true (written only when the option applied).

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <malloc/malloc.h>
#import "XSICloudCore.h"

#define XLOG(fmt, ...) os_log(xsiLog(), "[XSiCloud] " fmt, ##__VA_ARGS__)

static os_log_t xsiLog(void) {
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("io.github.xside.icloud", "shim"); });
    return log;
}

static const NSInteger kCKErrorNotAuthenticated = 9;   // CKErrorNotAuthenticated
static const NSInteger kCKAccountStatusNoAccount = 3;  // CKAccountStatusNoAccount

static NSError *xsiNotAuthenticated(void) {
    return [NSError errorWithDomain:@"CKErrorDomain" code:kCKErrorNotAuthenticated userInfo:@{
        NSLocalizedDescriptionKey: @"No iCloud account available (sideloaded app: iCloud is not supported).",
    }];
}

// One serial queue, off main, like CloudKit's own callback delivery: completion handlers never
// run concurrently with each other.
static dispatch_queue_t xsiCallbackQueue(void) {
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("io.github.xside.icloud.callbacks",
                                      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

/// The app's Info.plist, from the file (tweaks fake what NSBundle reports).
static NSDictionary *xsiInfo(void) {
    static NSDictionary *info; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Info.plist"];
        NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
        id plist = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
        info = [plist isKindOfClass:NSDictionary.class] ? plist : @{};
    });
    return info;
}

// Allocates an instance with NSObject's allocator: CKContainer overrides +allocWithZone:.
static id xsiRawAlloc(Class cls) {
    if (!cls) return nil;
    IMP rootAlloc = method_getImplementation(class_getClassMethod([NSObject class], @selector(allocWithZone:)));
    return ((id (*)(Class, SEL, NSZone *))rootAlloc)(cls, @selector(allocWithZone:), NULL);
}

#pragma mark - Calling an arbitrary completion block

// Block ABI (libclosure Block_private.h).
enum { XSI_BLOCK_HAS_COPY_DISPOSE = (1 << 25), XSI_BLOCK_HAS_SIGNATURE = (1 << 30), XSI_BLOCK_SMALL_DESCRIPTOR = (1 << 22) };
struct xsi_block_layout { void *isa; volatile int32_t flags; int32_t reserved; void *invoke; void *descriptor; };
struct xsi_desc_small { uint32_t size; int32_t signature; int32_t layout; int32_t copy; int32_t dispose; };

static const char *xsiBlockSignature(id block) {
    if (!block) return NULL;
    struct xsi_block_layout *b = (__bridge void *)block;
    if (!(b->flags & XSI_BLOCK_HAS_SIGNATURE) || !b->descriptor) return NULL;
    if (b->flags & XSI_BLOCK_SMALL_DESCRIPTOR) {
        struct xsi_desc_small *d = b->descriptor;
        return d->signature ? (const char *)&d->signature + d->signature : NULL;
    }
    uint8_t *d = (uint8_t *)b->descriptor + 2 * sizeof(unsigned long);
    if (b->flags & XSI_BLOCK_HAS_COPY_DISPOSE) d += 2 * sizeof(void *);
    return *(const char **)d;
}

static NSMethodSignature *xsiBlockMethodSignature(id block) {
    const char *types = xsiBlockSignature(block);
    if (!types) return nil;
    @try { return [NSMethodSignature signatureWithObjCTypes:types]; } @catch (__unused NSException *e) { return nil; }
}

// Calls `block` with zero/nil for every argument, the last object argument being `error`.
// `firstInteger`, when non-nil, is passed as the first integer argument (an account status).
static void xsiCallBlock(id block, NSError *error, NSNumber *firstInteger) {
    NSMethodSignature *sig = xsiBlockMethodSignature(block);
    if (!sig) { XLOG("block without signature, not called"); return; }
    @try {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        NSUInteger lastObject = 0;
        for (NSUInteger i = 1; i < sig.numberOfArguments; i++) {
            const char *t = [sig getArgumentTypeAtIndex:i];
            if (t[0] == '@' && t[1] != '?') lastObject = i;
        }
        BOOL integerSet = NO;
        for (NSUInteger i = 1; i < sig.numberOfArguments; i++) {
            const char *t = [sig getArgumentTypeAtIndex:i];
            NSUInteger size = 0; NSGetSizeAndAlignment(t, &size, NULL);
            void *buf = calloc(1, MAX(size, sizeof(long long)));
            if (!buf) return;
            if (i == lastObject && error) {
                __unsafe_unretained NSError *e = error; memcpy(buf, &e, sizeof(e));
            } else if (firstInteger && !integerSet && strchr("qlisQLIScC", t[0]) && size <= sizeof(long long)) {
                long long v = firstInteger.longLongValue; memcpy(buf, &v, size); integerSet = YES;
            }
            [inv setArgument:buf atIndex:i];
            free(buf);
        }
        [inv retainArguments];
        [inv invokeWithTarget:block];
    } @catch (NSException *e) {
        XLOG("block not called: %{public}@", e.reason);
    }
}

static void xsiCallBlockLater(id block, NSError *error, NSNumber *firstInteger) {
    if (!block) return;
    // `id` captures are retained, not copied: a caller's stack block must be copied here.
    id heapBlock = [block copy];
    dispatch_async(xsiCallbackQueue(), ^{ xsiCallBlock(heapBlock, error, firstInteger); });
}

static void xsiEnqueueOperation(id op, id database);

// Generic forwarding: a call to any non-overridden method fails "not authenticated": its last
// block argument is called back with the error, its return value is zero/nil. A call that hands
// over an operation (`addOperation:wrappingDatabase:...`, `_scheduleConvenienceOperation:...`)
// runs it, so it completes (with NotAuthenticated, see xsi_operationStart).
static void xsiFailInvocation(NSInvocation *inv, NSString *owner) {
    NSMethodSignature *sig = inv.methodSignature;
    if (sig.numberOfArguments > 2 && [sig getArgumentTypeAtIndex:2][0] == '@' && [NSStringFromSelector(inv.selector) containsString:@"Operation:"]) {
        __unsafe_unretained id op = nil; [inv getArgument:&op atIndex:2];
        Class operation = objc_getClass("CKOperation");
        if (operation && [op isKindOfClass:operation]) {
            XLOG("%{public}@ -%{public}s -> runs %{public}@", owner, sel_getName(inv.selector), NSStringFromClass([op class]));
            xsiEnqueueOperation(op, nil);
            return;
        }
    }
    id block = nil;
    for (NSUInteger i = sig.numberOfArguments; i-- > 2;) {
        const char *t = [sig getArgumentTypeAtIndex:i];
        if (t[0] == '@' && t[1] == '?') { __unsafe_unretained id b = nil; [inv getArgument:&b atIndex:i]; block = b; break; }
    }
    XLOG("%{public}@ -%{public}s -> %{public}s", owner, sel_getName(inv.selector), block ? "NotAuthenticated" : "nil");
    if (sig.methodReturnLength) {
        void *zero = calloc(1, sig.methodReturnLength);
        if (zero) { [inv setReturnValue:zero]; free(zero); }
    }
    xsiCallBlockLater(block, xsiNotAuthenticated(), nil);
}

#pragma mark - Stub classes (methods copied into runtime subclasses of CKContainer / CKDatabase)

static const void *kStubBaseKey = &kStubBaseKey;

// The class a stub stands for (CKContainer, CKDatabaseImplementation...): its superclass, or for
// an NSProxy stub the class recorded on it when it was made.
static Class xsiStubBase(id object) {
    Class cls = object_getClass(object);
    Class base = cls ? objc_getAssociatedObject(cls, kStubBaseKey) : nil;
    return base ?: class_getSuperclass(cls);
}

static Class gStubContainerClass, gStubDatabaseClass, gStubContainerImplClass, gStubDatabaseImplClass;
static NSMutableDictionary<NSString *, id> *gContainers;   // identifier -> stub container
static NSOperationQueue *gStubOperationQueue;
static const void *kIdentifierKey = &kIdentifierKey, *kScopeKey = &kScopeKey, *kContainerKey = &kContainerKey;
static const void *kDatabasesKey = &kDatabasesKey, *kImplKey = &kImplKey, *kConfigKey = &kConfigKey;

// The object CloudKit's Swift overlay talks to behind a container or database
// (`-implementation`): a stub of CKContainerImplementation / CKDatabaseImplementation whose
// every method fails NotAuthenticated. Created once per owner, kept with it.
static id xsiImplementation(id owner, Class implClass) {
    @synchronized (owner) {
        id impl = objc_getAssociatedObject(owner, kImplKey);
        if (!impl && implClass) {
            impl = xsiRawAlloc(implClass);
            if (impl) objc_setAssociatedObject(owner, kImplKey, impl, OBJC_ASSOCIATION_RETAIN);
        }
        return impl;
    }
}

static id xsiStubDatabase(id container, NSInteger scope);

static void xsiEnqueueOperation(id op, id database) {
    if (!op || !gStubOperationQueue) return;
    // Like CloudKit does for an operation added to a database: point it at that database.
    if (database && [op respondsToSelector:@selector(setDatabase:)]) {
        @try { ((void (*)(id, SEL, id))objc_msgSend)(op, @selector(setDatabase:), database); } @catch (__unused id e) {}
    }
    @try { [gStubOperationQueue addOperation:op]; } @catch (NSException *e) {
        XLOG("operation not run: %{public}@", e.reason);
    }
}

@interface XSiStubContainerTemplate : NSObject @end
@implementation XSiStubContainerTemplate
- (NSString *)containerIdentifier { return objc_getAssociatedObject(self, kIdentifierKey); }
- (void)accountStatusWithCompletionHandler:(id)handler {
    XLOG("accountStatus -> NoAccount (%{public}@)", [self containerIdentifier]);
    xsiCallBlockLater(handler, nil, @(kCKAccountStatusNoAccount));
}
// Private, used by Core Data/SwiftData mirroring and CKSyncEngine: a CKAccountInfo saying "no
// account" with no error, like a signed-out device. An error here (the generic NotAuthenticated)
// makes Core Data retry its setup in a tight loop instead of waiting for an account. Without
// CKAccountInfo, or with a handler of another shape, it fails NotAuthenticated like the rest.
- (void)accountInfoWithCompletionHandler:(id)handler {
    if (!handler) return;
    Class infoClass = objc_getClass("CKAccountInfo");
    NSMethodSignature *sig = xsiBlockMethodSignature(handler);
    BOOL expected = sig.numberOfArguments == 3 && [sig getArgumentTypeAtIndex:1][0] == '@'
        && [sig getArgumentTypeAtIndex:2][0] == '@';
    id info = nil;
    if (infoClass && expected) {
        @try {
            info = [infoClass new];
            if ([info respondsToSelector:@selector(setAccountStatus:)])
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(info, @selector(setAccountStatus:), kCKAccountStatusNoAccount);
            if ([info respondsToSelector:@selector(setHasValidCredentials:)])
                ((void (*)(id, SEL, BOOL))objc_msgSend)(info, @selector(setHasValidCredentials:), NO);
        } @catch (__unused NSException *e) { info = nil; }
    }
    if (!info) {
        XLOG("accountInfo -> NotAuthenticated");
        xsiCallBlockLater(handler, xsiNotAuthenticated(), nil);
        return;
    }
    XLOG("accountInfo -> NoAccount");
    void (^block)(id, NSError *) = [handler copy];
    dispatch_async(xsiCallbackQueue(), ^{ block(info, nil); });
}
- (void)fetchUserRecordIDWithCompletionHandler:(id)handler {
    XLOG("fetchUserRecordID -> NotAuthenticated");
    xsiCallBlockLater(handler, xsiNotAuthenticated(), nil);
}
- (id)privateCloudDatabase { return xsiStubDatabase(self, 2); }
- (id)publicCloudDatabase { return xsiStubDatabase(self, 1); }
- (id)sharedCloudDatabase { return xsiStubDatabase(self, 3); }
- (id)databaseWithDatabaseScope:(NSInteger)scope { return xsiStubDatabase(self, scope); }
- (id)implementation { return xsiImplementation(self, gStubContainerImplClass); }
- (id)convenienceConfiguration {
    @synchronized (self) {
        id conf = objc_getAssociatedObject(self, kConfigKey);
        Class confClass = objc_getClass("CKOperationConfiguration");
        if (!conf && confClass) {
            conf = [confClass new];
            if (conf) objc_setAssociatedObject(self, kConfigKey, conf, OBJC_ASSOCIATION_RETAIN);
        }
        return conf;
    }
}
- (void)addOperation:(id)op { XLOG("container addOperation %{public}@", NSStringFromClass([op class])); xsiEnqueueOperation(op, nil); }
- (NSString *)description { return [NSString stringWithFormat:@"<CKContainer (XSide stub) %@>", [self containerIdentifier]]; }
- (NSString *)debugDescription { return [self description]; }
- (id)forwardingTargetForSelector:(SEL)sel { return nil; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *s = [objc_getClass("CKContainer") instanceMethodSignatureForSelector:sel];
    if (!s) {
        Method m = class_getInstanceMethod(objc_getClass("CKContainerImplementation"), sel);
        if (m) s = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
    }
    if (!s) XLOG("CKContainer: unknown selector %{public}s", sel_getName(sel));
    return s;
}
- (void)forwardInvocation:(NSInvocation *)inv { xsiFailInvocation(inv, @"CKContainer"); }
@end

@interface XSiStubDatabaseTemplate : NSObject @end
@implementation XSiStubDatabaseTemplate
- (NSInteger)databaseScope { return [objc_getAssociatedObject(self, kScopeKey) integerValue]; }
- (NSInteger)scope { return [self databaseScope]; }
- (id)container { return objc_getAssociatedObject(self, kContainerKey); }
- (id)implementation { return xsiImplementation(self, gStubDatabaseImplClass); }
- (void)addOperation:(id)op { XLOG("database addOperation %{public}@", NSStringFromClass([op class])); xsiEnqueueOperation(op, self); }
- (NSString *)description { return [NSString stringWithFormat:@"<CKDatabase (XSide stub) scope %ld>", (long)[self databaseScope]]; }
- (NSString *)debugDescription { return [self description]; }
- (id)forwardingTargetForSelector:(SEL)sel { return nil; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *s = [objc_getClass("CKDatabase") instanceMethodSignatureForSelector:sel];
    if (!s) XLOG("CKDatabase: unknown selector %{public}s", sel_getName(sel));
    return s;
}
- (void)forwardInvocation:(NSInvocation *)inv { xsiFailInvocation(inv, @"CKDatabase"); }
@end

// Behind-the-scenes implementation objects: everything fails NotAuthenticated.
@interface XSiStubImplTemplate : NSObject @end
@implementation XSiStubImplTemplate
- (NSString *)description { return [NSString stringWithFormat:@"<%s (XSide stub)>", class_getName(xsiStubBase(self))]; }
- (NSString *)debugDescription { return [self description]; }
- (id)forwardingTargetForSelector:(SEL)sel { return nil; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    Method m = class_getInstanceMethod(xsiStubBase(self), sel);
    if (!m) XLOG("%{public}s: unknown selector %{public}s", class_getName(object_getClass(self)), sel_getName(sel));
    return m ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)] : nil;
}
- (void)forwardInvocation:(NSInvocation *)inv { xsiFailInvocation(inv, NSStringFromClass(xsiStubBase(self))); }
@end

// Never forwarded: object lifetime and identity stay NSObject's.
static BOOL xsiKeepSelector(SEL sel) {
    static NSSet *keep;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keep = [NSSet setWithArray:@[@".cxx_destruct", @"dealloc", @"hash", @"isEqual:", @"class", @"retain", @"release",
                                     @"autorelease", @"retainCount", @"_tryRetain", @"_isDeallocating", @"allowsWeakReference",
                                     @"retainWeakReference", @"respondsToSelector:", @"conformsToProtocol:", @"isKindOfClass:",
                                     @"copyWithZone:", @"copy", @"zone", @"self"]];
    });
    return [keep containsObject:NSStringFromSelector(sel)];
}

// A subclass of `base` with the template's methods, every other method of `base` forwarded.
// Nil when it can't be made (then nothing is hooked).
static Class xsiMakeStubClass(Class base, Class template, const char *name) {
    if (!base || !template) return nil;
    Class existing = objc_getClass(name);
    if (existing) return class_getSuperclass(existing) == base ? existing : nil;
    Class cls = objc_allocateClassPair(base, name, 0);
    if (!cls) return nil;
    unsigned n = 0;
    Method *ms = class_copyMethodList(template, &n);
    for (unsigned i = 0; i < n; i++) class_addMethod(cls, method_getName(ms[i]), method_getImplementation(ms[i]), method_getTypeEncoding(ms[i]));
    free(ms);
    for (Class c = base; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        ms = class_copyMethodList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            SEL sel = method_getName(ms[i]);
            if (xsiKeepSelector(sel)) continue;
            // Fails (keeps the template's method) when the template implements it.
            class_addMethod(cls, sel, _objc_msgForward, method_getTypeEncoding(ms[i]));
        }
        free(ms);
    }
    objc_registerClassPair(cls);
    return cls;
}

// What an NSProxy stub adds to its template's methods: it passes for an instance of the class it
// replaces (Swift casts and isKindOfClass: checks ask it), and answers respondsToSelector: as one.
@interface XSiStubProxyTemplate : NSObject @end
@implementation XSiStubProxyTemplate
- (BOOL)isKindOfClass:(Class)c {
    if (!c) return NO;
    for (Class k = xsiStubBase(self); k; k = class_getSuperclass(k)) if (k == c) return YES;
    for (Class k = object_getClass(self); k; k = class_getSuperclass(k)) if (k == c) return YES;
    return NO;
}
- (BOOL)isMemberOfClass:(Class)c { return c && c == xsiStubBase(self); }
- (BOOL)respondsToSelector:(SEL)sel {
    if (!sel) return NO;
    return class_respondsToSelector(object_getClass(self), sel) || [xsiStubBase(self) instancesRespondToSelector:sel];
}
- (BOOL)conformsToProtocol:(Protocol *)p { return p && [xsiStubBase(self) conformsToProtocol:p]; }
@end

static void xsiCopyMethods(Class from, Class to) {
    unsigned n = 0;
    Method *ms = class_copyMethodList(from, &n);
    for (unsigned i = 0; i < n; i++) class_addMethod(to, method_getName(ms[i]), method_getImplementation(ms[i]), method_getTypeEncoding(ms[i]));
    free(ms);
}

// The fallback: an NSProxy subclass with the template's methods; every other message reaches the
// template's forwardInvocation: (NSProxy implements almost nothing). Nil when it can't be made.
static Class xsiMakeProxyClass(Class base, Class template, const char *name) {
    if (!base || !template) return nil;
    Class existing = objc_getClass(name);
    if (existing) return objc_getAssociatedObject(existing, kStubBaseKey) == base ? existing : nil;
    Class cls = objc_allocateClassPair([NSProxy class], name, 0);
    if (!cls) return nil;
    xsiCopyMethods(template, cls);
    xsiCopyMethods([XSiStubProxyTemplate class], cls);
    objc_registerClassPair(cls);
    objc_setAssociatedObject(cls, kStubBaseKey, base, OBJC_ASSOCIATION_ASSIGN);   // classes live forever
    return cls;
}

// Test builds only (scripts/test-icloud-shim.sh compiles with XSICLOUD_TEST_HOOKS):
// XSICLOUD_FORCE_PROXY=1 takes the fallback as if CloudKit refused every subclass.
static BOOL xsiForceProxy(void) {
#if XSICLOUD_TEST_HOOKS
    const char *v = getenv("XSICLOUD_FORCE_PROXY");
    return v && strcmp(v, "1") == 0;
#else
    return NO;
#endif
}

// Whether CloudKit takes the subclass: the first message runs its +initialize (and the base
// class's) here, where an exception is caught, rather than in the app's first call.
static BOOL xsiSubclassAccepted(Class cls) {
    if (!cls) return NO;
    @try {
        return ((Class (*)(id, SEL))objc_msgSend)(cls, @selector(class)) == cls;
    } @catch (NSException *e) {
        XLOG("%{public}s refused: %{public}@", class_getName(cls), e.reason);
        return NO;
    }
}

// The stub class for `base`: a runtime subclass, else (CloudKit refuses it) an NSProxy stub.
static Class xsiStubClass(Class base, Class template, const char *name, const char *proxyName) {
    if (!base || !template) return nil;
    if (!xsiForceProxy()) {
        Class cls = xsiMakeStubClass(base, template, name);
        if (xsiSubclassAccepted(cls)) return cls;
    }
    Class proxy = xsiMakeProxyClass(base, template, proxyName);
    XLOG("%{public}s: subclass unavailable, %{public}s stub", class_getName(base), proxy ? "NSProxy" : "no");
    return proxy;
}

static id xsiStubContainer(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) identifier = XSICloudDefaultContainer(xsiInfo());
    @synchronized (gContainers) {
        id c = gContainers[identifier];
        if (!c) {
            c = xsiRawAlloc(gStubContainerClass);   // kept forever: CloudKit's -dealloc never runs on it
            if (!c) return nil;
            objc_setAssociatedObject(c, kIdentifierKey, identifier, OBJC_ASSOCIATION_COPY);
            objc_setAssociatedObject(c, kDatabasesKey, [NSMutableDictionary new], OBJC_ASSOCIATION_RETAIN);
            gContainers[identifier] = c;
            XLOG("stub container %{public}@", identifier);
        }
        return c;
    }
}

static id xsiStubDatabase(id container, NSInteger scope) {
    @synchronized (gContainers) {
        NSMutableDictionary *dbs = objc_getAssociatedObject(container, kDatabasesKey);
        id db = dbs[@(scope)];
        if (!db) {
            db = xsiRawAlloc(gStubDatabaseClass);
            if (!db) return nil;
            objc_setAssociatedObject(db, kScopeKey, @(scope), OBJC_ASSOCIATION_RETAIN);
            objc_setAssociatedObject(db, kContainerKey, container, OBJC_ASSOCIATION_ASSIGN);   // container lives forever
            dbs[@(scope)] = db;
        }
        return db;
    }
}

#pragma mark - CKContainer entry points

static id xsi_defaultContainer(id self, SEL _cmd) { return xsiStubContainer(nil); }
static id xsi_containerWithIdentifier(id self, SEL _cmd, NSString *identifier) { return xsiStubContainer(identifier); }

// What an uninitialised CKContainer receiver becomes once its init path returned a stub: a plain
// NSObject, so the release ARC sends it frees it with NSObject's -dealloc (CloudKit's -dealloc
// expects an initialised container).
@interface XSiSpentReceiver : NSObject @end
@implementation XSiSpentReceiver @end

// The receivers that couldn't be turned into an XSiSpentReceiver: kept alive, once each.
static NSHashTable *gKeptReceivers;

static void xsiRetireReceiver(id receiver) {
    if (!receiver) return;
    Class container = objc_getClass("CKContainer");
    void *raw = (__bridge void *)receiver;
    // Only a fresh heap allocation of a CKContainer, never anything shared or of another kind.
    if (container && [receiver isKindOfClass:container] && malloc_zone_from_ptr(raw)
        && malloc_size(raw) >= class_getInstanceSize([XSiSpentReceiver class])) {
        object_setClass(receiver, [XSiSpentReceiver class]);
        return;
    }
    @synchronized (gKeptReceivers) { [gKeptReceivers addObject:receiver]; }
}

// The private init paths, as init-family methods so ARC consumes the receiver and returns +1.
@interface XSiInitTemplate : NSObject @end
@implementation XSiInitTemplate
static id xsiInitResult(id receiver, id containerIDOrIdentifier) {
    xsiRetireReceiver(receiver);
    NSString *identifier = nil;
    if ([containerIDOrIdentifier isKindOfClass:[NSString class]]) identifier = containerIDOrIdentifier;
    else if ([containerIDOrIdentifier respondsToSelector:@selector(containerIdentifier)]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(containerIDOrIdentifier, @selector(containerIdentifier));
        if ([value isKindOfClass:NSString.class]) identifier = value;
    }
    XLOG("CKContainer init -> stub (%{public}@)", identifier ?: @"default");
    return xsiStubContainer(identifier);
}
- (instancetype)initWithContainerID:(id)cid { return xsiInitResult(self, cid); }
- (instancetype)initWithContainerID:(id)cid options:(id)options { return xsiInitResult(self, cid); }
- (instancetype)_initWithContainerIdentifier:(id)identifier { return xsiInitResult(self, identifier); }
- (instancetype)initWithContainerSetupInfo:(id)info { return xsiInitResult(self, nil); }
- (instancetype)initWithImplementation:(id)impl convenienceConfiguration:(id)conf { return xsiInitResult(self, nil); }
- (instancetype)initUnconfiguredContainerWithImplementation:(id)impl { return xsiInitResult(self, nil); }
@end

#pragma mark - CKOperation

// The operation's final completion blocks: `<verb>CompletionBlock` (the Swift `...ResultBlock`
// setters store theirs there too), else its `_wrapper` variant. Per-item blocks (`per...`,
// `recordZoneFetchCompletionBlock`) are skipped: they take a non-null item id.
static NSArray *xsiFinalBlocks(id op) {
    NSMutableArray *blocks = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    Class stop = objc_getClass("CKOperation");
    for (Class c = [op class]; c && c != stop; c = class_getSuperclass(c)) {
        unsigned n = 0;
        objc_property_t *props = class_copyPropertyList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            const char *rawName = property_getName(props[i]);
            const char *attrs = property_getAttributes(props[i]);
            if (!rawName || !attrs) continue;
            NSString *name = @(rawName);
            if (strncmp(attrs, "T@?", 3) != 0 || ![name hasSuffix:@"CompletionBlock"] || [name hasPrefix:@"per"]
                || [name hasPrefix:@"recordZoneFetch"] || [seen containsObject:name]) continue;
            [seen addObject:name];
            id block = nil;
            @try {
                block = [op valueForKey:name];
                if (!block) block = [op valueForKey:[name stringByAppendingString:@"_wrapper"]];
            } @catch (__unused NSException *e) {}
            if (block) [blocks addObject:block];
        }
        free(props);
    }
    return blocks;
}

// -[CKOperation start] never reaches the daemon: the operation's final completion blocks get
// CKErrorNotAuthenticated, then it moves to finished (NSOperation.completionBlock, dependencies
// and waitUntilFinished behave).
static void xsi_operationStart(id op, SEL _cmd) {
    NSArray *blocks = xsiFinalBlocks(op);
    XLOG("operation %{public}@ -> NotAuthenticated (%lu completion blocks)", NSStringFromClass([op class]), (unsigned long)blocks.count);
    @try {
        if ([op respondsToSelector:@selector(transitionToExecuting)])
            ((BOOL (*)(id, SEL))objc_msgSend)(op, @selector(transitionToExecuting));
    } @catch (__unused NSException *e) {}
    NSError *error = xsiNotAuthenticated();
    dispatch_async(xsiCallbackQueue(), ^{
        for (id block in blocks) xsiCallBlock(block, error, nil);
        @try {
            if ([op respondsToSelector:@selector(transitionToFinished)] && ((BOOL (*)(id, SEL))objc_msgSend)(op, @selector(transitionToFinished)))
                return;
            if ([op respondsToSelector:@selector(setIsFinished:)])
                ((void (*)(id, SEL, BOOL))objc_msgSend)(op, @selector(setIsFinished:), YES);
        } @catch (NSException *e) {
            XLOG("could not finish operation: %{public}@", e.reason);
        }
    });
}

#pragma mark - NSUbiquitousKeyValueStore

@interface XSiKeyValueStore : NSUbiquitousKeyValueStore
@property (nonatomic, strong) NSUserDefaults *xsiDefaults;
@end
@implementation XSiKeyValueStore
- (nullable id)objectForKey:(NSString *)key { return key ? [self.xsiDefaults objectForKey:key] : nil; }
- (void)setObject:(nullable id)object forKey:(NSString *)key {
    if (![key isKindOfClass:NSString.class]) return;
    if (!object) { [self.xsiDefaults removeObjectForKey:key]; return; }
    // NSUserDefaults stops the app on a value it can't store (iCloud's store would refuse it).
    if (![NSPropertyListSerialization propertyList:object isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
        XLOG("key-value store: not a property list value, ignored");
        return;
    }
    @try { [self.xsiDefaults setObject:object forKey:key]; } @catch (__unused NSException *e) {
        XLOG("key-value store: value not stored");
    }
}
- (void)removeObjectForKey:(NSString *)key { if (key) [self.xsiDefaults removeObjectForKey:key]; }
- (nullable NSString *)stringForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSString class]] ? v : nil; }
- (nullable NSArray *)arrayForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSArray class]] ? v : nil; }
- (nullable NSDictionary *)dictionaryForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSDictionary class]] ? v : nil; }
- (nullable NSData *)dataForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSData class]] ? v : nil; }
- (long long)longLongForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(longLongValue)] ? [v longLongValue] : 0; }
- (double)doubleForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0; }
- (BOOL)boolForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO; }
- (void)setString:(nullable NSString *)v forKey:(NSString *)key { [self setObject:v forKey:key]; }
- (void)setData:(nullable NSData *)v forKey:(NSString *)key { [self setObject:v forKey:key]; }
- (void)setArray:(nullable NSArray *)v forKey:(NSString *)key { [self setObject:v forKey:key]; }
- (void)setDictionary:(nullable NSDictionary *)v forKey:(NSString *)key { [self setObject:v forKey:key]; }
- (void)setLongLong:(long long)v forKey:(NSString *)key { [self setObject:@(v) forKey:key]; }
- (void)setDouble:(double)v forKey:(NSString *)key { [self setObject:@(v) forKey:key]; }
- (void)setBool:(BOOL)v forKey:(NSString *)key { [self setObject:@(v) forKey:key]; }
- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
    // Only this suite's own keys, not NSGlobalDomain's.
    NSString *suite = objc_getAssociatedObject(self, kIdentifierKey);
    return (suite ? [self.xsiDefaults persistentDomainForName:suite] : nil) ?: @{};
}
- (BOOL)synchronize { return YES; }
- (void)synchronizeWithCompletionHandler:(id)handler { xsiCallBlockLater(handler, nil, nil); }
- (void)registerDefaultValues:(NSDictionary *)values { if ([values isKindOfClass:NSDictionary.class]) [self.xsiDefaults registerDefaults:values]; }
- (NSString *)description { return @"<NSUbiquitousKeyValueStore (XSide local store)>"; }
@end

static NSMutableDictionary<NSString *, XSiKeyValueStore *> *gStores;
static id xsiStore(NSString *identifier) {
    NSString *suite = XSICloudStoreSuite(identifier);
    @synchronized (gStores) {
        XSiKeyValueStore *s = gStores[suite];
        if (!s) {
            s = xsiRawAlloc([XSiKeyValueStore class]);   // NSUbiquitousKeyValueStore's init is never run
            s.xsiDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite] ?: NSUserDefaults.standardUserDefaults;
            objc_setAssociatedObject(s, kIdentifierKey, suite, OBJC_ASSOCIATION_COPY);
            gStores[suite] = s;
            XLOG("local key-value store %{public}@", suite);
        }
        return s;
    }
}
static id xsi_kvsDefaultStore(id self, SEL _cmd) { return xsiStore(nil); }
static id xsi_kvsAdditionalStore(id self, SEL _cmd, NSString *identifier) { return xsiStore(identifier ?: @"additional"); }

#pragma mark - NSFileManager

static id xsi_ubiquityIdentityToken(id self, SEL _cmd) { return nil; }
static id xsi_URLForUbiquityContainer(id self, SEL _cmd, NSString *identifier) {
    XLOG("URLForUbiquityContainerIdentifier -> nil");
    return nil;
}
static BOOL xsi_setUbiquitous(id self, SEL _cmd, BOOL flag, NSURL *url, NSURL *dest, NSError **error) {
    if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUbiquitousFileUnavailableError userInfo:nil];
    return NO;
}

#pragma mark - Installation

// Replaces `sel` on `cls` itself (not an inherited implementation). Nothing when either is missing.
static void xsiReplace(Class cls, SEL sel, IMP imp) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { XLOG("missing %{public}s on %{public}s", sel_getName(sel), class_getName(cls)); return; }
    if (!class_addMethod(cls, sel, imp, method_getTypeEncoding(m))) method_setImplementation(m, imp);
}

static void xsiInstallCloudKit(void) {
    static BOOL done;
    @synchronized ([NSObject class]) {
        if (done) return;
        Class container = objc_getClass("CKContainer"), database = objc_getClass("CKDatabase"), operation = objc_getClass("CKOperation");
        if (!container || !database || !operation) return;
        done = YES;
        gContainers = [NSMutableDictionary new];
        gKeptReceivers = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
        gStubOperationQueue = [NSOperationQueue new];
        gStubOperationQueue.name = @"XSiCloud stub operations";
        gStubContainerClass = xsiStubClass(container, [XSiStubContainerTemplate class], "XSiStubContainer", "XSiStubProxyContainer");
        gStubDatabaseClass = xsiStubClass(database, [XSiStubDatabaseTemplate class], "XSiStubDatabase", "XSiStubProxyDatabase");
        if (!gStubContainerClass || !gStubDatabaseClass) {
            XLOG("CloudKit hooks not installed: stub classes unavailable");
            return;
        }
        Class containerImpl = objc_getClass("CKContainerImplementation"), databaseImpl = objc_getClass("CKDatabaseImplementation");
        gStubContainerImplClass = xsiStubClass(containerImpl, [XSiStubImplTemplate class], "XSiStubContainerImplementation",
                                               "XSiStubProxyContainerImplementation");
        gStubDatabaseImplClass = xsiStubClass(databaseImpl, [XSiStubImplTemplate class], "XSiStubDatabaseImplementation",
                                              "XSiStubProxyDatabaseImplementation");

        Class meta = object_getClass(container);
        xsiReplace(meta, @selector(defaultContainer), (IMP)xsi_defaultContainer);
        xsiReplace(meta, @selector(containerWithIdentifier:), (IMP)xsi_containerWithIdentifier);
        unsigned n = 0;
        Method *inits = class_copyMethodList([XSiInitTemplate class], &n);
        for (unsigned i = 0; i < n; i++) {
            if (class_getInstanceMethod(container, method_getName(inits[i])))
                xsiReplace(container, method_getName(inits[i]), method_getImplementation(inits[i]));
        }
        free(inits);
        xsiReplace(operation, @selector(start), (IMP)xsi_operationStart);
        XLOG("CloudKit hooks installed (default container %{public}@)", XSICloudDefaultContainer(xsiInfo()));
    }
}

__attribute__((constructor)) static void xsiInit(void) {
    @autoreleasepool {
        @try {
            // Only an app XSide signed with the option on (the Info.plist says so).
            if (!XSICloudIsEnabled(xsiInfo())) {
                XLOG("not enabled for this app (no XSideICloudSignedOut in its Info.plist): nothing installed");
                return;
            }
            gStores = [NSMutableDictionary new];
            Class kvs = objc_getClass("NSUbiquitousKeyValueStore");
            if (kvs) {
                Class kvsMeta = object_getClass(kvs);
                xsiReplace(kvsMeta, @selector(defaultStore), (IMP)xsi_kvsDefaultStore);
                if (class_getInstanceMethod(kvsMeta, @selector(additionalStoreWithIdentifier:)))
                    xsiReplace(kvsMeta, @selector(additionalStoreWithIdentifier:), (IMP)xsi_kvsAdditionalStore);
            }
            Class fm = objc_getClass("NSFileManager");
            xsiReplace(fm, @selector(ubiquityIdentityToken), (IMP)xsi_ubiquityIdentityToken);
            xsiReplace(fm, @selector(URLForUbiquityContainerIdentifier:), (IMP)xsi_URLForUbiquityContainer);
            xsiReplace(fm, @selector(setUbiquitous:itemAtURL:destinationURL:error:), (IMP)xsi_setUbiquitous);
            XLOG("loaded (KVS local, ubiquity off)");
            // CloudKit is already loaded (weakly linked by this library): hooks in place before any
            // of the app's code runs. Nothing when CloudKit is missing.
            xsiInstallCloudKit();
            if (!objc_getClass("CKContainer")) XLOG("CloudKit not loaded: CloudKit hooks not installed");
        } @catch (NSException *e) {
            XLOG("not installed: %{public}@", e.reason);
        }
    }
}
