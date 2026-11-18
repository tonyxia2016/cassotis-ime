// iCloud sync in the input method: a sync shortly after launch, then hourly and after
// waking; what came in reaches the engine. See src/sync/CloudSync.h.
#import <Foundation/Foundation.h>
#import "CloudSync.h"

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue after each sync (object: the CassotisSyncReport).
extern NSNotificationName const CassotisSyncDidFinishNotification;

@interface CassotisSyncController : NSObject
@property(class, nonatomic, readonly) CassotisSyncController *shared;
@property(nonatomic, readonly) CassotisCloudSync *sync;
- (void)start;
/// Now, whatever the time since the last one (the settings' button).
- (void)syncNow;
@end

/// The user dictionary the engine keeps.
NSString *CassotisUserDictionaryPath(void);
/// Identifies this Mac for the sync (only a hash is kept, on this Mac).
NSString *CassotisDeviceToken(void);

NS_ASSUME_NONNULL_END
