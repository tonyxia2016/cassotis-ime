#import "CloudSync.h"
#import <CloudKit/CloudKit.h>
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <Security/Security.h>
#endif

#include "SyncStore.hpp"

#include <algorithm>
#include <memory>
#include <optional>

NSString *const CassotisCloudContainer = @"iCloud.com.hustmobile.cassotis";
NSString *const CassotisSyncZone = @"CassotisSync";

static const int64_t kSnapshotInterval = 7 * 86400;  // a replica's snapshot, weekly
static const int64_t kBatchKeep = 14 * 86400;        // own batches stay at least this long
static const int64_t kLiveWindow = 60 * 86400;       // replicas not seen for longer: gone
static const NSUInteger kChunkBytes = 512 * 1024;    // a record holds at most 1 MB
static const NSUInteger kOperationBytes = 1536 * 1024;

// --------------------------------------------------------------------------
// Errors in words for the settings.

static BOOL CassotisIsCKError(NSError *error, CKErrorCode code) {
    if (![error.domain isEqual:CKErrorDomain]) return NO;
    if (error.code == code) return YES;
    if (error.code == CKErrorPartialFailure) {
        NSDictionary *partial = error.userInfo[CKPartialErrorsByItemIDKey];
        for (id key in partial)
            if (CassotisIsCKError(partial[key], code)) return YES;
    }
    return NO;
}

/// Every partial error is this one (a record to delete that is already gone).
static BOOL CassotisOnlyCKError(NSError *error, CKErrorCode code) {
    if (![error.domain isEqual:CKErrorDomain]) return NO;
    if (error.code != CKErrorPartialFailure) return error.code == code;
    NSDictionary *partial = error.userInfo[CKPartialErrorsByItemIDKey];
    for (id key in partial)
        if (![partial[key] isKindOfClass:NSError.class] || [(NSError *)partial[key] code] != code) return NO;
    return partial.count > 0;
}

static NSString *CassotisSyncMessage(NSError *error) {
    if ([error.domain isEqual:CKErrorDomain]) {
        switch (error.code) {
        case CKErrorNotAuthenticated: return @"未登录 iCloud";
        case CKErrorNetworkUnavailable:
        case CKErrorNetworkFailure: return @"网络不可用，稍后再试";
        case CKErrorServiceUnavailable:
        case CKErrorRequestRateLimited:
        case CKErrorZoneBusy: return @"iCloud 繁忙，稍后再试";
        case CKErrorQuotaExceeded: return @"iCloud 储存空间已满";
        case CKErrorPermissionFailure:
        case CKErrorMissingEntitlement: return @"没有使用 iCloud 的权限";
        case CKErrorAccountTemporarilyUnavailable: return @"iCloud 暂时不可用";
        case CKErrorServerRejectedRequest: return @"iCloud 拒绝了请求（CKError 15）";
        case CKErrorPartialFailure: {
            NSDictionary *partial = error.userInfo[CKPartialErrorsByItemIDKey];
            for (id key in partial) return CassotisSyncMessage(partial[key]);
            break;
        }
        default: break;
        }
        return [NSString stringWithFormat:@"同步失败（CKError %ld）", (long)error.code];
    }
    if ([error.domain isEqual:NSURLErrorDomain]) return @"网络不可用，稍后再试";
    return [NSString stringWithFormat:@"同步失败（%@ %ld）", error.domain, (long)error.code];
}

/// An error with what CloudKit says inside it: partial errors per item, userInfo.
static NSString *CassotisErrorText(NSError *error) {
    if (!error) return @"ok";
    NSMutableString *text = [NSMutableString stringWithFormat:@"%@ %ld %@", error.domain,
        (long)error.code, error.localizedDescription];
    for (NSString *key in error.userInfo) {
        id value = error.userInfo[key];
        if ([key isEqual:CKPartialErrorsByItemIDKey]) {
            for (id item in (NSDictionary *)value)
                [text appendFormat:@" | item %@: %@", item, CassotisErrorText(((NSDictionary *)value)[item])];
        } else if ([key isEqual:NSUnderlyingErrorKey]) {
            [text appendFormat:@" | underlying: %@", CassotisErrorText(value)];
        } else if (![key isEqual:@"CKDHTTPHeaders"]) {
            [text appendFormat:@" | %@=%@", key, value];
        }
    }
    return text;
}

static NSString *CassotisAccountStatusName(CKAccountStatus status) {
    switch (status) {
    case CKAccountStatusAvailable: return @"available";
    case CKAccountStatusNoAccount: return @"no-account";
    case CKAccountStatusRestricted: return @"restricted";
    case CKAccountStatusTemporarilyUnavailable: return @"temporarily-unavailable";
    default: return @"could-not-determine";
    }
}

static void CassotisConfigure(CKOperation *operation) {
    operation.qualityOfService = NSQualityOfServiceUtility;
    CKOperationConfiguration *configuration = [[CKOperationConfiguration alloc] init];
    configuration.allowsCellularAccess = YES;
    configuration.timeoutIntervalForRequest = 30;
    configuration.timeoutIntervalForResource = 120;
    operation.configuration = configuration;
}

static NSString *ns(const std::string &text) {
    return [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding] ?: @"";
}

static std::string str(NSString *text) {
    return [text isKindOfClass:NSString.class] ? std::string(text.UTF8String ?: "") : std::string();
}

static std::string bytes(NSData *value) {
    return value ? std::string(static_cast<const char *>(value.bytes), value.length) : std::string();
}

static NSData *dataOf(const std::string &text) { return [NSData dataWithBytes:text.data() length:text.size()]; }

static int64_t seconds(id date) {
    return [date isKindOfClass:NSDate.class] ? int64_t([(NSDate *)date timeIntervalSince1970]) : 0;
}

#if TARGET_OS_OSX
/// An ad hoc build has no iCloud entitlement, and CloudKit throws when asked for a
/// container it is not entitled to.
static BOOL CassotisEntitled(void) {
    SecTaskRef task = SecTaskCreateFromSelf(NULL);
    if (!task) return NO;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task,
        CFSTR("com.apple.developer.icloud-container-identifiers"), NULL);
    CFRelease(task);
    BOOL entitled = value && CFGetTypeID(value) == CFArrayGetTypeID() &&
        [(__bridge NSArray *)value containsObject:CassotisCloudContainer];
    if (value) CFRelease(value);
    return entitled;
}
#else
static BOOL CassotisEntitled(void) { return ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CassotisCloudKitUnavailable"] boolValue]; }
#endif

static NSString *CassotisWhen(int64_t when) {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:when];
    NSDateFormatter *format = [[NSDateFormatter alloc] init];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    format.dateFormat = [NSCalendar.currentCalendar isDateInToday:date] ? @"今天 HH:mm" : @"M月d日 HH:mm";
    return [format stringFromDate:date];
}

// --------------------------------------------------------------------------

@interface CassotisSyncReport ()
@property(nonatomic, readwrite) BOOL ok;
@property(nonatomic) int64_t engineRevision;
@property(nonatomic, readwrite, copy) NSString *message;
@property(nonatomic, readwrite) BOOL learningChanged;
@property(nonatomic, readwrite) BOOL phrasesChanged;
@property(nonatomic, readwrite, copy) NSString *detail;
@end

@implementation CassotisSyncReport
@end

/// One run as it goes through its steps.
@interface CassotisSyncRun : NSObject
@property(nonatomic, copy) void (^completion)(CassotisSyncReport *);
@property(nonatomic) int64_t now;
@property(nonatomic) BOOL learningChanged, phrasesChanged, hadToken, rebased, snapshotSent;
@property(nonatomic) NSUInteger retries, records, batchesIn, opsIn, opsOut, batchesOut, cleaned;
@property(nonatomic) size_t bytesOut;
@end

@implementation CassotisSyncRun
@end

@implementation CassotisCloudSync {
    dispatch_queue_t _queue;
    std::unique_ptr<cassotis_sync::Store> _store;
    NSString *_path, *_device, *_platform, *_label, *_zoneName;
    CKContainer *_container;
    CKDatabase *_database;
    CKRecordZoneID *_zoneID;
    BOOL _running;
    CassotisSyncRun *_activeRun;
    CKOperation *_operation;
}

- (instancetype)initWithDatabasePath:(NSString *)path deviceToken:(NSString *)deviceToken
    platform:(NSString *)platform label:(NSString *)label zone:(NSString *)zone {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.hustmobile.cassotis.sync", DISPATCH_QUEUE_SERIAL);
        _preferences = NSUserDefaults.standardUserDefaults;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(accountChanged:)
            name:CKAccountChangedNotification object:nil];
        _path = [path copy];
        _device = [deviceToken copy];
        _platform = [platform copy];
        _label = [label copy];
        _zoneName = [zone copy];
        _zoneID = [[CKRecordZoneID alloc] initWithZoneName:zone ownerName:CKCurrentUserDefaultName];
    }
    return self;
}

// Everything below that touches the store runs on _queue.

- (BOOL)storeReady {
    if (_store && _store->isOpen()) return YES;
    if (![NSFileManager.defaultManager fileExistsAtPath:_path]) return NO;  // the engine creates it
    auto store = std::make_unique<cassotis_sync::Store>(str(_path));
    std::string error;
    if (!store->open(error)) {
        NSLog(@"cassotis sync: open: %s", error.c_str());
        return NO;
    }
    if (!_transportOnly && _device.length) store->adoptDevice(str(_device));
    _store = std::move(store);
    return YES;
}

- (BOOL)containerReady {
    if (_database) return YES;
    if (!CassotisEntitled()) return NO;
    @try {
        _container = [CKContainer containerWithIdentifier:CassotisCloudContainer];
        _database = _container.privateCloudDatabase;
    } @catch (NSException *exception) {
        NSLog(@"cassotis sync: no container: %@", exception.reason);
        _container = nil;
        _database = nil;
    }
    return _database != nil;
}

- (BOOL)isEnabled {
    return ![self.preferences boolForKey:@"CassotisCloudSyncDisabled"];
}

- (void)setEnabled:(BOOL)enabled {
    [self.preferences setBool:!enabled forKey:@"CassotisCloudSyncDisabled"];
    if (!enabled) [self cancel];
}

- (void)cancel {
    dispatch_async(_queue, ^{
        if (!self->_activeRun) return;
        [self->_operation cancel];
        [self finish:self->_activeRun ok:NO message:self.enabled ? @"同步已中断" : @"已关闭"];
    });
}

- (void)accountChanged:(NSNotification *)notification {
    (void)notification;
    [self cancel];
    dispatch_async(_queue, ^{
        if ([self storeReady]) self->_store->setNumber("last_attempt", 0);
    });
}

// Check on the serial queue before continuing an asynchronous CloudKit call.
// This also observes a switch turned off by the other iOS process.
- (BOOL)mayContinue:(CassotisSyncRun *)run {
    if (!run || _activeRun != run) return NO;
    if (self.enabled) return YES;
    [self finish:run ok:NO message:@"已关闭"];
    return NO;
}

- (NSString *)statusText {
    __block NSString *text = @"尚未同步";
    dispatch_sync(_queue, ^{
        if (![self storeReady]) return;
        if (!self.enabled) { text = @"已关闭"; return; }
        if (self->_running) { text = @"正在同步……"; return; }
        std::string error = self->_store->value("last_error");
        int64_t last = self->_store->number("last_sync", 0);
        if (!error.empty()) text = ns(error);
        else if (last > 0) text = [NSString stringWithFormat:@"已同步（%@）", CassotisWhen(last)];
    });
    return text;
}

// --------------------------------------------------------------------------
// One run: account, zone, others' changes in, own changes out, snapshot, cleaning.

- (void)syncWithCompletion:(void (^)(CassotisSyncReport *))completion {
    [self syncIfDue:0 completion:completion];
}

- (void)syncIfDue:(NSTimeInterval)interval completion:(void (^)(CassotisSyncReport *))completion {
    CassotisSyncRun *run = [[CassotisSyncRun alloc] init];
    run.completion = completion;
    run.now = int64_t(time(nullptr));
    dispatch_async(_queue, ^{
        if (self->_running || !self.enabled || ![self storeReady] ||
            (interval > 0 && difftime(run.now, self->_store->number("last_attempt")) >= 0 &&
             difftime(run.now, self->_store->number("last_attempt")) < interval)) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }
        self->_store->setNumber("last_attempt", run.now);
        if (![self containerReady]) {
            self->_store->setValue("last_error", "这个版本没有 iCloud 权限");
            [self report:run ok:NO message:@"这个版本没有 iCloud 权限"];
            return;
        }
        self->_running = YES;
        self->_activeRun = run;
        [self->_container accountStatusWithCompletionHandler:^(CKAccountStatus status, NSError *error) {
            dispatch_async(self->_queue, ^{
                if (![self mayContinue:run]) return;
                if (status != CKAccountStatusAvailable) {
                    NSString *message = status == CKAccountStatusNoAccount ? @"未登录 iCloud"
                        : status == CKAccountStatusRestricted ? @"iCloud 受到限制"
                        : error ? CassotisSyncMessage(error) : @"iCloud 暂时不可用";
                    [self finish:run ok:NO message:message];
                    return;
                }
                [self adoptAccount:run];
            });
        }];
    });
}

- (void)prepareRelayWithCompletion:(void (^)(CassotisSyncReport *))completion {
    dispatch_async(_queue, ^{
        NSString *path = self.relayPath;
        if (!self.enabled || !path || ![self storeReady]) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }
        CassotisSyncRun *run = [CassotisSyncRun new];
        run.completion = completion;
        run.now = time(nullptr);
        std::string error;
        cassotis_sync::CollectResult collected;
        cassotis_sync::ApplyResult applied;
        bool ok = self->_store->exchangeWithRelay(str(path), error) &&
            self->_store->applyReceived(run.now, applied, error) &&
            self->_store->collect(run.now, collected, error) &&
            self->_store->exchangeWithRelay(str(path), error);
        run.learningChanged = applied.learningChanged || applied.phrasesChanged;
        run.phrasesChanged = applied.phrasesChanged;
        [self report:run ok:ok message:ok ? @"已整理本机更改" : ns(error)];
    });
}

- (void)adoptAccount:(CassotisSyncRun *)run {
    [_container fetchUserRecordIDWithCompletionHandler:^(CKRecordID *recordID, NSError *error) {
        dispatch_async(self->_queue, ^{
            if (![self mayContinue:run]) return;
            if (!recordID || error) {
                [self fail:run error:error step:"account"];
                return;
            }
            if ((self->_transportOnly && self->_store->value("account").empty()) ||
                !self->_store->adoptAccount(str(recordID.recordName))) {
                [self finish:run ok:NO message:@"请切回此词库原先使用的 iCloud 账户"];
                return;
            }
            NSString *relay = self.relayPath;
            if (relay && !self->_transportOnly) {
                std::string failure;
                if (!self->_store->exchangeWithRelay(str(relay), failure))
                    NSLog(@"cassotis sync: background exchange: %s", failure.c_str());
            }
            [self ensureZone:run];
        });
    }];
}

- (void)ensureZone:(CassotisSyncRun *)run {
    if (_store->value("zone_ready") == "1") {
        [self fetchChanges:run];
        return;
    }
    CKRecordZone *zone = [[CKRecordZone alloc] initWithZoneID:_zoneID];
    CKModifyRecordZonesOperation *operation =
        [[CKModifyRecordZonesOperation alloc] initWithRecordZonesToSave:@[zone] recordZoneIDsToDelete:nil];
    CassotisConfigure(operation);
    operation.modifyRecordZonesCompletionBlock = ^(NSArray *saved, NSArray *deleted, NSError *error) {
        (void)saved; (void)deleted;
        dispatch_async(self->_queue, ^{
            if (![self mayContinue:run]) return;
            if (error) {
                [self fail:run error:error step:"zone"];
                return;
            }
            self->_store->setValue("zone_ready", "1");
            [self fetchChanges:run];
        });
    };
    _operation = operation;
    [_database addOperation:operation];
}

- (void)fetchChanges:(CassotisSyncRun *)run {
    CKServerChangeToken *token = nil;
    std::string archived = _store->value("token");
    if (!archived.empty())
        token = [NSKeyedUnarchiver unarchivedObjectOfClass:CKServerChangeToken.class fromData:dataOf(archived) error:nil];
    run.hadToken = token != nil;
    CKFetchRecordZoneChangesConfiguration *options = [[CKFetchRecordZoneChangesConfiguration alloc] init];
    options.previousServerChangeToken = token;
    options.resultsLimit = 24;
    // Everything but the snapshots' chunks, which only a rebase needs.
    options.desiredKeys = @[@"replica", @"seq", @"created", @"ops", @"platform", @"label", @"lastSeq", @"minSeq",
        @"lastSync", @"applied", @"generation", @"parts", @"index"];
    CKFetchRecordZoneChangesOperation *operation = [[CKFetchRecordZoneChangesOperation alloc]
        initWithRecordZoneIDs:@[_zoneID] configurationsByRecordZoneID:@{_zoneID: options}];
    CassotisConfigure(operation);
    operation.fetchAllChanges = NO;
    NSMutableArray<CKRecord *> *changed = [NSMutableArray array];
    NSMutableArray<CKRecordID *> *deleted = [NSMutableArray array];
    __block CKServerChangeToken *latest = nil;
    __block BOOL moreComing = NO;
    __block NSError *zoneError = nil;
    operation.recordWasChangedBlock = ^(CKRecordID *recordID, CKRecord *record, NSError *error) {
        (void)recordID;
        @synchronized (changed) {
            if (error) zoneError = error;
            else if (record) [changed addObject:record];
        }
    };
    operation.recordWithIDWasDeletedBlock = ^(CKRecordID *recordID, CKRecordType type) {
        (void)type;
        @synchronized (changed) { [deleted addObject:recordID]; }
    };
    operation.recordZoneChangeTokensUpdatedBlock = ^(CKRecordZoneID *zoneID, CKServerChangeToken *serverToken, NSData *client) {
        (void)zoneID; (void)client;
        @synchronized (changed) { latest = serverToken; }
    };
    operation.recordZoneFetchCompletionBlock = ^(CKRecordZoneID *zoneID, CKServerChangeToken *serverToken,
        NSData *client, BOOL more, NSError *error) {
        (void)zoneID; (void)client; (void)more;
        @synchronized (changed) {
            moreComing = more;
            if (serverToken) latest = serverToken;
            if (error) zoneError = error;
        }
    };
    operation.fetchRecordZoneChangesCompletionBlock = ^(NSError *error) {
        dispatch_async(self->_queue, ^{
            if (![self mayContinue:run]) return;
            NSError *failure = zoneError ?: error;
            if (failure && CassotisIsCKError(failure, CKErrorChangeTokenExpired) && run.retries < 2) {
                run.retries++;
                self->_store->setValue("token", "");
                [self fetchChanges:run];
                return;
            }
            if (failure && (CassotisIsCKError(failure, CKErrorZoneNotFound) ||
                    CassotisIsCKError(failure, CKErrorUserDeletedZone)) && run.retries < 2) {
                // The zone is gone (or never was): make it. If it held this
                // replica's batches before, they go up again, with a snapshot of
                // everything merged here for the replicas that start over.
                run.retries++;
                self->_store->setValue("zone_ready", "0");
                if (run.hadToken) {
                    self->_store->markAllUnuploaded();
                    self->_store->setValue("snapshot_due", "1");
                }
                self->_store->setValue("token", "");
                [self ensureZone:run];
                return;
            }
            if (failure) {
                [self fail:run error:failure step:"fetch"];
                return;
            }
            if (![self take:changed deleted:deleted run:run]) {
                [self finish:run ok:NO message:@"下载的更改尚未存好，下次重试"];
                return;
            }
            if (latest) {
                NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:latest requiringSecureCoding:YES error:nil];
                if (!archive || !self->_store->setValue("token", bytes(archive))) {
                    [self finish:run ok:NO message:@"同步进度尚未保存"];
                    return;
                }
            }
            if (moreComing && !latest) { [self finish:run ok:NO message:@"云端未返回下一页游标"]; return; }
            if (moreComing) [self fetchChanges:run];
            else if (self->_transportOnly) [self upload:run];
            else [self applyChanges:run];
        });
    };
    _operation = operation;
    [_database addOperation:operation];
}

- (BOOL)take:(NSArray<CKRecord *> *)changed deleted:(NSArray<CKRecordID *> *)deleted run:(CassotisSyncRun *)run {
    const std::string self_id = _store->replica();
    for (CKRecord *record in changed) {
        run.records++;
        std::string replica = str(record[@"replica"]);
        if (replica.empty()) {
            if ([record.recordType isEqual:@"Batch"]) return NO;
            continue;
        }
        if ([record.recordType isEqual:@"Batch"]) {
            NSNumber *seq = record[@"seq"];
            NSData *ops = record.encryptedValues[@"ops"];
            if (replica != self_id && (![seq isKindOfClass:NSNumber.class] || ![ops isKindOfClass:NSData.class] ||
                !_store->receive(replica, seq.longLongValue, seconds(record[@"created"]), bytes(ops)))) return NO;
        } else if ([record.recordType isEqual:@"Replica"]) {
            cassotis_sync::ReplicaInfo info;
            info.replica = replica;
            info.platform = str(record[@"platform"]);
            info.label = str(record[@"label"]);
            info.lastSeq = [record[@"lastSeq"] longLongValue];
            info.minSeq = [record[@"minSeq"] longLongValue];
            info.lastSync = seconds(record[@"lastSync"]);
            info.applied = cassotis_sync::parseApplied(str(record[@"applied"]));
            if (!_store->noteReplica(info)) return NO;
        } else if ([record.recordType isEqual:@"Snapshot"] && [record[@"index"] longLongValue] == 0) {
            cassotis_sync::SnapshotInfo info;
            info.replica = replica;
            info.generation = [record[@"generation"] longLongValue];
            info.parts = [record[@"parts"] longLongValue];
            info.created = seconds(record[@"created"]);
            info.applied = cassotis_sync::parseApplied(str(record[@"applied"]));
            if (!_store->noteSnapshot(info)) return NO;
        }
    }
    for (CKRecordID *recordID in deleted) {
        NSString *name = recordID.recordName;
        if ([name hasPrefix:@"r-"] && !_store->forgetReplica(str([name substringFromIndex:2]))) return NO;
        else if ([name hasPrefix:@"s-"] && [name hasSuffix:@"-0"] && name.length > 4)
            if (!_store->forgetSnapshot(str([name substringWithRange:NSMakeRange(2, name.length - 4)]))) return NO;
    }
    return YES;
}

- (void)applyChanges:(CassotisSyncRun *)run {
    cassotis_sync::ApplyResult result;
    std::string error;
    bool success = _store->applyReceived(run.now, result, error);
    run.learningChanged |= result.learningChanged || result.phrasesChanged;
    run.phrasesChanged |= result.phrasesChanged;
    if (!success) {
        [self finish:run ok:NO message:[@"同步失败：" stringByAppendingString:ns(error)]];
        return;
    }
    run.batchesIn += result.batches;
    run.opsIn += result.ops;
    run.learningChanged = run.learningChanged || result.learningChanged;
    run.phrasesChanged = run.phrasesChanged || result.phrasesChanged;
    // After cleanup a replica can have *zero* surviving batches. Its manifest
    // still advertises its high-water mark; inspecting inbox gaps alone loses it.
    auto applied = _store->applied();
    for (const auto &peer : _store->replicas()) {
        if (peer.replica != _store->replica() && applied[peer.replica] < peer.lastSeq)
            result.waiting[peer.replica] = applied[peer.replica] + 1;
    }
    if (!result.waiting.empty()) {
        if (run.rebased) [self finish:run ok:NO message:@"正在等待完整的同步记录"];
        else [self rebase:run];
        return;
    }
    [self upload:run];
}

- (void)rebase:(CassotisSyncRun *)run {
    run.rebased = YES;
    const std::string self_id = _store->replica();
    auto others = _store->replicas();
    std::optional<cassotis_sync::SnapshotInfo> best;
    for (const auto &snapshot : _store->snapshots()) {
        bool usable = snapshot.parts > 0;
        auto mine = snapshot.applied.find(self_id);
        if ((mine == snapshot.applied.end() ? 0 : mine->second) < _store->firstOwnSeq() - 1) usable = false;
        for (const auto &other : others) {
            if (other.replica == self_id) continue;
            auto held = snapshot.applied.find(other.replica);
            if ((held == snapshot.applied.end() ? 0 : held->second) < other.minSeq - 1) usable = false;
        }
        if (usable && (!best || snapshot.created > best->created)) best = snapshot;
    }
    if (!best) {
        NSLog(@"cassotis sync: batches missing and no snapshot holds them yet");
        _store->setValue("token", "");
        [self finish:run ok:NO message:@"正在等待其他设备的完整同步记录"];
        return;
    }
    NSMutableArray<CKRecordID *> *ids = [NSMutableArray array];
    for (int64_t part = 0; part < best->parts; ++part)
        [ids addObject:[[CKRecordID alloc] initWithRecordName:[NSString stringWithFormat:@"s-%@-%lld",
            ns(best->replica), part] zoneID:_zoneID]];
    CKFetchRecordsOperation *operation = [[CKFetchRecordsOperation alloc] initWithRecordIDs:ids];
    CassotisConfigure(operation);
    operation.fetchRecordsCompletionBlock = ^(NSDictionary<CKRecordID *, CKRecord *> *records, NSError *error) {
        dispatch_async(self->_queue, ^{
            if (![self mayContinue:run]) return;
            std::string payload;
            int64_t generation = -1;
            bool complete = records.count == ids.count;
            for (CKRecordID *recordID in ids) {
                CKRecord *record = records[recordID];
                NSData *chunk = record.encryptedValues[@"chunk"];
                int64_t partGeneration = [record[@"generation"] longLongValue];
                if (!record || !chunk || (generation >= 0 && partGeneration != generation)) { complete = false; break; }
                generation = partGeneration;
                payload += bytes(chunk);
            }
            if (!complete || generation != best->generation) {
                // Being replaced right now, or gone: the next sync tries again.
                NSLog(@"cassotis sync: snapshot incomplete (%@)", CassotisErrorText(error));
                [self finish:run ok:NO message:@"快照尚未完整下载"];
                return;
            }
            cassotis_sync::CollectResult collected;
            cassotis_sync::ApplyResult imported;
            std::string failure;
            // What this replica has not sent yet goes into its outbox first; the
            // snapshot then comes in under it.
            if (!self->_store->collect(run.now, collected, failure) ||
                !self->_store->importSnapshot(payload, imported, failure)) {
                [self finish:run ok:NO message:[@"同步失败：" stringByAppendingString:ns(failure)]];
                return;
            }
            run.learningChanged = YES;
            run.phrasesChanged = run.phrasesChanged || imported.phrasesChanged;
            run.opsIn += imported.ops;
            [self fetchChanges:run];
        });
    };
    _operation = operation;
    [_database addOperation:operation];
}

/// Saves records (and deletes ids, with the last group) in operations of a bounded
/// size, one after another.
- (void)save:(NSArray<CKRecord *> *)records delete:(NSArray<CKRecordID *> *)deletions
    sizes:(NSArray<NSNumber *> *)sizes saved:(void (^)(NSArray<CKRecord *> *group))saved
    done:(void (^)(NSError *error))done {
    CassotisSyncRun *run = _activeRun;
    if (![self mayContinue:run]) return;
    NSMutableArray<CKRecord *> *group = [NSMutableArray array];
    NSUInteger index = 0, total = 0;
    while (index < records.count && (group.count == 0 ||
               (total + sizes[index].unsignedIntegerValue <= kOperationBytes && group.count < 200))) {
        total += sizes[index].unsignedIntegerValue;
        [group addObject:records[index++]];
    }
    NSUInteger deleteCount = group.count == 0 ? MIN(deletions.count, 200U) : 0;
    NSArray *batchDeletes = [deletions subarrayWithRange:NSMakeRange(0, deleteCount)];
    NSArray *remainingDeletes = [deletions subarrayWithRange:NSMakeRange(deleteCount, deletions.count - deleteCount)];
    NSArray<CKRecord *> *rest = [records subarrayWithRange:NSMakeRange(index, records.count - index)];
    NSArray<NSNumber *> *restSizes = [sizes subarrayWithRange:NSMakeRange(index, sizes.count - index)];
    CKModifyRecordsOperation *operation = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:group
        recordIDsToDelete:batchDeletes];
    operation.savePolicy = CKRecordSaveAllKeys;
    operation.atomic = NO;
    CassotisConfigure(operation);
    operation.modifyRecordsCompletionBlock = ^(NSArray *savedRecords, NSArray *deletedIDs, NSError *error) {
        (void)savedRecords; (void)deletedIDs;
        dispatch_async(self->_queue, ^{
            if (![self mayContinue:run]) return;
            if (error && (group.count || !CassotisOnlyCKError(error, CKErrorUnknownItem))) {
                done(error);
                return;
            }
            if (group.count) saved(group);
            if (rest.count == 0 && remainingDeletes.count == 0) {
                done(nil);
                return;
            }
            [self save:rest delete:remainingDeletes sizes:restSizes saved:saved done:done];
        });
    };
    _operation = operation;
    [_database addOperation:operation];
}

- (void)upload:(CassotisSyncRun *)run {
    cassotis_sync::CollectResult collected;
    std::string error;
    if (!_transportOnly && !_store->collect(run.now, collected, error)) {
        [self finish:run ok:NO message:[@"同步失败：" stringByAppendingString:ns(error)]];
        return;
    }
    run.opsOut += collected.ops;
    const std::string self_id = _store->replica();
    NSString *me = ns(self_id);
    NSMutableArray<CKRecord *> *records = [NSMutableArray array];
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray array];
    int64_t minSeq = _store->firstOwnSeq();
    auto pending = _store->outbox(true);
    for (auto &batch : _store->forwarded()) pending.push_back(std::move(batch));
    for (const auto &batch : pending) {
        NSString *origin = batch.origin.empty() ? me : ns(batch.origin);
        CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:[NSString stringWithFormat:@"b-%@-%lld", origin,
            batch.seq] zoneID:_zoneID];
        CKRecord *record = [[CKRecord alloc] initWithRecordType:@"Batch" recordID:recordID];
        record[@"replica"] = origin;
        record[@"seq"] = @(batch.seq);
        record[@"created"] = [NSDate dateWithTimeIntervalSince1970:double(batch.created)];
        record.encryptedValues[@"ops"] = dataOf(batch.payload);
        [records addObject:record];
        [sizes addObject:@(batch.payload.size())];
        run.batchesOut++;
        run.bytesOut += batch.payload.size();
    }
    // What this replica has sent and taken in, for the others' cleaning up.
    CKRecord *replica = [[CKRecord alloc] initWithRecordType:@"Replica"
        recordID:[[CKRecordID alloc] initWithRecordName:[@"r-" stringByAppendingString:me] zoneID:_zoneID]];
    replica[@"replica"] = me;
    replica[@"platform"] = _platform;
    replica[@"label"] = _label;
    replica[@"lastSeq"] = @(_store->lastOwnSeq());
    replica[@"minSeq"] = @(minSeq);
    replica[@"lastSync"] = [NSDate dateWithTimeIntervalSince1970:double(run.now)];
    replica[@"applied"] = ns(cassotis_sync::formatApplied(_store->applied()));
    if (!_transportOnly) {
        [records addObject:replica];
        [sizes addObject:@1024];
    }
    if (records.count == 0) { [self finish:run ok:YES message:nil]; return; }
    [self save:records delete:@[] sizes:sizes saved:^(NSArray<CKRecord *> *group) {
        for (CKRecord *record in group) {
            if (![record.recordType isEqual:@"Batch"]) continue;
            auto seq = [record[@"seq"] longLongValue];
            if ([record[@"replica"] isEqual:me]) self->_store->markUploaded(seq);
            else self->_store->markForwarded(str(record[@"replica"]), seq);
        }
    } done:^(NSError *saveError) {
        if (saveError) {
            [self fail:run error:saveError step:"upload"];
            return;
        }
        if (self->_transportOnly) [self finish:run ok:YES message:nil];
        else [self snapshot:run];
    }];
}

- (void)snapshot:(CassotisSyncRun *)run {
    bool due = _store->value("snapshot_due") == "1" ||
        run.now - _store->number("last_snapshot", 0) >= kSnapshotInterval;
    bool synced = _store->lastOwnSeq() > 0 || !_store->applied().empty();
    if (!due || !synced || _store->number("cleared_at") || !_store->outbox(true).empty()) {
        [self clean:run];
        return;
    }
    std::string payload, error;
    if (!_store->exportSnapshot(run.now, payload, error)) {
        NSLog(@"cassotis sync: snapshot: %s", error.c_str());
        [self clean:run];
        return;
    }
    const std::string self_id = _store->replica();
    NSString *me = ns(self_id);
    auto applied = _store->applied();
    applied[self_id] = _store->lastOwnSeq();
    NSString *appliedText = ns(cassotis_sync::formatApplied(applied));
    int64_t generation = _store->number("snapshot_gen", 0) + 1;
    int64_t parts = int64_t((payload.size() + kChunkBytes - 1) / kChunkBytes);
    int64_t previous = _store->number("snapshot_parts", 0);
    NSMutableArray<CKRecord *> *records = [NSMutableArray array];
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray array];
    for (int64_t part = 0; part < parts; ++part) {
        size_t start = size_t(part) * kChunkBytes;
        std::string chunk = payload.substr(start, std::min<size_t>(kChunkBytes, payload.size() - start));
        CKRecord *record = [[CKRecord alloc] initWithRecordType:@"Snapshot" recordID:[[CKRecordID alloc]
            initWithRecordName:[NSString stringWithFormat:@"s-%@-%lld", me, part] zoneID:_zoneID]];
        record[@"replica"] = me;
        record[@"generation"] = @(generation);
        record[@"parts"] = @(parts);
        record[@"index"] = @(part);
        record[@"created"] = [NSDate dateWithTimeIntervalSince1970:double(run.now)];
        record[@"applied"] = appliedText;
        record.encryptedValues[@"chunk"] = dataOf(chunk);
        [records addObject:record];
        [sizes addObject:@(chunk.size())];
    }
    NSMutableArray<CKRecordID *> *stale = [NSMutableArray array];
    for (int64_t part = parts; part < previous; ++part)
        [stale addObject:[[CKRecordID alloc] initWithRecordName:[NSString stringWithFormat:@"s-%@-%lld", me, part]
            zoneID:_zoneID]];
    [self save:records delete:stale sizes:sizes saved:^(NSArray<CKRecord *> *group) { (void)group; }
        done:^(NSError *saveError) {
        if (saveError) {
            NSLog(@"cassotis sync: snapshot upload: %@", CassotisErrorText(saveError));
            [self clean:run];
            return;
        }
        self->_store->setNumber("last_snapshot", run.now);
        self->_store->setNumber("snapshot_gen", generation);
        self->_store->setNumber("snapshot_parts", parts);
        self->_store->setValue("snapshot_due", "0");
        cassotis_sync::SnapshotInfo info;
        info.replica = self_id;
        info.generation = generation;
        info.parts = parts;
        info.created = run.now;
        info.applied = applied;
        self->_store->noteSnapshot(info);
        run.snapshotSent = YES;
        [self clean:run];
    }];
}

- (void)clean:(CassotisSyncRun *)run {
    int64_t safe = _store->ownSeqSafeToDelete(run.now, kLiveWindow, run.now - kBatchKeep);
    if (safe <= 0) {
        [self finish:run ok:YES message:nil];
        return;
    }
    NSString *me = ns(_store->replica());
    NSMutableArray<CKRecordID *> *ids = [NSMutableArray array];
    for (const auto &batch : _store->outbox(false))
        if (batch.uploaded && batch.seq <= safe)
            [ids addObject:[[CKRecordID alloc] initWithRecordName:[NSString stringWithFormat:@"b-%@-%lld", me,
                batch.seq] zoneID:_zoneID]];
    [self save:@[] delete:ids sizes:@[] saved:^(NSArray<CKRecord *> *group) { (void)group; }
        done:^(NSError *error) {
        if (!error) {
            self->_store->dropOutbox(safe);
            run.cleaned = ids.count;
        } else {
            NSLog(@"cassotis sync: cleaning: %@", CassotisErrorText(error));
        }
        [self finish:run ok:YES message:nil];
    }];
}

- (void)fail:(CassotisSyncRun *)run error:(NSError *)error step:(const char *)step {
    NSLog(@"cassotis sync: %s: %@", step, CassotisErrorText(error));
    [self finish:run ok:NO message:CassotisSyncMessage(error)];
}

- (void)finish:(CassotisSyncRun *)run ok:(BOOL)ok message:(NSString *)message {
    _running = NO;
    _activeRun = nil;
    _operation = nil;
    if (ok) {
        _store->setNumber("last_sync", run.now);
        _store->setValue("last_error", "");
        message = [NSString stringWithFormat:@"已同步（%@）", CassotisWhen(run.now)];
    } else {
        _store->setValue("last_error", str(message));
    }
    [self report:run ok:ok message:message];
}

- (void)acknowledgeRefresh:(CassotisSyncReport *)report {
    dispatch_async(_queue, ^{
        if (self->_store && report.engineRevision > self->_store->number("engine_refreshed"))
            self->_store->setNumber("engine_refreshed", report.engineRevision);
    });
}

- (void)report:(CassotisSyncRun *)run ok:(BOOL)ok message:(NSString *)message {
    CassotisSyncReport *report = [[CassotisSyncReport alloc] init];
    report.ok = ok;
    report.message = message ?: @"";
    report.engineRevision = _store && !_transportOnly ? _store->number("engine_revision") : 0;
    report.learningChanged = run.learningChanged || (report.engineRevision > 0 &&
        report.engineRevision > _store->number("engine_refreshed"));
    report.phrasesChanged = run.phrasesChanged;
    report.detail = [NSString stringWithFormat:@"records=%lu in=%lu batches/%lu ops out=%lu batches/%lu ops/%zu bytes "
        "rebased=%d snapshot=%d cleaned=%lu", (unsigned long)run.records, (unsigned long)run.batchesIn,
        (unsigned long)run.opsIn, (unsigned long)run.batchesOut, (unsigned long)run.opsOut, run.bytesOut,
        run.rebased, run.snapshotSent, (unsigned long)run.cleaned];
    NSLog(@"cassotis sync: %@ %@", report.message, report.detail);
    void (^completion)(CassotisSyncReport *) = run.completion;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(report); });
}

// --------------------------------------------------------------------------

+ (void)probeWithCompletion:(void (^)(NSString *report, BOOL succeeded))completion {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    void (^note)(NSString *) = ^(NSString *line) {
        NSString *entry = [NSString stringWithFormat:@"%6.0f ms %@",
            (CFAbsoluteTimeGetCurrent() - started) * 1000, line];
        NSLog(@"cassotis sync probe: %@", entry);  // as it happens: a step may never end
        @synchronized (lines) { [lines addObject:entry]; }
    };
    void (^finish)(BOOL) = ^(BOOL succeeded) {
        NSString *report;
        @synchronized (lines) { report = [lines componentsJoinedByString:@"\n"]; }
        completion(report, succeeded);
    };
    if (!CassotisEntitled()) {
        note(@"no iCloud entitlement in this build");
        finish(NO);
        return;
    }
    // A diagnostic can only delete a zone it created for this invocation.
    NSString *zoneName = [@"CassotisProbe-" stringByAppendingString:NSUUID.UUID.UUIDString];
    CKContainer *container;
    @try { container = [CKContainer containerWithIdentifier:CassotisCloudContainer]; }
    @catch (NSException *exception) { note(@"iCloud container unavailable"); finish(NO); return; }
    CKDatabase *database = container.privateCloudDatabase;
    CKRecordZone *zone = [[CKRecordZone alloc] initWithZoneName:zoneName];
    note([NSString stringWithFormat:@"container %@ zone %@", CassotisCloudContainer, zoneName]);
    [container accountStatusWithCompletionHandler:^(CKAccountStatus status, NSError *error) {
        note([NSString stringWithFormat:@"account %@%@", CassotisAccountStatusName(status),
            error ? [@" error " stringByAppendingString:CassotisErrorText(error)] : @""]);
        if (status != CKAccountStatusAvailable) { finish(NO); return; }
        CKModifyRecordZonesOperation *makeZone =
            [[CKModifyRecordZonesOperation alloc] initWithRecordZonesToSave:@[zone] recordZoneIDsToDelete:nil];
        CassotisConfigure(makeZone);
        makeZone.modifyRecordZonesCompletionBlock = ^(NSArray *savedZones, NSArray *deletedZones, NSError *zoneError) {
            (void)savedZones; (void)deletedZones;
            note([NSString stringWithFormat:@"zone %@", CassotisErrorText(zoneError)]);
            if (zoneError) { finish(NO); return; }
            void (^cleanUp)(BOOL) = ^(BOOL passed) {
                CKModifyRecordZonesOperation *drop = [[CKModifyRecordZonesOperation alloc]
                    initWithRecordZonesToSave:nil recordZoneIDsToDelete:@[zone.zoneID]];
                CassotisConfigure(drop);
                drop.modifyRecordZonesCompletionBlock = ^(NSArray *saved, NSArray *deleted, NSError *error) {
                    (void)saved; (void)deleted;
                    note([NSString stringWithFormat:@"zone delete %@", CassotisErrorText(error)]);
                    finish(passed && !error);
                };
                [database addOperation:drop];
            };
            CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:@"b-probe-1" zoneID:zone.zoneID];
            CKRecord *record = [[CKRecord alloc] initWithRecordType:@"Batch" recordID:recordID];
            NSData *payload = dataOf(cassotis_sync::compressText("cassotis diagnostic"));
            record[@"replica"] = @"probe";
            record[@"seq"] = @1;
            record[@"created"] = NSDate.date;
            record.encryptedValues[@"ops"] = payload;
            CKModifyRecordsOperation *save =
                [[CKModifyRecordsOperation alloc] initWithRecordsToSave:@[record] recordIDsToDelete:nil];
            save.savePolicy = CKRecordSaveAllKeys;
            CassotisConfigure(save);
            save.modifyRecordsCompletionBlock = ^(NSArray *savedRecords, NSArray *deletedRecords, NSError *saveError) {
                (void)savedRecords; (void)deletedRecords;
                note([NSString stringWithFormat:@"record %@", CassotisErrorText(saveError)]);
                if (saveError) { cleanUp(NO); return; }
                CKFetchRecordZoneChangesConfiguration *options = [[CKFetchRecordZoneChangesConfiguration alloc] init];
                CKFetchRecordZoneChangesOperation *fetch = [[CKFetchRecordZoneChangesOperation alloc]
                    initWithRecordZoneIDs:@[zone.zoneID] configurationsByRecordZoneID:@{zone.zoneID: options}];
                CassotisConfigure(fetch);
                __block NSUInteger matched = 0, seen = 0;
                fetch.recordWasChangedBlock = ^(CKRecordID *changedID, CKRecord *changed, NSError *recordError) {
                    (void)changedID;
                    seen++;
                    NSData *value = changed.encryptedValues[@"ops"];
                    if (!recordError && [value isEqual:payload]) matched++;
                };
                fetch.fetchRecordZoneChangesCompletionBlock = ^(NSError *fetchError) {
                    note([NSString stringWithFormat:@"fetch %@ records=%lu encrypted_match=%lu",
                        CassotisErrorText(fetchError), (unsigned long)seen, (unsigned long)matched]);
                    cleanUp(!fetchError && matched == 1);
                };
                [database addOperation:fetch];
            };
            [database addOperation:save];
        };
        [database addOperation:makeZone];
    }];
}

@end
