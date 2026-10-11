import Foundation

/// The five groups of Retry 1, asked of every upload result: is the problem in this batch or
/// somewhere else? Only `badBatch` deletes a batch the server did not accept. iOS adds
/// `interrupted` for the SDK's own cancellation (iOS Retry 2).
package enum RetryGroup: Sendable, Equatable {
    /// A. 2xx: delete the batch.
    case success
    /// B. Network failures, 408, most 5xx, 1xx and non-standard codes: keep, back off.
    case transient
    /// C. 429, or 503 with `Retry-After`: keep, pause everything.
    case throttle
    /// D. 400, 422 and other 4xx: delete, counted as `rejected`.
    case badBatch
    /// E. Configuration or environment: keep, pause an hour, ERROR once.
    case config
    /// The background time ran out and the SDK cancelled its own request: keep, no wait, no step.
    case interrupted

    /// One `switch` over the result (Retry 1, 4; iOS HTTP 3).
    package static func of(_ result: HttpResult) -> RetryGroup {
        switch result {
        case .success:
            return .success
        case .networkFailure(let kind, _):
            switch kind {
            case .timeout, .connect, .io, .dns: return .transient
            case .tls, .blocked, .unexpected: return .config
            case .cancelled: return .interrupted
            }
        case .httpError(let code, _, let retryAfterMs):
            return ofStatus(code, hasRetryAfter: retryAfterMs != nil)
        }
    }

    private static func ofStatus(_ code: Int, hasRetryAfter: Bool) -> RetryGroup {
        switch code {
        case 200..<300: return .success
        case 429: return .throttle
        case 503: return hasRetryAfter ? .throttle : .transient
        case 401, 403, 404, 410, 413, 501, 505: return .config
        case 300..<400: return .config
        case 408: return .transient
        case 400..<500: return .badBatch
        case 500..<600: return .transient
        default: return .transient  // 1xx and non-standard codes
        }
    }
}
