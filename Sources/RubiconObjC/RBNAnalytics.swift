import Foundation
import Rubicon
import RubiconCore

/// The SDK's entry point for Objective-C apps (iOS Public API 1, 4, 7): a view over the Swift
/// `Analytics`. Create one per process on the main thread during launch, hold it, and call the
/// verbs from any thread; nothing blocks (Public API 9).
///
/// ```objc
/// RBNConfiguration *config = [[RBNConfiguration alloc] initWithApiKey:@"api-key"];
/// self.analytics = [RBNAnalytics makeWithConfiguration:config];
/// [self.analytics trackEvent:@"Purchase Completed" properties:@{@"amount": @49.90}];
/// ```
@objc(RBNAnalytics)
public final class RBNAnalytics: NSObject {
    /// The Swift instance behind the view; `RBNNetworkObserver` and tests use it.
    public let analytics: any Analytics

    // The one view per Swift instance, so a second `make` returns the same object (Configuration 3).
    private static let current = Locked<RBNAnalytics?>(nil)

    init(analytics: any Analytics) {
        self.analytics = analytics
    }

    /// Creates the instance; a second call returns the first (Configuration 3).
    @objc public static func make(configuration: RBNConfiguration) -> RBNAnalytics {
        let hookLog = RBNHookLog()
        return view(over: RubiconAnalytics.make(configuration: configuration.swift(hookLog: hookLog)), hookLog: hookLog)
    }

    /// The test seam of the Swift factory, with the same boxing.
    package static func make(configuration: RBNConfiguration, bundle: Bundle, storageRoot: URL?) -> RBNAnalytics {
        let hookLog = RBNHookLog()
        let analytics = RubiconAnalytics.make(
            configuration: configuration.swift(hookLog: hookLog), bundle: bundle, storageRoot: storageRoot)
        return view(over: analytics, hookLog: hookLog)
    }

    /// Forgets the view, after `RubiconAnalytics.resetForTests()`.
    package static func resetForTests() {
        RubiconAnalytics.resetForTests()
        current.withLock { $0 = nil }
    }

    private static func view(over analytics: any Analytics, hookLog: RBNHookLog) -> RBNAnalytics {
        current.withLock { cached in
            if let cached, (cached.analytics as AnyObject) === (analytics as AnyObject) { return cached }
            // The first view attaches its hooks to the instance; a later `make` returned the same
            // instance with the first configuration, so its hooks are never installed (Configuration 3).
            if let capture = analytics as? AutomaticCapture { hookLog.attach(capture.log) }
            let view = RBNAnalytics(analytics: analytics)
            cached = view
            return view
        }
    }

    /// The SDK's version, such as `1.0.0`. (`version` itself is taken by `NSObject`.)
    @objc public static var sdkVersion: String { RubiconAnalytics.version }

    /// Records an action (Public API 8).
    @objc public func trackEvent(_ name: String, properties: [String: Any]) {
        analytics.track(name, properties: properties)
    }

    /// Records an action without properties.
    @objc public func trackEvent(_ name: String) {
        analytics.track(name)
    }

    /// Records a screen view.
    @objc public func trackScreen(_ name: String, properties: [String: Any]) {
        analytics.screen(name, properties: properties)
    }

    /// Records a screen view without properties.
    @objc public func trackScreen(_ name: String) {
        analytics.screen(name)
    }

    /// Attaches the user (Identity 3, 4).
    @objc public func identifyUser(_ userId: String, traits: [String: Any]) {
        analytics.identify(userId, traits: traits)
    }

    /// Attaches the user without traits.
    @objc public func identifyUser(_ userId: String) {
        analytics.identify(userId)
    }

    /// Back to anonymous (Identity 5).
    @objc public func reset() {
        analytics.reset()
    }

    /// Adds a property to every later event (Context 5); `NSNull` is the value `null`.
    @objc public func registerSuperProperty(_ key: String, value: Any) {
        analytics.register(key, value: value)
    }

    /// Removes a super property.
    @objc public func unregisterSuperProperty(_ key: String) {
        analytics.unregister(key)
    }

    /// Triggers an upload and returns.
    @objc public func flush() {
        analytics.flush()
    }

    /// Stops collecting (Privacy 1).
    @objc public func optOut() {
        analytics.optOut()
    }

    /// Resumes collecting.
    @objc public func optIn() {
        analytics.optIn()
    }

    /// `YES` while opted out or consent is pending.
    @objc public var isOptedOut: Bool { analytics.isOptedOut }

    /// Deletes the person's data and renews the device id (Privacy 3).
    @objc public func clearLocalData() {
        analytics.clearLocalData()
    }

    /// The installation id.
    @objc public var deviceId: String { analytics.deviceId }

    /// A URL scheme deep link (iOS Lifecycle 3); `referrer` is the source application's bundle id.
    @objc public func trackDeepLink(_ url: URL, referrer: String?) {
        analytics.trackDeepLink(url, referrer: referrer)
    }

    /// A universal link from `NSUserActivityTypeBrowsingWeb`.
    @objc public func trackDeepLink(withActivity activity: NSUserActivity) {
        analytics.trackDeepLink(activity)
    }
}

/// The name of a view controller's automatic screen view (iOS Lifecycle 2), the Objective-C form of
/// `ScreenNamed`: implement the class method and the SDK uses it, with `name_source` `annotation`.
///
/// ```objc
/// @interface PaymentFlowViewController : UIViewController <RBNScreenNamed>
/// @end
/// @implementation PaymentFlowViewController
/// + (NSString *)rbnScreenName { return @"checkout"; }
/// @end
/// ```
@objc(RBNScreenNamed)
public protocol RBNScreenNamed {
    /// The screen name, 1 to 255 characters.
    @objc static func rbnScreenName() -> String
}

/// Sends a `Network Request` event for each call to the hosts you choose (iOS Lifecycle 5); forward
/// your `NSURLSession` delegate's `didFinishCollectingMetrics` and `didCompleteWithError` to it.
@objc(RBNNetworkObserver)
public final class RBNNetworkObserver: NSObject {
    private let observer: RubiconNetworkObserver

    /// - Parameters:
    ///   - analytics: the instance from `+makeWithConfiguration:`.
    ///   - hosts: exact host names or `*.domain.tld` wildcards.
    ///   - maskPathIds: whether ids in paths become `:id`; default `YES`.
    @objc public init(analytics: RBNAnalytics, hosts: Set<String>, maskPathIds: Bool) {
        observer = RubiconNetworkObserver(analytics: analytics.analytics, hosts: hosts, maskPathIds: maskPathIds)
    }

    /// With ids masked.
    @objc public convenience init(analytics: RBNAnalytics, hosts: Set<String>) {
        self.init(analytics: analytics, hosts: hosts, maskPathIds: true)
    }

    /// Forward `URLSession:task:didFinishCollectingMetrics:`.
    @objc(URLSession:task:didFinishCollectingMetrics:)
    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        observer.urlSession(session, task: task, didFinishCollecting: metrics)
    }

    /// Forward `URLSession:task:didCompleteWithError:`.
    @objc(URLSession:task:didCompleteWithError:)
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        observer.urlSession(session, task: task, didCompleteWithError: error)
    }
}
