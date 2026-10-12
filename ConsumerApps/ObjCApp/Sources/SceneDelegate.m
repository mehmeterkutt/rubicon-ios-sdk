#import "SceneDelegate.h"
#import "AppDelegate.h"
#import "ScenarioViewController.h"

@implementation SceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    AppDelegate *delegate = (AppDelegate *)UIApplication.sharedApplication.delegate;
    ScenarioViewController *screen = [[ScenarioViewController alloc] initWithAnalytics:delegate.analytics];
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = screen;
    [self.window makeKeyAndVisible];
}

@end
