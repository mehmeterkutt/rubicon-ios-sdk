import Rubicon
import UIKit

/// The one instance and the screen that shows it, shared by the app and scene delegates. Apps built
/// with the iOS 27 SDK must adopt the scene lifecycle (an app without a scene manifest traps at
/// launch), so the window belongs to the scene delegate and the instance to the launch.
@MainActor
final class ScenarioApp {
    static let shared = ScenarioApp()
    private(set) var analytics: (any Analytics)?
    weak var controller: ScenarioViewController?

    /// Creates the instance once, during `didFinishLaunching`.
    func start() {
        guard analytics == nil else { return }
        analytics = Scenario.makeAnalytics { update in
            Task { @MainActor in ScenarioApp.shared.controller?.apply(update) }
        }
    }
}

/// Builds the window for the one scene.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene, let analytics = ScenarioApp.shared.analytics else { return }
        let controller = ScenarioViewController(analytics: analytics)
        ScenarioApp.shared.controller = controller
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
    }
}
