// Regression check for XSideICloud.dylib (App/ICloud): an app that syncs Core Data through
// CloudKit without linking CloudKit itself. Core Data loads CloudKit inside
// loadPersistentStores and sets up mirroring at once on its own queue while the main thread is
// still busy (building the UI). The shim's hooks must already be in place then, or CloudKit stops
// the process (no iCloud entitlement here, like an app signed with a free account).
// Built and run by scripts/test-icloud-shim.sh: this program links Foundation and CoreData only.
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import <objc/message.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { printf("FAIL usage: test-icloud-shim-coredata <store dir>\n"); return 1; }

        NSEntityDescription *entity = [NSEntityDescription new];
        entity.name = @"Item";
        entity.managedObjectClassName = @"NSManagedObject";
        NSAttributeDescription *title = [NSAttributeDescription new];
        title.name = @"title";
        title.attributeType = NSStringAttributeType;
        title.optional = YES;
        entity.properties = @[title];
        NSManagedObjectModel *model = [NSManagedObjectModel new];
        model.entities = @[entity];

        NSPersistentCloudKitContainer *container = [NSPersistentCloudKitContainer persistentContainerWithName:@"Test" managedObjectModel:model];
        NSPersistentStoreDescription *store = [NSPersistentStoreDescription persistentStoreDescriptionWithURL:
            [NSURL fileURLWithPath:[@(argv[1]) stringByAppendingPathComponent:@"Test.sqlite"]]];
        store.cloudKitContainerOptions = [[NSPersistentCloudKitContainerOptions alloc] initWithContainerIdentifier:@"iCloud.com.example.icloudtest"];
        [store setOption:@YES forKey:NSPersistentHistoryTrackingKey];
        container.persistentStoreDescriptions = @[store];

        __block NSError *loadError = nil;
        [container loadPersistentStoresWithCompletionHandler:^(NSPersistentStoreDescription *d, NSError *e) { loadError = e; }];
        // The app keeps building its UI: the main queue doesn't drain for a while.
        usleep(300 * 1000);
        // Then it runs; mirroring has time to reach CloudKit.
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3]];

        int failures = 0;
        if (loadError) { printf("FAIL store not loaded: %s\n", loadError.description.UTF8String); failures++; }
        Class ck = objc_getClass("CKContainer");
        id dflt = ck ? ((id (*)(id, SEL))objc_msgSend)(ck, NSSelectorFromString(@"defaultContainer")) : nil;
        BOOL stub = dflt && strstr(object_getClassName(dflt), "XSiStub") != NULL;
        printf("%s CloudKit hooked when Core Data loads it (%s)\n", stub ? "ok  " : "FAIL", dflt ? object_getClassName(dflt) : "no CloudKit");
        if (!stub) failures++;
        printf(failures ? "%d failure(s)\n" : "Core Data + CloudKit without linking CloudKit: no crash\n", failures);
        return failures ? 1 : 0;
    }
}
