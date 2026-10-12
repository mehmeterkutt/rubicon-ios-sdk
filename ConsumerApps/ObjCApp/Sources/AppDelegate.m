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
    self.analytics = [RBNAnalytics makeWithConfiguration:config];
    return YES;
}

@end
