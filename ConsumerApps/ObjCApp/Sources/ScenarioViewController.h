@import UIKit;
@import RubiconObjC;

/// The scenario screen of the Objective-C app (step 8.1), the twin of the Swift apps' screen with the
/// same accessibility identifiers, so the shared UI tests drive all three apps.
@interface ScenarioViewController : UIViewController

- (instancetype)initWithAnalytics:(RBNAnalytics *)analytics;

/// The screen on display, for the observer block created before it existed.
@property (class, nonatomic, weak, readonly) ScenarioViewController *current;

/// The observer's update, on the main thread.
- (void)applyUpdate:(RBNEventUpdate *)update;

@end
