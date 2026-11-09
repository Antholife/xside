#import "XSICloudCore.h"

static NSString *XSICloudString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

NSString *XSICloudDefaultContainer(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class]) info = @{};
    id containers = info[@"XSideICloudContainers"];
    if ([containers isKindOfClass:NSArray.class]) {
        for (id c in containers) {
            NSString *s = XSICloudString(c);
            if ([s hasPrefix:@"iCloud."] && s.length > 7) return s;
        }
    }
    NSString *original = XSICloudString(info[@"XSideOriginalBundleID"]) ?: XSICloudString(info[@"CFBundleIdentifier"]);
    return [@"iCloud." stringByAppendingString:original ?: @"unknown"];
}

BOOL XSICloudIsEnabled(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class]) return NO;
    id value = info[@"XSideICloudSignedOut"];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}

NSString *XSICloudStoreSuite(NSString *identifier) {
    NSString *name = [identifier isKindOfClass:NSString.class] && identifier.length ? identifier : @"default";
    return [@"io.github.xside.icloud-kvs." stringByAppendingString:name];
}
