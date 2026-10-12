import Foundation
import RubiconCore

/// Sends a `Network Request` event for each call to the hosts you choose (Lifecycle 1, 6; Privacy
/// 5c; iOS Lifecycle 5). Forward two callbacks of your own `URLSession` delegate to it, or Alamofire's
/// `EventMonitor` equivalents:
///
/// ```swift
/// let observer = RubiconNetworkObserver(analytics: analytics, hosts: ["api.shop.com", "*.cdn.shop.com"])
///
/// func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
///     observer.urlSession(session, task: task, didFinishCollecting: metrics)
/// }
/// func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
///     observer.urlSession(session, task: task, didCompleteWithError: error)
/// }
/// ```
///
/// - **Hosts**: an exact host name (`api.shop.com`) or a leading wildcard (`*.shop.com`, every
///   subdomain of `shop.com` but not `shop.com` itself), ignoring case. Nothing else is captured. An
///   invalid pattern (a scheme, path, port, or a wildcard such as `*.com`) is a developer error when
///   `debug` is on and is ignored with a warning otherwise.
/// - **Sent**: `method`, `url` and `path` without query or fragment, `host`, `status_code` (absent
///   when the call failed), `error` (a short type such as `timeout`, never a message), `duration_ms`
///   from the task's metrics, `request_bytes` and `response_bytes` when known.
/// - **Never sent**: headers, bodies, query parameters, fragments. With `maskPathIds` (the default),
///   path segments that are all digits, a UUID or hexadecimal longer than 16 characters become `:id`.
/// - The observer never touches the task or its response, never traps, and does nothing when the
///   user opted out, when `networkRequests` is off (a remote switch-off applies at once), for the
///   SDK's own host, and when `analytics` is not the SDK's instance, for example a test double. A
///   session without a delegate (`URLSession.shared` with completion handlers) cannot be observed.
///
/// Thread safety: metrics are kept per task behind a lock until the task completes; the delegate
/// calls arrive on the app's delegate queue, and the rest of the state is immutable.
public final class RubiconNetworkObserver: @unchecked Sendable {
    private let capture: (any AutomaticCapture)?
    private let patterns: HostPatterns
    private let maskPathIds: Bool
    private let pending = Locked<[ObjectIdentifier: URLSessionTaskMetrics]>([:])

    /// - Parameters:
    ///   - analytics: the instance returned by `RubiconAnalytics.make(configuration:)`.
    ///   - hosts: the hosts to capture.
    ///   - maskPathIds: whether ids in paths are replaced by `:id`.
    public init(analytics: any Analytics, hosts: Set<String>, maskPathIds: Bool = true) {
        let capture = analytics as? AutomaticCapture
        self.capture = capture
        self.maskPathIds = maskPathIds
        patterns = HostPatterns.parse(hosts, debug: capture?.debug ?? false, log: capture?.log)
    }

    /// Keeps the metrics until the task completes; forward `urlSession(_:task:didFinishCollecting:)`.
    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard captures(task) else { return }
        pending.withLock { $0[ObjectIdentifier(task)] = metrics }
    }

    /// Records the call; forward `urlSession(_:task:didCompleteWithError:)`.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let metrics = pending.withLock { $0.removeValue(forKey: ObjectIdentifier(task)) }
        guard let capture, captures(task), let url = task.originalRequest?.url else { return }
        let transaction = metrics?.transactionMetrics.last
        let duration = metrics.map { Int64(($0.taskInterval.duration * 1000).rounded()) } ?? 0
        let properties = NetworkRequestProperties.build(
            method: task.originalRequest?.httpMethod, url: url,
            statusCode: (task.response as? HTTPURLResponse)?.statusCode,
            error: error.map(NetworkErrors.name(for:)), durationMs: max(0, duration),
            requestBytes: transaction?.countOfRequestBodyBytesSent,
            responseBytes: transaction?.countOfResponseBodyBytesReceived,
            maskPathIds: maskPathIds)
        capture.track(gate: .networkRequests, name: NetworkRequestProperties.eventName, properties: properties)
    }

    private func captures(_ task: URLSessionTask) -> Bool {
        guard let capture, capture.capturesNetworkRequests, let host = task.originalRequest?.url?.host else {
            return false
        }
        return host.caseInsensitiveCompare(capture.sdkHost) != .orderedSame && patterns.matches(host)
    }
}
