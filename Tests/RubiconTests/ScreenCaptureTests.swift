import Foundation
import RubiconTesting
import Testing

@testable import Rubicon
@testable import RubiconCore

#if canImport(UIKit)
    import SwiftUI
    import UIKit

    final class CheckoutViewController: UIViewController {}

    final class PaymentFlowViewController: UIViewController, ScreenNamed {
        static let screenName = "checkout"
    }

    final class SettingsViewController: UIViewController {}

    /// Automatic screen views on the simulator (step 7.5): real controllers in a real window.
    @Suite("ScreenCapture", .serialized)
    @MainActor
    struct ScreenCaptureTests {
        final class RecordingCapture: AutomaticCapture, @unchecked Sendable {
            let screens = Locked<[(String, String)]>([])
            let log: Log
            init(log: Log) { self.log = log }
            func track(gate: Autocapture, name: String, properties: [String: Any]) {}
            func screen(gate: Autocapture, name: String, properties: [String: Any]) {
                screens.withLock { $0.append((name, properties[ScreenNames.nameSource] as? String ?? "?")) }
            }
            var capturesNetworkRequests: Bool { false }
            var sdkHost: String { "" }
            var debug: Bool { false }
        }

        let test = TestPlatform()
        let lifecycle = FakeLifecycleSource(foreground: true)
        let window = UIWindow(frame: UIScreen.main.bounds)

        func capture() -> RecordingCapture {
            let capture = RecordingCapture(log: test.log())
            // The test bundle plays the app's bundle; the xctest runner is `Bundle.main` here.
            ScreenCapture.shared.appBundle.withLock { $0 = Bundle(for: CheckoutViewController.self) }
            ScreenCapture.shared.install(capture: capture, lifecycle: lifecycle)
            return capture
        }

        /// What UIKit does when a controller becomes visible, synchronously.
        func show(_ controller: UIViewController) {
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.loadViewIfNeeded()
            controller.beginAppearanceTransition(true, animated: false)
            controller.endAppearanceTransition()
        }

        func names(_ capture: RecordingCapture) -> [String] { capture.screens.current.map(\.0) }

        @Test("a controller that appears produces one screen, named by the class or by ScreenNamed")
        func classAndDeclaredNames() {
            let capture = capture()

            show(CheckoutViewController())
            show(PaymentFlowViewController())

            #expect(names(capture) == ["Checkout", "checkout"])
            #expect(capture.screens.current.map(\.1) == ["class", "annotation"])
        }

        @Test("the same instance appearing twice in a row is skipped; A to B to A counts")
        func repeats() {
            let capture = capture()
            let checkout = CheckoutViewController()
            let settings = SettingsViewController()

            show(checkout)
            ScreenCapture.shared.didAppear(checkout)
            show(settings)
            show(checkout)

            #expect(names(capture) == ["Checkout", "Settings", "Checkout"])
        }

        @Test("containers are never screens: the visible controller of a navigation or tab controller is")
        func containers() {
            let capture = capture()
            let navigation = UINavigationController(rootViewController: CheckoutViewController())
            show(navigation)
            let tabs = UITabBarController()
            tabs.viewControllers = [SettingsViewController(), PaymentFlowViewController()]
            tabs.selectedIndex = 1
            show(tabs)

            #expect(names(capture) == ["Checkout", "checkout"])
        }

        @Test("UIHostingController and controllers from outside the main bundle produce nothing")
        func skipped() {
            let capture = capture()

            show(UIHostingController(rootView: Text("SwiftUI")))
            show(UIAlertController(title: "t", message: nil, preferredStyle: .alert))
            #expect(ScreenCapture.name(of: UIViewController()) == nil)

            #expect(names(capture).isEmpty)
        }

        @Test("returning to the foreground sends the last screen again while its controller is still visible")
        func resendOnForeground() async {
            let capture = capture()
            let checkout = CheckoutViewController()
            show(checkout)
            #expect(names(capture) == ["Checkout"])

            lifecycle.moveToBackground()
            lifecycle.moveToForeground()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 50_000_000)

            #expect(names(capture) == ["Checkout", "Checkout"])
            window.rootViewController = nil
            lifecycle.moveToBackground()
            lifecycle.moveToForeground()
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(names(capture) == ["Checkout", "Checkout"])
        }

        @Test("the swizzle is installed once with two instances, and the newer instance receives the screens")
        func installedOnce() {
            let first = capture()
            let second = capture()

            show(SettingsViewController())

            #expect(ScreenCapture.shared.installCount == 1)
            #expect(names(first).isEmpty)
            #expect(names(second) == ["Settings"])
        }
    }
#endif
