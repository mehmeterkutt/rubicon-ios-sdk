import Foundation

/// Validates an `AnalyticsConfiguration` and takes its snapshot (Configuration 3, iOS Configuration
/// 3). Validation itself never traps: it returns the snapshot, or `nil` for an unrecoverable
/// configuration, and the problems it found. `Result.report` then raises developer errors in debug
/// and logs in both modes.
package enum ConfigValidator {
    package static let flushAtBounds: ClosedRange<Int64> = 1...100
    package static let flushIntervalMsBounds: ClosedRange<Int64> = 1_000...600_000
    package static let backgroundTimeoutMsBounds: ClosedRange<Int64> = 10_000...7_200_000

    package struct Issue: Sendable, Equatable {
        package var code: Code
        package var level: LogLevel
        package var isDeveloperError: Bool
        package var message: String
    }

    package struct Result: Sendable {
        /// `nil` when the SDK must not start: a blank key or an invalid host.
        package var snapshot: ConfigSnapshot?
        package var issues: [Issue]

        /// Logs the issues with their codes and, when `debug` is on, reports each developer error
        /// first (iOS Configuration 2).
        package func report(debug: Bool, log: Log) {
            for issue in issues {
                if debug && issue.isDeveloperError { log.developerError(issue.message) }
                switch issue.level {
                case .error: log.error(issue.code) { issue.message }
                default: log.warn(issue.code) { issue.message }
                }
            }
        }
    }

    package static func validate(_ config: AnalyticsConfiguration) -> Result {
        var issues: [Issue] = []

        let apiKeyValid = !config.apiKey.allSatisfy { $0.isWhitespace }
        if !apiKeyValid {
            issues.append(
                Issue(
                    code: .invalidApiKey, level: .error, isDeveloperError: true,
                    message: "The API key is blank; the SDK does nothing."))
        }
        let host = Hosts.normalize(config.host)
        let hostURL = host.flatMap(Hosts.url)
        if host == nil || hostURL == nil {
            issues.append(
                Issue(
                    code: .invalidHost, level: .error, isDeveloperError: true,
                    message: "host \"\(config.host)\" is not an http or https base URL; the SDK does nothing."))
        } else if let host, Hosts.isCleartext(host) {
            issues.append(
                Issue(
                    code: .cleartextHost, level: .warn, isDeveloperError: false,
                    message:
                        "host \"\(host)\" uses http://; events are sent unencrypted, and iOS refuses the connection unless the app declares an App Transport Security exception."
                ))
        }

        let flushAt = clamp("flush.at", Int64(config.flush.at), flushAtBounds, &issues)
        let flushIntervalMs = clamp("flush.intervalMs", config.flush.intervalMs, flushIntervalMsBounds, &issues)
        let backgroundTimeoutMs = clamp(
            "session.backgroundTimeoutMs", config.session.backgroundTimeoutMs, backgroundTimeoutMsBounds, &issues)
        let headers = allowedHeaders(config.network.headers, &issues)

        var snapshot: ConfigSnapshot?
        if apiKeyValid, let host, let hostURL {
            snapshot = ConfigSnapshot(
                apiKey: config.apiKey, host: host, hostURL: hostURL, debug: config.debug, flushAt: Int(flushAt),
                flushIntervalMs: flushIntervalMs, immediateEvents: config.flush.immediateEvents,
                sessionBackgroundTimeoutMs: backgroundTimeoutMs, autocapture: config.autocapture.enabled,
                disabledFields: config.context.disabledFields, defaultConsent: config.privacy.defaultConsent,
                persistConsent: config.privacy.persistConsent, logLevel: config.logging.level,
                logger: config.logging.logger, sendDiagnostics: config.logging.sendDiagnostics, headers: headers)
        }
        return Result(snapshot: snapshot, issues: issues)
    }

    private static func clamp(_ name: String, _ value: Int64, _ bounds: ClosedRange<Int64>, _ issues: inout [Issue])
        -> Int64
    {
        if bounds.contains(value) { return value }
        let clamped = min(max(value, bounds.lowerBound), bounds.upperBound)
        issues.append(
            Issue(
                code: .settingOutOfBounds, level: .warn, isDeveloperError: true,
                message:
                    "\(name) is \(value), outside \(bounds.lowerBound) to \(bounds.upperBound); \(clamped) is used."))
        return clamped
    }

    // Header names are logged, never values (Logging 4a).
    private static func allowedHeaders(_ headers: [String: String], _ issues: inout [Issue]) -> [String: String] {
        var allowed: [String: String] = [:]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            if Headers.isReserved(name) {
                issues.append(
                    Issue(
                        code: .reservedHeader, level: .warn, isDeveloperError: true,
                        message: "network.headers: \"\(name)\" is set by the SDK and cannot be replaced; it is ignored."
                    ))
            } else {
                allowed[name] = value
            }
        }
        return allowed
    }
}
