@import UIKit;
@import RubiconObjC;

@interface AppDelegate : UIResponder <UIApplicationDelegate>
/// The one instance, created at launch; the scene delegate builds the screen over it.
@property (strong, nonatomic) RBNAnalytics *analytics;
@end
