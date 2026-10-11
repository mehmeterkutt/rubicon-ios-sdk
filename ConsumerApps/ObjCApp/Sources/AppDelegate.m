#import "AppDelegate.h"
@import RubiconObjC;

// The smallest Objective-C app that imports the wrapper (iOS Public API 1). Step 8.1 adds the
// scenario UI and tests.
@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UIViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
