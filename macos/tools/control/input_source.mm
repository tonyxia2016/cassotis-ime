#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>
#import <AppKit/AppKit.h>
#include "SyncStore.hpp"
#include <libproc.h>
#include <signal.h>
#include <iostream>
#include <vector>

// The input method's id. Builds before 2026-11 used the upstream project's id;
// updating from one must still switch away from it and stop it.
static NSString *const CassotisBundleID=@"com.hustmobile.inputmethod.Cassotis";
static NSString *const CassotisLegacyBundleID=@"org.cassotis.inputmethod.Cassotis";

static NSArray<NSString *> *installedPaths(void) {
    NSString *directory=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Input Methods"];
    return @[[directory stringByAppendingPathComponent:@"CassotisIME.app"],
             [directory stringByAppendingPathComponent:@"Cassotis.app"]];
}

int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc<2) return 2;
        NSString *command=[NSString stringWithUTF8String:argv[1]];
        if([command isEqual:@"backup-dictionary"] || [command isEqual:@"import-dictionary"]) {
            if(argc!=4) return 2;
            std::string error;
            bool ok=[command isEqual:@"backup-dictionary"]
                ? cassotis_sync::backupDictionary(argv[2],argv[3],error)
                : cassotis_sync::importLegacyDictionary(argv[2],argv[3],CassotisLegacyBundleID.UTF8String,error);
            if(!ok) std::cerr<<error<<std::endl;
            return ok?0:1;
        }
        if([command isEqual:@"current"]) {
            TISInputSourceRef current=TISCopyCurrentKeyboardInputSource();
            NSString *identifier=(__bridge NSString *)TISGetInputSourceProperty(current,kTISPropertyInputSourceID);
            std::cout<<(identifier.UTF8String?:"")<<std::endl;CFRelease(current);return 0;
        }
        if([command isEqual:@"launch"]) {
            if(argc!=2) return 2;
            NSURL *url=nil;
            for(NSString *path in installedPaths()) {
                NSString *identifier=[NSBundle bundleWithPath:path].bundleIdentifier;
                if([identifier isEqual:CassotisBundleID] || [identifier isEqual:CassotisLegacyBundleID]) {
                    url=[NSURL fileURLWithPath:path];
                    break;
                }
            }
            if(!url) return 1;
            NSWorkspaceOpenConfiguration *configuration=NSWorkspaceOpenConfiguration.configuration;
            configuration.activates=NO;
            __block NSRunningApplication *application=nil;
            __block NSError *launchError=nil;
            [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:configuration
                completionHandler:^(NSRunningApplication *app,NSError *error){
                    dispatch_async(dispatch_get_main_queue(),^{ application=app;launchError=error; });
                }];
            NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+30;
            while(!launchError && (!application || (!application.finishedLaunching && !application.terminated)) &&
                  NSProcessInfo.processInfo.systemUptime<deadline)
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            if(launchError || !application.finishedLaunching || application.terminated ||
               ![application.bundleURL.URLByStandardizingPath isEqual:url.URLByStandardizingPath]) {
                std::cerr<<"Input method launch did not complete"<<std::endl;return 1;
            }
            std::cout<<"Input method frontend ready: pid="<<application.processIdentifier<<std::endl;
            return 0;
        }
        if([command isEqual:@"prepare-update"]) {
            TISInputSourceRef current=TISCopyCurrentKeyboardInputSource();
            NSString *bundle=(__bridge NSString *)TISGetInputSourceProperty(current,kTISPropertyBundleID);
            if([bundle isEqual:CassotisBundleID] || [bundle isEqual:CassotisLegacyBundleID]) {
                TISInputSourceRef ascii=TISCopyCurrentASCIICapableKeyboardInputSource();
                OSStatus status=ascii?TISSelectInputSource(ascii):paramErr;
                if(ascii)CFRelease(ascii);if(status){CFRelease(current);return 1;}
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
            }
            CFRelease(current);
            NSArray<NSString *> *installed=installedPaths();
            for(NSString *identifier in @[CassotisBundleID,CassotisLegacyBundleID])
                for(NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier])
                    if([installed containsObject:app.bundleURL.path]) [app terminate];
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
            // Only this user's executable files inside the installed Cassotis
            // bundle are eligible. Other engine instances and input methods stay live.
            int bytes=proc_listpids(PROC_UID_ONLY,getuid(),nullptr,0);
            std::vector<pid_t> pids(size_t(bytes/sizeof(pid_t)+32));
            bytes=proc_listpids(PROC_UID_ONLY,getuid(),pids.data(),int(pids.size()*sizeof(pid_t)));

            for(int i=0;i<bytes/int(sizeof(pid_t));++i) {
                char path[PROC_PIDPATHINFO_MAXSIZE]={};
                if(proc_pidpath(pids[i],path,sizeof(path))<=0)continue;
                NSString *executable=[NSString stringWithUTF8String:path];
                NSString *name=executable.lastPathComponent;
                if(![name isEqual:@"Cassotis"] && ![name isEqual:@"cassotis-engine"]) continue;
                NSString *bundle=executable.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
                if([installed containsObject:bundle]) kill(pids[i],SIGTERM);
            }
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
            return 0;
        }
        BOOL registrationOnly=[command isEqual:@"register-only"];
        if([command isEqual:@"register"] || registrationOnly) {
            if(argc!=3) return 2;
            NSURL *url=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
            OSStatus status=TISRegisterInputSource((__bridge CFURLRef)url);
            std::cout<<"TISRegisterInputSource="<<status<<std::endl;
            if(status) return 1;
            // Installation registers the bundle; System Settings owns user
            // enablement. On newer macOS, TIS can report success after a denied
            // preference write while still changing the input menu's ordering.
            if(registrationOnly) return 0;
        }
        NSDictionary *filter=([command isEqual:@"select-id"] || [command isEqual:@"status-id"]) && argc==3?
            @{(__bridge NSString *)kTISPropertyInputSourceID:[NSString stringWithUTF8String:argv[2]]}:
            @{(__bridge NSString *)kTISPropertyInputSourceID:CassotisBundleID};
        NSArray *sources=CFBridgingRelease(TISCreateInputSourceList((__bridge CFDictionaryRef)filter,true));
        for(id item in sources) {
            TISInputSourceRef source=(__bridge TISInputSourceRef)item;
            NSString *identifier=(__bridge NSString *)TISGetInputSourceProperty(source,kTISPropertyInputSourceID);
            BOOL enabled=CFBooleanGetValue((CFBooleanRef)TISGetInputSourceProperty(source,kTISPropertyInputSourceIsEnabled));
            BOOL selectable=CFBooleanGetValue((CFBooleanRef)TISGetInputSourceProperty(source,kTISPropertyInputSourceIsSelectCapable));
            NSString *type=(__bridge NSString *)TISGetInputSourceProperty(source,kTISPropertyInputSourceType);
            std::cout<<identifier.UTF8String<<" enabled="<<enabled<<" selectable="<<selectable<<" type="<<type.UTF8String<<std::endl;
            if([command isEqual:@"enable"] || [command isEqual:@"register"]) {
                OSStatus status=TISEnableInputSource(source);if(status) return 1;
            }
            if([command isEqual:@"select"] || [command isEqual:@"select-id"]) { OSStatus status=TISSelectInputSource(source);if(status) return 1; }
            if([command isEqual:@"disable"]) { OSStatus status=TISDisableInputSource(source);if(status) return 1; }
        }
        return sources.count?0:1;
    }
}
