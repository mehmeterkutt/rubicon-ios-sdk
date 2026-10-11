import Foundation

/// Everything the SDK needs to start, handed to the factory once (Configuration 2, iOS
/// Configuration 1). Only `apiKey` is required; every other setting has a default. Settings live in
/// small groups held in `var` properties, so `config.flush.at = 20` reads as on Android.
///
/// The configuration is a value: the factory validates its copy and keeps it as the snapshot, so a
/// change made after `make` stays in the caller's copy and never reaches the SDK. Behaviour that
/// changes at runtime goes through `Analytics`, never through the configuration.
///
/// ```swift
/// var config = AnalyticsConfiguration(apiKey: Secrets.rubiconKey)
/// config.flush.immediateEvents = ["Purchase Completed"]
/// config.autocapture.enabled.remove(.networkRequests)
/// let analytics = RubiconAnalytics.make(configuration: config)
/// ```
public struct AnalyticsConfiguration: Sendable {
    /// The SaaS base URL, used when `host` is not set.
    public static let defaultHost = "https://api.rubicon.example"

    /// The default of `debug`: `true` in a Debug build of the app, `false` otherwise (iOS
    /// Configuration 2). SwiftPM compiles the SDK with the app's configuration.
    public static let defaultDebug: Bool = {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }()

    /// The project's write key. A blank key is a developer error when `debug` is on; otherwise the
    /// SDK does nothing and logs an error.
    public let apiKey: String

    /// The base URL of the analytics server. Default `defaultHost`; on-prem and proxy setups set
    /// their own, with an `http` or `https` scheme and an optional path:
    /// `https://intranet.example.com/analytics`. A trailing slash is ignored. `http://` works and
    /// logs a warning, and needs an App Transport Security exception in the app's `Info.plist`. An
    /// invalid URL, or one with a query, fragment, user info or surrounding whitespace, is a
    /// developer error when `debug` is on; otherwise the SDK does nothing and logs an error.
    public var host: String = AnalyticsConfiguration.defaultHost

    /// Whether developer mistakes are reported loudly (`assertionFailure`), such as an invalid
    /// setting or an unsupported property value. Default `defaultDebug`: on in Debug builds, off
    /// otherwise; set it yourself for a Release build you want to check. It changes neither the log
    /// level nor when events are uploaded.
    public var debug: Bool = AnalyticsConfiguration.defaultDebug

    /// Hooks that see each event in list order before it is stored (Public API 4). Empty by
    /// default. A hook returns the event, a changed copy of it, or `nil` to drop it. Automatic
    /// events allow only new property values; `BeforeSend` has the rules. Fixed when the SDK is
    /// created; runs on the thread that called the SDK.
    ///
    /// ```swift
    /// config.beforeSend = [{ event in (event as? TrackEvent)?.name.hasPrefix("debug_") == true ? nil : event }]
    /// ```
    public var beforeSend: [BeforeSend] = []

    /// When events are uploaded.
    public var flush = FlushConfiguration()

    /// How sessions are measured.
    public var session = SessionConfiguration()

    /// Which events the SDK captures by itself.
    public var autocapture = AutocaptureConfiguration()

    /// What goes into each event's `context`.
    public var context = ContextConfiguration()

    /// Consent.
    public var privacy = PrivacyConfiguration()

    /// The SDK's own log lines and health reports.
    public var logging = LoggingConfiguration()

    /// Requests the SDK sends.
    public var network = NetworkConfiguration()

    /// Creates a configuration with the defaults; only the key is required.
    public init(apiKey: String) {
        self.apiKey = apiKey
    }
}

extension AnalyticsConfiguration: CustomStringConvertible {
    /// The host only: never the API key or headers (Logging 4).
    public var description: String { "AnalyticsConfiguration(host: \(host))" }
}

/// When queued events are uploaded (Queue 2, 3, 7). Held by `AnalyticsConfiguration.flush`.
///
/// The defaults are a starting point and may be tuned in minor releases. Remote configuration can
/// only raise `at` and `intervalMs`, within their bounds.
public struct FlushConfiguration: Sendable {
    /// Upload when this many events are waiting on the device. Default 30; from 1 to 100. A value
    /// out of bounds is a developer error when `debug` is on, and is clamped otherwise.
    public var at: Int = 30

    /// Upload this long after the first waiting event, in milliseconds. Default 60 000 (one
    /// minute); from 1 000 (one second) to 600 000 (ten minutes). A value out of bounds is a
    /// developer error when `debug` is on, and is clamped otherwise.
    public var intervalMs: Int64 = 60_000

    /// Event names that are uploaded right after they are stored, together with everything waiting
    /// before them. Matched exactly, after the `beforeSend` hooks. Empty by default. Without a
    /// network the event waits like any other.
    public var immediateEvents: Set<String> = []

    /// The defaults.
    public init() {}
}

/// How sessions are measured (Session 4). Held by `AnalyticsConfiguration.session`.
public struct SessionConfiguration: Sendable {
    /// A session continues if the app returns to the foreground within this time, in
    /// milliseconds. Default 300 000 (five minutes); from 10 000 (ten seconds) to 7 200 000 (two
    /// hours). A value out of bounds is a developer error when `debug` is on, and is clamped
    /// otherwise.
    public var backgroundTimeoutMs: Int64 = 300_000

    /// The defaults.
    public init() {}
}

/// Which events the SDK captures by itself (Lifecycle 6). Held by `AnalyticsConfiguration.autocapture`.
public struct AutocaptureConfiguration: Sendable {
    /// The enabled types. Default: every `Autocapture` type except `deepLinks`.
    ///
    /// ```swift
    /// config.autocapture.enabled.remove(.screenViews)
    /// ```
    public var enabled: Set<Autocapture> = [.appLifecycle, .installUpdate, .sessions, .screenViews, .networkRequests]

    /// The defaults.
    public init() {}
}

/// What goes into each event's `context` (Context 6). Held by `AnalyticsConfiguration.context`.
public struct ContextConfiguration: Sendable {
    /// Fields that are never read and never sent. Empty by default.
    public var disabledFields: Set<ContextField> = []

    /// The defaults.
    public init() {}
}

/// Consent (Privacy 2, 4). Held by `AnalyticsConfiguration.privacy`; change it at runtime with
/// `optIn` and `optOut`.
public struct PrivacyConfiguration: Sendable {
    /// The state while no choice is stored. Default `.granted`.
    public var defaultConsent: Consent = .granted

    /// Whether the SDK stores the user's `optIn` or `optOut` choice on the device, where it wins
    /// over `defaultConsent` at the next launch. Default `true`. Set it to `false` when the app's
    /// own consent system keeps the choice and passes it to the SDK on every launch.
    public var persistConsent = true

    /// The defaults.
    public init() {}
}

/// The SDK's own log lines and health reports (Logging). Held by `AnalyticsConfiguration.logging`.
public struct LoggingConfiguration: Sendable {
    /// How much the SDK logs. Default `.warn`, which is silent in a healthy app. `debug` does not
    /// change it.
    public var level: LogLevel = .warn

    /// Where log lines go. Default `nil`: unified logging with subsystem `com.rubicon.analytics`
    /// and category `Rubicon` (iOS Logging 1).
    public var logger: RubiconLogger?

    /// Hears what became of each event: queued, sent or dropped (Logging 4c). Default `nil`. Meant
    /// for QA screens in debug builds and for tests; called on the SDK's queues.
    public var eventObserver: EventObserver?

    /// Whether the SDK sends the automatic `SDK Diagnostics` event, at most once an hour and only
    /// when it dropped events or met problems. Default `true`.
    public var sendDiagnostics = true

    /// The defaults.
    public init() {}
}

/// Requests the SDK sends (Configuration 5). Held by `AnalyticsConfiguration.network`.
public struct NetworkConfiguration: Sendable {
    /// Headers added to every SDK request, for example a gateway token of an on-prem deployment.
    /// Empty by default. A header the SDK sets itself cannot be replaced: `Authorization`,
    /// `Content-Type`, `Content-Encoding`, `Content-Length`, `User-Agent`, `Host`, `If-None-Match`
    /// and any name starting with `X-Rubicon-`, in any letter case. Such a header is a developer
    /// error when `debug` is on, and is ignored otherwise.
    ///
    /// ```swift
    /// config.network.headers = ["X-Gateway-Token": Secrets.gatewayToken]
    /// ```
    public var headers: [String: String] = [:]

    /// The defaults.
    public init() {}
}
