import Rubicon
import UIKit

// The consumer app (iOS Public API 3, step 8.1): the instance is created at launch, the shared
// scenario screen is built by the scene delegate (the scene manifest is in the Info.plist).
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ScenarioApp.shared.start()
        return true
    }
}
