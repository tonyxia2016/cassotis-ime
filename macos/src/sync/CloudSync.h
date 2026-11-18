// iCloud (CloudKit) sync of the user dictionary: learning and custom phrases.
// Shared by the macOS input method and the iOS keyboard. SyncStore.cpp decides what
// changed and how others' changes merge; this moves the batches through the user's
// private CloudKit database:
//   b-<replica>-<seq>   one batch of a replica's changes, compressed, in an encrypted field
//   r-<replica>         what a replica has sent and applied, for cleaning up
//   s-<replica>-<part>  a replica's synced state, weekly: where a new replica starts
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The CloudKit container of the input method and the keyboard.
extern NSString *const CassotisCloudContainer;
/// The zone everything lives in; tests use their own.
extern NSString *const CassotisSyncZone;

/// What one sync did.
@interface CassotisSyncReport : NSObject
@property(nonatomic, readonly) BOOL ok;
/// One line for the settings: "已同步", "未登录 iCloud", …
@property(nonatomic, readonly, copy) NSString *message;
/// Other devices' learning came in: the engine has to reread the user dictionary.
@property(nonatomic, readonly) BOOL learningChanged;
/// The stored phrase list changed in this run.
@property(nonatomic, readonly) BOOL phrasesChanged;
/// Counts, for logs and tests (no user data).
@property(nonatomic, readonly, copy) NSString *detail;
@end

@interface CassotisCloudSync : NSObject
/// path: user_dict.db, which the engine creates. deviceToken identifies this device;
/// only a hash of it is kept, and it never leaves the device. platform and label
/// name the replica in the cloud ("macOS", "Mac").
- (instancetype)initWithDatabasePath:(NSString *)path deviceToken:(NSString *)deviceToken
    platform:(NSString *)platform label:(NSString *)label zone:(NSString *)zone NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// The host uses the App Group queue when the keyboard is suspended.
@property(atomic, copy, nullable) NSString *relayPath;
@property(nonatomic) BOOL transportOnly;
@property(atomic, strong) NSUserDefaults *preferences;
/// Per-device preference, available before the engine creates its dictionary.
@property(nonatomic, getter=isEnabled) BOOL enabled;
/// For the settings: "已同步（今天 14:20）", "已关闭", or what went wrong.
@property(nonatomic, readonly, copy) NSString *statusText;
/// One sync: others' changes in, then this replica's out. completion runs on the
/// main queue. A sync already running reports itself and does nothing.
- (void)syncWithCompletion:(nullable void (^)(CassotisSyncReport *report))completion;
/// Atomically check the interval and start on the store queue. Returns nil to the
/// completion if another run is active, disabled, or too recent.
- (void)syncIfDue:(NSTimeInterval)interval completion:(nullable void (^)(CassotisSyncReport *_Nullable report))completion;
/// Confirm that the engine has reloaded the committed rows from this report.
- (void)acknowledgeRefresh:(CassotisSyncReport *)report;
/// Cancel a run when the system expires a background task.
- (void)cancel;
/// Stage local changes for background delivery and consume any downloaded batches.
- (void)prepareRelayWithCompletion:(nullable void (^)(CassotisSyncReport *_Nullable report))completion;
/// One round trip to the container, for checking signing and entitlements: the
/// account, a zone, a record with an encrypted field written and read back through
/// zone changes, the zone deleted again. Reports each step as a line.
+ (void)probeWithCompletion:(void (^)(NSString *report, BOOL succeeded))completion;
@end

NS_ASSUME_NONNULL_END
