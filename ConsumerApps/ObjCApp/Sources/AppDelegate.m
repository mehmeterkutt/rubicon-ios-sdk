#import "AppDelegate.h"
#import "ScenarioViewController.h"
@import RubiconObjC;

// The Objective-C consumer app (iOS Public API 1 and 3, step 8.1): the instance is created at launch
// through the wrapper from the launch environment; SceneDelegate builds the scenario screen.
@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    if ([environment[@"RUBICON_RESET"] isEqualToString:@"1"]) {
        NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                              inDomains:NSUserDomainMask].firstObject;
        [NSFileManager.defaultManager removeItemAtURL:[support URLByAppendingPathComponent:@"rubicon"] error:nil];
    }
    RBNConfiguration *config = [[RBNConfiguration alloc] initWithApiKey:@"rk_consumer"];
    config.host = environment[@"RUBICON_HOST"] ?: @"http://127.0.0.1:9";
    config.debug = NO;
    config.flush.at = 100;
    config.flush.intervalMs = 600000;
    config.logging.sendDiagnostics = NO;
    config.logging.eventObserver = ^(RBNEventUpdate *update) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ScenarioViewController.current applyUpdate:update];
        });
    };
    // The hooks a client writes (step 8.2): a logger block and a beforeSend block that tags app
    // events and drops debug events; a block that raises is caught by the wrapper (HOOK_THREW).
    config.logging.logger = ^(RBNLogLevel level, NSString *message, NSError *error) {
        NSLog(@"[rubicon %ld] %@ %@", (long)level, message, error ?: @"");
    };
    [config addBeforeSend:^RBNEvent *(RBNEvent *event) {
        if (![event isKindOfClass:[RBNTrackEvent class]] || event.source != RBNEventSourceApp) return event;
        RBNTrackEvent *track = (RBNTrackEvent *)event;
        if ([track.name hasPrefix:@"debug_"]) return nil;
        NSMutableDictionary *properties = [track.properties mutableCopy];
        properties[@"client"] = @"objc";
        track.properties = properties;
        return track;
    }];
    self.analytics = [RBNAnalytics makeWithConfiguration:config];
    return YES;
}

@end
