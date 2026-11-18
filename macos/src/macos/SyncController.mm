#import "SyncController.h"
#import <AppKit/AppKit.h>
#import "InputSession.h"
#include "EngineClient.hpp"
#include <unistd.h>
#include <uuid/uuid.h>

NSNotificationName const CassotisSyncDidFinishNotification = @"CassotisSyncDidFinishNotification";

static const NSTimeInterval kInterval = 3600;   // the user asked for hourly
static const NSTimeInterval kFirstDelay = 120;  // after launch: the engine first
static const NSTimeInterval kCheckEvery = 300;

NSString *CassotisUserDictionaryPath(void) {
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    if ([env[@"CASSOTIS_USER_DICTIONARY"] length]) return env[@"CASSOTIS_USER_DICTIONARY"];
    NSString *directory = env[@"CASSOTIS_DATA_DIRECTORY"];
    if (!directory.length) directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/CassotisIME"];
    return [directory stringByAppendingPathComponent:@"user_dict.db"];
}

NSString *CassotisDeviceToken(void) {
    uuid_t identifier;
    struct timespec wait = {1, 0};
    if (gethostuuid(identifier, &wait) != 0) return @"";
    uuid_string_t text;
    uuid_unparse_upper(identifier, text);
    return [NSString stringWithUTF8String:text];
}

@implementation CassotisSyncController {
    NSTimer *_timer;
    dispatch_queue_t _engineQueue;  // engine calls for the sync, off the main thread
}

+ (CassotisSyncController *)shared {
    static CassotisSyncController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[CassotisSyncController alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sync = [[CassotisCloudSync alloc] initWithDatabasePath:CassotisUserDictionaryPath()
            deviceToken:CassotisDeviceToken() platform:@"macOS" label:@"Mac" zone:CassotisSyncZone];
        _engineQueue = dispatch_queue_create("com.hustmobile.cassotis.sync-engine", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)start {
    if (_timer) return;
    __weak CassotisSyncController *weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(kFirstDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weak syncIfDue];
    });
    _timer = [NSTimer scheduledTimerWithTimeInterval:kCheckEvery repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weak syncIfDue];
    }];
    _timer.tolerance = 60;
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(woke:)
        name:NSWorkspaceDidWakeNotification object:nil];
}

- (void)woke:(NSNotification *)notification {
    (void)notification;
    // The network needs a moment after waking.
    __weak CassotisSyncController *weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weak syncIfDue];
    });
}

- (void)syncIfDue {
    [_sync syncIfDue:kInterval completion:^(CassotisSyncReport *report) { if (report) [self finished:report]; }];
}

- (void)syncNow {
    __weak CassotisSyncController *weak = self;
    [_sync syncWithCompletion:^(CassotisSyncReport *report) {
        if (report) [weak finished:report];
    }];
}

- (void)finished:(CassotisSyncReport *)report {
    dispatch_async(_engineQueue, ^{
        if (report.learningChanged) {
            try {
                cassotis::EngineClient engine;
                if (engine.connect(CassotisSocketPath().UTF8String)) {
                    engine.userDataChanged();
                    [self.sync acknowledgeRefresh:report];
                }
            } catch (const std::exception &e) {
                NSLog(@"cassotis sync: engine: %s", e.what());
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:CassotisSyncDidFinishNotification object:report];
        });
    });
}

@end
