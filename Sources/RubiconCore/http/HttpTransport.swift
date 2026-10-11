import Foundation

/// Sends one request, once, and reports what happened (HTTP 1, 4, 6). Never throws: every failure
/// is an `HttpResult`. The implementation adds compression and the SDK's own headers (HTTP 2, 5).
package protocol HttpTransport: Sendable {
    func execute(_ request: HttpRequest) -> HttpResult

    /// Ends the transport's session when the instance shuts down (`invalidateAndCancel`).
    func shutdown()
}

/// A request to the configured host; `body` is the uncompressed JSON, `nil` for a GET.
package struct HttpRequest: Sendable, Equatable {
    package enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    package var method: Method
    package var url: URL
    package var headers: [String: String]
    package var body: Data?

    package init(method: Method, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

extension HttpRequest: CustomStringConvertible {
    /// Method, URL and body size, never the body or the headers.
    package var description: String {
        "HttpRequest(\(method.rawValue) \(url.absoluteString), body=\(body?.count ?? 0) bytes)"
    }
}

/// Why no HTTP status was received (iOS HTTP 3). The groups are Retry's (Retry 1): `timeout`,
/// `dns`, `connect`, `io` and `cancelled` are transient; `tls`, `blocked` and `unexpected` are
/// configuration problems. `cancelled` exists only on iOS: the SDK's own cancellation when the
/// background time expires (iOS Queue 2); it is never on the wire.
package enum FailureKind: String, Sendable, CaseIterable {
    case timeout
    case dns
    case connect
    case tls
    case io
    case blocked
    case cancelled
    case unexpected
}

/// The outcome of one attempt (HTTP 4). The transport reports; the retry policy decides.
package enum HttpResult: Sendable, Equatable {
    /// A 2xx status. The body of an upload's success is never read (Retry 4); a GET carries its
    /// body, at most 64 KB, and its `ETag` for the remote configuration (Configuration 1).
    case success(code: Int, body: String? = nil, etag: String? = nil)

    /// Any other status, with at most 4 KB of the error body and `Retry-After` in milliseconds.
    case httpError(code: Int, body: String?, retryAfterMs: Int64?)

    /// No HTTP status was received. The cause is kept for the DEBUG line; two failures are equal
    /// when their kind and the cause's description are.
    case networkFailure(kind: FailureKind, cause: any Error)

    package static func == (lhs: HttpResult, rhs: HttpResult) -> Bool {
        switch (lhs, rhs) {
        case (.success(let a, let b, let c), .success(let d, let e, let f)):
            return a == d && b == e && c == f
        case (.httpError(let a, let b, let c), .httpError(let d, let e, let f)):
            return a == d && b == e && c == f
        case (.networkFailure(let a, let b), .networkFailure(let c, let d)):
            return a == c && String(describing: b) == String(describing: d)
        default:
            return false
        }
    }
}

extension HttpResult: CustomStringConvertible {
    /// Status and kind, never a body.
    package var description: String {
        switch self {
        case .success(let code, _, _): return "Success(\(code))"
        case .httpError(let code, _, let retryAfterMs):
            return "HttpError(\(code), retryAfterMs=\(retryAfterMs.map(String.init) ?? "nil"))"
        case .networkFailure(let kind, let cause): return "NetworkFailure(\(kind), \(cause))"
        }
    }
}

/// What a transport takes from the validated configuration and the instance: the API key for
/// `Authorization` and `network.headers` with the reserved ones already removed. Step 2.2 adds the
/// instance's log.
package struct TransportSettings: Sendable {
    package var apiKey: String
    package var headers: [String: String]

    package init(apiKey: String, headers: [String: String] = [:]) {
        self.apiKey = apiKey
        self.headers = headers
    }
}

extension TransportSettings: CustomStringConvertible {
    /// Never the key or the header values.
    package var description: String {
        "TransportSettings(\(headers.count) custom headers)"
    }
}

/// Builds the instance's transport once the configuration is validated (Configuration 5, Android
/// log 5.1): the transport needs the key and the headers, which exist only after validation.
/// Production uses the `URLSession` transport of step 5.1; tests return a fake.
package typealias HttpTransportFactory = @Sendable (TransportSettings, Platform) -> any HttpTransport
