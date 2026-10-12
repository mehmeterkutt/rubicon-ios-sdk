import Foundation
import RubiconCore

#if canImport(UIKit)
    import ObjectiveC
    import UIKit
#endif

/// Automatic screen views (Lifecycle 3; iOS Lifecycle 1, 2): the one swizzle of the SDK,
/// `UIViewController.viewDidAppear(_:)`, installed once per process, on the main thread, only when
/// `screenViews` is enabled, never reversed. Nothing else is ever swizzled.
///
/// - The controller that appeared is resolved to the visible one: presented, a navigation
///   controller's `visibleViewController`, a tab controller's `selectedViewController`, the first
///   child; container controllers are never screens.
/// - Skipped: classes from outside the main bundle (UIKit's own, alerts, system and third-party
///   controllers), `UIHostingController` and its subclasses (SwiftUI screens use `screen()`).
/// - Named by `ScreenNamed`, else the class (`ScreenNames`); the title is never used.
/// - The same instance appearing twice in a row is skipped; A to B to A counts. On
///   `willEnterForeground` the last screen is sent again if its controller is still in a window.
///
/// One process-wide installer holds the current instance's capture: a second instance (tests, a
/// restart in a test) replaces the target without swizzling again.
// The target and the last screen are `Locked`; UIKit calls arrive on the main thread.
final class ScreenCapture: @unchecked Sendable {
    static let shared = ScreenCapture()

    private struct Last {
        weak var controller: AnyObject?
        var name: String
        var source: String
    }

    private let target = Locked<(any AutomaticCapture)?>(nil)
    private let last = Locked<Last?>(nil)
    private let token = Locked<(any ListenerToken)?>(nil)
    private let installed = AtomicFlag()
    private let installs = Locked(0)
    /// The bundle whose controllers are screens: the app's. Tests point it at their own bundle,
    /// since the xctest host's `Bundle.main` is the runner, not the test bundle.
    let appBundle = Locked<Bundle>(.main)

    /// Called by the factory for a new instance, on the main thread (posted there otherwise), only
    /// when `screenViews` is enabled.
    func install(capture: any AutomaticCapture, lifecycle: any LifecycleSource) {
        target.withLock { $0 = capture }
        token.current?.cancel()
        token.withLock {
            $0 = lifecycle.addListener { [self] event in
                if case .foreground = event { resendLastScreen() }
            }
        }
        if Thread.isMainThread {
            swizzleOnce(capture.log)
        } else {
            DispatchQueue.main.async { [self] in swizzleOnce(capture.log) }
        }
    }

    /// How many times the swizzle was installed in this process: one, whatever the instances.
    var installCount: Int { installs.current }

    #if canImport(UIKit)
        /// UIKit's `viewDidAppear` of `controller`; the swizzled method calls it, tests call it directly.
        @MainActor
        func didAppear(_ controller: UIViewController) {
            guard let capture = target.current, let screen = Self.visibleScreen(from: controller) else { return }
            guard let (name, source) = Self.name(of: screen) else { return }
            let repeated: Bool = last.withLock { l in
                if let l, l.controller === screen { return true }
                l = Last(controller: screen, name: name, source: source)
                return false
            }
            if repeated { return }
            capture.screen(gate: .screenViews, name: name, properties: [ScreenNames.nameSource: source])
        }

        /// The screen among the controllers that appeared: the one the user sees (iOS Lifecycle 2).
        @MainActor
        static func visibleScreen(from controller: UIViewController) -> UIViewController? {
            var current = controller
            var hops = 0
            while hops < 16 {
                hops += 1
                if let presented = current.presentedViewController, presented.isBeingDismissed == false,
                    presented !== controller
                {
                    current = presented
                    continue
                }
                if let navigation = current as? UINavigationController {
                    guard let visible = navigation.visibleViewController, visible !== current else { return nil }
                    current = visible
                    continue
                }
                if let tabs = current as? UITabBarController {
                    guard let selected = tabs.selectedViewController else { return nil }
                    current = selected
                    continue
                }
                if current is UIPageViewController || current is UISplitViewController {
                    guard let child = current.children.first else { return nil }
                    current = child
                    continue
                }
                return current
            }
            return nil
        }

        /// The name and its source, or `nil` when the controller is not a screen of the app.
        @MainActor
        static func name(of controller: UIViewController) -> (String, String)? {
            let type = type(of: controller)
            let typeName = NSStringFromClass(type)
            if typeName.contains("UIHostingController") { return nil }
            guard Bundle(for: type) == shared.appBundle.current else { return nil }
            if let named = type as? ScreenNamed.Type { return (named.screenName, ScreenNames.declared) }
            return (ScreenNames.name(forClass: typeName), ScreenNames.fromClass)
        }

        private func resendLastScreen() {
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    let kept: Last? = last.current
                    guard let kept, let capture = target.current, let controller = kept.controller as? UIViewController,
                        controller.viewIfLoaded?.window != nil
                    else { return }
                    capture.screen(
                        gate: .screenViews, name: kept.name, properties: [ScreenNames.nameSource: kept.source])
                }
            }
        }

        // MARK: - The swizzle

        private static let originalImplementation = Locked<IMP?>(nil)

        private func swizzleOnce(_ log: Log) {
            guard installed.set() else { return }
            installs.withLock { $0 += 1 }
            let selector = #selector(UIViewController.viewDidAppear(_:))
            guard let method = class_getInstanceMethod(UIViewController.self, selector) else {
                log.warn(.swizzleFailed) { "viewDidAppear could not be found; automatic screen views are off" }
                return
            }
            Self.originalImplementation.withLock { $0 = method_getImplementation(method) }
            let block: @convention(block) (UIViewController, Bool) -> Void = { controller, animated in
                typealias Function = @convention(c) (UIViewController, Selector, Bool) -> Void
                if let original = ScreenCapture.originalImplementation.current {
                    unsafeBitCast(original, to: Function.self)(controller, selector, animated)
                }
                MainActor.assumeIsolated { ScreenCapture.shared.didAppear(controller) }
            }
            let replacement = imp_implementationWithBlock(block)
            // Add-then-replace: a subclass-free base method is replaced in place; the IMP returned by
            // class_replaceMethod is the original when the method existed, nil when it was just added.
            if class_addMethod(UIViewController.self, selector, replacement, method_getTypeEncoding(method)) {
                return
            }
            if class_replaceMethod(UIViewController.self, selector, replacement, method_getTypeEncoding(method)) == nil
            {
                log.warn(.swizzleFailed) { "viewDidAppear could not be replaced; automatic screen views are off" }
            }
        }
    #else
        private func swizzleOnce(_ log: Log) {}

        private func resendLastScreen() {}
    #endif
}
