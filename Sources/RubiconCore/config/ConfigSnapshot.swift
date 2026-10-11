import Foundation

/// The validated copy of an `AnalyticsConfiguration` that the SDK reads (Configuration 4, iOS
/// Configuration 1). Taken once by the factory; later changes to the caller's value never reach
/// it. Numbers are within their bounds, the host is normalized and parsed, and reserved headers are
/// removed.
package struct ConfigSnapshot: Sendable {
    package var apiKey: String
    package var host: String
    package var hostURL: URL
    package var debug: Bool
    package var beforeSend: [BeforeSend]
    package var flushAt: Int
    package var flushIntervalMs: Int64
    package var immediateEvents: Set<String>
    package var sessionBackgroundTimeoutMs: Int64
    package var autocapture: Set<Autocapture>
    package var disabledFields: Set<ContextField>
    package var defaultConsent: Consent
    package var persistConsent: Bool
    package var logLevel: LogLevel
    package var logger: RubiconLogger?
    package var eventObserver: EventObserver?
    package var sendDiagnostics: Bool
    package var headers: [String: String]

    package var batchURL: URL { hostURL.appendingPathComponent("v1/batch") }
    package var configURL: URL { hostURL.appendingPathComponent("v1/config") }
}

extension ConfigSnapshot: CustomStringConvertible {
    /// Never the API key or header values (Logging 4a).
    package var description: String { "ConfigSnapshot(host: \(host), debug: \(debug))" }
}
