import Foundation

/// The SDK's entry point (Public API 2, 8; iOS Public API 4, 7). Create one per process with the
/// factory of the `Rubicon` target, `RubiconAnalytics.make(configuration:)`, hold it in your app
/// delegate or dependency container, and pass it to the code that tracks (Public API 1). In tests,
/// pass a fake: a conformance is a few lines.
///
/// ```swift
/// let analytics = RubiconAnalytics.make(configuration: AnalyticsConfiguration(apiKey: key))
/// analytics.track("Purchase Completed", properties: ["amount": 49.90])
/// ```
///
/// Threading (Public API 9, iOS Public API 3):
/// 1. Every method can be called from any thread; the instance is `Sendable`.
/// 2. No method blocks: disk and network work never runs on the calling thread. The calling thread
///    only copies the arguments, validates properties and takes a snapshot of identity and super
///    properties. The exceptions are `isOptedOut` and `deviceId` in the first milliseconds after
///    startup, which may read a small file once.
/// 3. Calls made from the same thread take effect in call order. `identify`, `reset`, `register`
///    and `unregister` change in-memory state at once and persist later, so a `track` after
///    `identify` carries the new identity. There is no order between calls on different threads.
///
/// Properties and traits are `[String: Any]` of `String`, `Bool`, the integer types, `Double`,
/// `Float`, `NSNull`, and arrays and dictionaries of these; `Date`, `URL`, `Decimal` and
/// payload-free enums are converted (iOS Serialization 2). Other values are dropped with a warning,
/// or are a developer error when `debug` is on (Public API 3). The SDK never keeps your dictionary.
///
/// Methods may be added in minor versions, always with a default implementation.
public protocol Analytics: Sendable {
    /// Records an action, such as `Purchase Completed`. A name that is blank or longer than 255
    /// characters drops the event with a warning, or is a developer error when `debug` is on.
    /// Plain Title Case names, as the automatic events use, and `snake_case` property keys are
    /// recommended.
    func track(_ name: String, properties: [String: Any])

    /// Records a screen view. Use a fixed key from your tracking plan, the same on every platform
    /// (`checkout`), never displayed text or a filled route. Send each screen either automatically
    /// (`Autocapture.screenViews`) or with this method, never both.
    func screen(_ name: String, properties: [String: Any])

    /// Attaches the user `userId` to this and every later event, and sends `traits` once with an
    /// identify event; traits are never stored. Calling it again with the same id and no traits
    /// does nothing. A different id while identified starts a new user: super properties and the
    /// session are cleared first. A blank id, or one longer than 255 characters, is ignored with a
    /// warning, or is a developer error when `debug` is on.
    func identify(_ userId: String, traits: [String: Any])

    /// Returns to an anonymous user, for example on logout: clears the user id, super properties
    /// and the session. `deviceId` stays, queued events are still sent, and no event is produced.
    func reset()

    /// Adds a super property, sent with every later event of this user until `unregister` or
    /// `reset`. A property of the event itself with the same key wins. `value` follows the property
    /// rules; `NSNull` is stored and sent as `null`.
    func register(_ key: String, value: Any)

    /// Removes the super property `key`.
    func unregister(_ key: String)

    /// Asks for an upload of every event tracked so far and returns at once. Uploads also happen by
    /// themselves; calling this is rarely needed.
    func flush()

    /// Stops collection: no new events of any kind, until `optIn`. Events collected before are
    /// still sent. With `privacy.persistConsent` (the default) the choice survives restarts. To
    /// also delete the data on the device, call `clearLocalData` after this.
    func optOut()

    /// Resumes collection after `optOut`, or gives consent when `privacy.defaultConsent` is `.pending`.
    func optIn()

    /// Whether nothing is being sent now: `true` after `optOut` and while consent is pending. Read
    /// in the first milliseconds after startup, it may read a small file once on the calling thread.
    var isOptedOut: Bool { get }

    /// Deletes everything on the device that belongs to a person: queued events, the user id, super
    /// properties and the session, and renews `deviceId`. The consent choice is kept. An upload
    /// already in flight may still complete. Collection goes on; "forget me" is `optOut` then this.
    ///
    /// ```swift
    /// let oldId = analytics.deviceId          // read before clearing
    /// backend.requestErasure(of: oldId)
    /// analytics.optOut()
    /// analytics.clearLocalData()
    /// ```
    func clearLocalData()

    /// The id of this installation, sent with every event, for example to request erasure on your
    /// backend. It changes only with `clearLocalData`; `reset` keeps it. Read in the first
    /// milliseconds after startup, it may read a small file once on the calling thread.
    var deviceId: String { get }

    /// Records `Deep Link Opened` for a link delivered through a URL scheme, when
    /// `Autocapture.deepLinks` is enabled; otherwise the call is ignored (iOS Lifecycle 3). Call it
    /// from `application(_:open:options:)`, `scene(_:openURLContexts:)` or SwiftUI's `onOpenURL`,
    /// passing the source application as `referrer` when iOS gives one. The event carries the
    /// scheme, host, path, the `utm_*` parameters present and the referrer; never other parameters
    /// or the fragment.
    func trackDeepLink(_ url: URL, referrer: String?)

    /// Records `Deep Link Opened` for a universal link delivered as an `NSUserActivity`, when
    /// `Autocapture.deepLinks` is enabled; otherwise the call is ignored. Activities other than web
    /// browsing, or without a `webpageURL`, are ignored. Call it from
    /// `application(_:continue:restorationHandler:)` or SwiftUI's `onContinueUserActivity`.
    func trackDeepLink(_ activity: NSUserActivity)
}

extension Analytics {
    /// `track` without properties.
    public func track(_ name: String) {
        track(name, properties: [:])
    }

    /// `screen` without properties.
    public func screen(_ name: String) {
        screen(name, properties: [:])
    }

    /// `identify` without traits.
    public func identify(_ userId: String) {
        identify(userId, traits: [:])
    }

    /// `trackDeepLink` without a referrer.
    public func trackDeepLink(_ url: URL) {
        trackDeepLink(url, referrer: nil)
    }
}
