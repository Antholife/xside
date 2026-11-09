// The pure part of XSideICloud.dylib, also compiled on the Mac by scripts/test-icloud-shim.sh.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The container `+[CKContainer defaultContainer]` stands for, from the app's Info.plist (read
/// from the file, see XSICloudInfo): the first of `XSideICloudContainers` (the containers its
/// original entitlements declared), else `iCloud.<XSideOriginalBundleID>`, else
/// `iCloud.<CFBundleIdentifier>`, else `iCloud.unknown`. Values of the wrong type are ignored.
NSString *XSICloudDefaultContainer(NSDictionary *info);

/// Whether XSide turned the option on at this signing: the Info.plist has `XSideICloudSignedOut`
/// = true (written only then). Without it the library installs nothing: an .ipa XSide signed
/// before may carry the library with the option off.
BOOL XSICloudIsEnabled(NSDictionary *info);

/// The NSUserDefaults suite backing the local key-value store `identifier` (nil: the default one).
NSString *XSICloudStoreSuite(NSString *_Nullable identifier);

NS_ASSUME_NONNULL_END
