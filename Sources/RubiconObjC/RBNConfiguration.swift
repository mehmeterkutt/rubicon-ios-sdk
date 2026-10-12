import Foundation
import Rubicon
import RubiconCore

/// A `beforeSend` hook (Public API 4, iOS Public API 6): sees each event before it is stored, on the
/// thread that called the SDK. Return the event, changed or not, or `nil` to drop an app event. A
/// block that raises an `NSException` drops the event with reason `before_send` and logs
/// `HOOK_THREW`; the exception never reaches your call site.
public typealias RBNBeforeSend = @Sendable (RBNEvent) -> RBNEvent?

/// A logger (Logging 1, iOS Logging 1): the level, the message and the error, if any. Called from the
/// SDK's queues and sometimes from the calling thread; keep it fast and thread-safe. A block that
/// raises is replaced by the SDK's default sink with `LOGGER_THREW`.
public typealias RBNLogger = @Sendable (RBNLogLevel, String, NSError?) -> Void

/// The event observer (Logging 4c): what became of each event, on the SDK's queues. A block that
/// raises is switched off with `OBSERVER_THREW`.
public typealias RBNEventObserver = @Sendable (RBNEventUpdate) -> Void

/// The configuration (Configuration 2, iOS Configuration 1), a mutable object over the Swift value:
/// set what you need, then pass it to `+[RBNAnalytics makeWithConfiguration:]`, which copies it.
/// Later changes do not reach the SDK.
///
/// ```objc
/// RBNConfiguration *config = [[RBNConfiguration alloc] initWithApiKey:@"api-key"];
/// config.flush.at = 20;
/// [config.autocapture disable:RBNAutocaptureNetworkRequests];
/// RBNAnalytics *analytics = [RBNAnalytics makeWithConfiguration:config];
/// ```
@objc(RBNConfiguration)
public final class RBNConfiguration: NSObject {
    // The Swift value; the groups below read and write it through the owner.
    let value: Locked<AnalyticsConfiguration>
    // The blocks, kept so the Swift closures can be rebuilt on every read of `value`.
    private let beforeSendBlocks = Locked<[RBNBeforeSend]>([])
    private let loggerBlock = Locked<RBNLogger?>(nil)
    private let observerBlock = Locked<RBNEventObserver?>(nil)

    /// Creates a configuration for `apiKey`; everything else has the Swift defaults.
    @objc public init(apiKey: String) {
        value = Locked(AnalyticsConfiguration(apiKey: apiKey))
        super.init()
    }

    /// The API key.
    @objc public var apiKey: String { value.current.apiKey }

    /// The base URL of the analytics server (Configuration 3).
    @objc public var host: String {
        get { value.current.host }
        set { value.withLock { $0.host = newValue } }
    }

    /// Whether developer mistakes are reported loudly (iOS Configuration 2); defaults to the build.
    @objc public var debug: Bool {
        get { value.current.debug }
        set { value.withLock { $0.debug = newValue } }
    }

    /// Adds a hook; the hooks run in the order added (Public API 4).
    @objc public func addBeforeSend(_ block: @escaping RBNBeforeSend) {
        beforeSendBlocks.withLock { $0.append(block) }
    }

    /// The number of hooks added.
    @objc public var beforeSendCount: Int { beforeSendBlocks.current.count }

    /// Removes every hook.
    @objc public func removeAllBeforeSend() {
        beforeSendBlocks.withLock { $0.removeAll() }
    }

    /// The flush settings (Queue 2, 3, 7).
    @objc public private(set) lazy var flush = RBNFlushConfiguration(owner: self)
    /// The session settings (Session 4).
    @objc public private(set) lazy var session = RBNSessionConfiguration(owner: self)
    /// The automatic event types (Lifecycle 6).
    @objc public private(set) lazy var autocapture = RBNAutocaptureConfiguration(owner: self)
    /// The context fields (Context 6).
    @objc public private(set) lazy var context = RBNContextConfiguration(owner: self)
    /// Consent (Privacy 2, 4).
    @objc public private(set) lazy var privacy = RBNPrivacyConfiguration(owner: self)
    /// Logging (Logging 1 to 5).
    @objc public private(set) lazy var logging = RBNLoggingConfiguration(owner: self)
    /// Network headers (Configuration 5).
    @objc public private(set) lazy var network = RBNNetworkConfiguration(owner: self)

    func setLogger(_ block: RBNLogger?) { loggerBlock.withLock { $0 = block } }
    var logger: RBNLogger? { loggerBlock.current }
    func setObserver(_ block: RBNEventObserver?) { observerBlock.withLock { $0 = block } }
    var observer: RBNEventObserver? { observerBlock.current }

    /// The Swift configuration with the blocks boxed; `hookLog` is filled by the factory once the
    /// instance exists, so a raising hook can be logged with the instance's log.
    func swift(hookLog: RBNHookLog) -> AnalyticsConfiguration {
        var config = value.current
        config.beforeSend = beforeSendBlocks.current.map { RBNHookBox.beforeSend($0, log: hookLog) }
        config.logging.logger = loggerBlock.current.map { RBNHookBox.logger($0, log: hookLog) }
        config.logging.eventObserver = observerBlock.current.map { RBNHookBox.observer($0, log: hookLog) }
        return config
    }
}

/// The `flush` group.
@objc(RBNFlushConfiguration)
public final class RBNFlushConfiguration: NSObject {
    private unowned let owner: RBNConfiguration
    init(owner: RBNConfiguration) { self.owner = owner }

    /// Events pending before an upload starts; 1 to 100, default 30.
    @objc public var at: Int {
        get { owner.value.current.flush.at }
        set { owner.value.withLock { $0.flush.at = newValue } }
    }

    /// Milliseconds after the first pending event before an upload; 1 s to 10 min, default 60 s.
    @objc public var intervalMs: Int64 {
        get { owner.value.current.flush.intervalMs }
        set { owner.value.withLock { $0.flush.intervalMs = newValue } }
    }

    /// Event names that trigger an upload right after they are stored (Queue 7).
    @objc public var immediateEvents: Set<String> {
        get { owner.value.current.flush.immediateEvents }
        set { owner.value.withLock { $0.flush.immediateEvents = newValue } }
    }
}

/// The `session` group.
@objc(RBNSessionConfiguration)
public final class RBNSessionConfiguration: NSObject {
    private unowned let owner: RBNConfiguration
    init(owner: RBNConfiguration) { self.owner = owner }

    /// Milliseconds in the background before a session ends; 10 s to 2 h, default 5 min.
    @objc public var backgroundTimeoutMs: Int64 {
        get { owner.value.current.session.backgroundTimeoutMs }
        set { owner.value.withLock { $0.session.backgroundTimeoutMs = newValue } }
    }
}

/// The `autocapture` group: the automatic event types, all on by default except deep links.
@objc(RBNAutocaptureConfiguration)
public final class RBNAutocaptureConfiguration: NSObject {
    private unowned let owner: RBNConfiguration
    init(owner: RBNConfiguration) { self.owner = owner }

    /// Whether `type` is on.
    @objc public func isEnabled(_ type: RBNAutocapture) -> Bool {
        owner.value.current.autocapture.enabled.contains(type.swift)
    }

    /// Switches `type` on.
    @objc public func enable(_ type: RBNAutocapture) {
        owner.value.withLock { _ = $0.autocapture.enabled.insert(type.swift) }
    }

    /// Switches `type` off.
    @objc public func disable(_ type: RBNAutocapture) {
        owner.value.withLock { _ = $0.autocapture.enabled.remove(type.swift) }
    }
}

/// The `context` group: fields that are never collected.
@objc(RBNContextConfiguration)
public final class RBNContextConfiguration: NSObject {
    private unowned let owner: RBNConfiguration
    init(owner: RBNConfiguration) { self.owner = owner }

    /// Whether `field` is switched off.
    @objc public func isDisabled(_ field: RBNContextField) -> Bool {
        owner.value.current.context.disabledFields.contains(field.swift)
    }

    /// Switches `field` off: it is never read (Context 6).
    @objc public func disable(_ field: RBNContextField) {
        owner.value.withLock { _ = $0.context.disabledFields.insert(field.swift) }
    }

    /// Switches `field` on again.
    @objc public func enable(_ field: RBNContextField) {
        owner.value.withLock { _ = $0.context.disabledFields.remove(field.swift) }
    }
}

/// The `privacy` group.
@objc(RBNPrivacyConfiguration)
public final class RBNPrivacyConfiguration: NSObject {
    private unowned let owner: RBNConfiguration
    init(owner: RBNConfiguration) { self.owner = owner }

    /// The state when no choice is stored; default granted (Privacy 4).
    @objc public var defaultConsent: RBNConsent {
        get { RBNConsent(owner.value.current.privacy.defaultConsent) }
        set { owner.value.withLock { $0.privacy.defaultConsent = newValue.swift } }
    }

    /// Whether the SDK stores the user's choice; default `YES` (Privacy 2).
    @objc public var persistConsent: Bool {
        get { owner.value.current.privacy.persistConsent }
        set { owner.value.withLock { $0.privacy.persistConsent = newValue } }
    }
}

/// The `logging` group.
@objc(RBNLoggingConfiguration)
public final class RBNLoggingConfiguration: NSObject {
    private unowned let owner: RBNConfiguration
    init(owner: RBNConfiguration) { self.owner = owner }

    /// The lowest level written; default warn (Logging 2).
    @objc public var level: RBNLogLevel {
        get { RBNLogLevel(owner.value.current.logging.level) }
        set { owner.value.withLock { $0.logging.level = newValue.swift } }
    }

    /// Your logger; `nil` means unified logging under `com.rubicon.analytics` (iOS Logging 1).
    @objc public var logger: RBNLogger? {
        get { owner.logger }
        set { owner.setLogger(newValue) }
    }

    /// The event observer, for QA screens and tests (Logging 4c).
    @objc public var eventObserver: RBNEventObserver? {
        get { owner.observer }
        set { owner.setObserver(newValue) }
    }

    /// Whether `SDK Diagnostics` is sent; default `YES` (Logging 5).
    @objc public var sendDiagnostics: Bool {
        get { owner.value.current.logging.sendDiagnostics }
        set { owner.value.withLock { $0.logging.sendDiagnostics = newValue } }
    }
}

/// The `network` group.
@objc(RBNNetworkConfiguration)
public final class RBNNetworkConfiguration: NSObject {
    private unowned let owner: RBNConfiguration
    init(owner: RBNConfiguration) { self.owner = owner }

    /// Headers added to every request, for gateways; the SDK's own names are reserved.
    @objc public var headers: [String: String] {
        get { owner.value.current.network.headers }
        set { owner.value.withLock { $0.network.headers = newValue } }
    }
}
