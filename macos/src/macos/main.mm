#import <AppKit/AppKit.h>
#import <InputMethodKit/InputMethodKit.h>
#import <Carbon/Carbon.h>
#import <os/log.h>
#import "InputSession.h"
#import "SettingsController.h"
#import "ProductName.h"
#import "SyncController.h"

static void CassotisShowAboutPanel(void) {
    NSMutableParagraphStyle *paragraph=[[NSMutableParagraphStyle alloc] init];
    paragraph.alignment=NSTextAlignmentCenter;
    NSAttributedString *website=[[NSAttributedString alloc] initWithString:CassotisWebsiteURL().absoluteString
        attributes:@{NSLinkAttributeName:CassotisWebsiteURL(),
            NSFontAttributeName:[NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName:NSColor.linkColor,
            NSUnderlineStyleAttributeName:@(NSUnderlineStyleSingle),
            NSParagraphStyleAttributeName:paragraph}];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationName:CassotisProductName(),
        NSAboutPanelOptionCredits:website}];
    [NSApp activateIgnoringOtherApps:YES];
}

@interface CassotisInputController : IMKInputController
@end
@implementation CassotisInputController {
    CassotisInputSession *_session;
}
// Opt-in lifecycle diagnostics record identities and lengths, never input text.
- (void)trace:(const char *)operation sender:(id)sender {
    if(!getenv("CASSOTIS_TRACE_INPUT")) return;
    NSString *bundle=@"unknown";
    @try { if([sender respondsToSelector:@selector(bundleIdentifier)]) bundle=[sender bundleIdentifier]; }
    @catch(NSException *error) { (void)error; }
    os_log(OS_LOG_DEFAULT,"Cassotis lifecycle %{public}s controller=%p sender=%p current=%p marked=%lu bundle=%{public}@ foreground=%{public}@",
        operation,self,sender,_session.client,(unsigned long)_session.preedit.length,bundle,
        NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier);
}
- (id)initWithServer:(IMKServer *)server delegate:(id)delegate client:(id)client {
    self=[super initWithServer:server delegate:delegate client:client];
    if(self) _session=[[CassotisInputSession alloc] init]; return self;
}
- (NSUInteger)recognizedEvents:(id)sender {
    (void)sender; return NSEventMaskKeyDown|NSEventMaskKeyUp|NSEventMaskFlagsChanged|
        NSEventMaskLeftMouseDown|NSEventMaskRightMouseDown;
}
- (void)activateServer:(id)sender {
    [self trace:"activate" sender:sender];
    if(![_session activateFromNotification:sender]) [self trace:"ignored-background-activate" sender:sender];
}
- (void)deactivateServer:(id)sender { [self trace:"deactivate" sender:sender]; [_session deactivate]; }
- (BOOL)handleEvent:(NSEvent *)event client:(id)sender {
    if(event.type==NSEventTypeKeyUp) return NO;
    [self trace:event.type==NSEventTypeKeyDown?"key-down":"other-event" sender:sender];
    if(_session.client!=sender && event.type!=NSEventTypeKeyDown) return NO;
    if(_session.client!=sender) [_session activate:sender];
    return [_session handleEvent:event];
}
- (void)commitComposition:(id)sender { [self trace:"commit" sender:sender]; [_session commit]; }
- (void)cancelComposition:(id)sender { [self trace:"cancel" sender:sender]; [_session cancel]; }
- (void)showPreferences:(id)sender { (void)sender; [_session showSettings]; }
- (void)modeAction:(id)sender {
    NSMenuItem *item=[sender isKindOfClass:NSDictionary.class]?sender[kIMKCommandMenuItemName]:sender;
    [_session toggle:item.tag];
}
- (void)aboutAction:(id)sender {
    (void)sender;
    CassotisShowAboutPanel();
}
- (NSMenu *)menu {
    NSMenu *menu=[_session modeMenuWithTarget:self action:@selector(modeAction:)];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *settings=[[NSMenuItem alloc] initWithTitle:@"设置…" action:@selector(showPreferences:) keyEquivalent:@""];
    settings.target=self; [menu addItem:settings];
    NSMenuItem *about=[[NSMenuItem alloc] initWithTitle:[@"关于" stringByAppendingString:CassotisShortName()] action:@selector(aboutAction:) keyEquivalent:@""];
    about.target=self; [menu addItem:about]; return menu;
}
@end

@interface CassotisAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) IMKServer *server;
@end
@implementation CassotisAppDelegate
- (void)inputSourceChanged:(NSNotification *)notification {
    (void)notification;
    CassotisInputSourceDidChange();
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification; CassotisStopEngine();
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification; CassotisStartEngine();
    [CassotisSyncController.shared start];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(inputSourceChanged:)
        name:(__bridge NSString *)kTISNotifySelectedKeyboardInputSourceChanged object:nil];
    [self inputSourceChanged:nil];
    if([NSProcessInfo.processInfo.arguments containsObject:@"--settings"])
        [CassotisSettingsController.shared showWindow:nil];
    else if([NSProcessInfo.processInfo.arguments containsObject:@"--about"])
        CassotisShowAboutPanel();
}
@end
// Builds before 2026-11 ran under the upstream project's id. Carry its preferences
// (candidate font and theme, remembered input modes, logging) over once.
static void CassotisMigrateLegacyDefaults(void) {
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    NSString *mine=NSBundle.mainBundle.bundleIdentifier;
    static NSString *const legacy=@"org.cassotis.inputmethod.Cassotis";
    static NSString *const done=@"CassotisLegacyDefaultsMigrated";
    if(!mine || [mine isEqual:legacy] || [defaults boolForKey:done]) return;
    NSDictionary *old=[defaults persistentDomainForName:legacy];
    NSMutableDictionary *current=[([defaults persistentDomainForName:mine]?:@{}) mutableCopy];
    for(NSString *key in old) if(!current[key]) current[key]=old[key];
    current[done]=@YES;
    [defaults setPersistentDomain:current forName:mine];
}

int main(int argc,const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        // Checks signing and the iCloud entitlement from the shell: one round trip
        // to the container in a throwaway zone, then exit. No input method starts.
        if((argc==2 || argc==3) && !strcmp(argv[1],"--sync-probe")) {
            __block NSString *result=nil;
            __block BOOL success=NO;
            [CassotisCloudSync probeWithCompletion:^(NSString *report, BOOL passed) {
                dispatch_async(dispatch_get_main_queue(),^{ success=passed; result=report; });
            }];
            while(!result) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            printf("%s\n",result.UTF8String);
            return success ? 0 : 1;
        }
        CassotisMigrateLegacyDefaults();
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        CassotisAppDelegate * __attribute__((objc_precise_lifetime)) delegate=[[CassotisAppDelegate alloc] init];
        NSString *connection=[NSBundle.mainBundle objectForInfoDictionaryKey:@"InputMethodConnectionName"];
        delegate.server=[[IMKServer alloc] initWithName:connection
            bundleIdentifier:NSBundle.mainBundle.bundleIdentifier];
        if(!delegate.server) return 1;
        NSApp.delegate=delegate; [NSApp run];
    }
    return 0;
}
