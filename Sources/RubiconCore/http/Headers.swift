import Foundation

/// The header names of the SDK's requests (HTTP 5, Configuration 5).
package enum Headers {
    package static let authorization = "Authorization"
    package static let userAgent = "User-Agent"
    package static let contentType = "Content-Type"
    package static let contentEncoding = "Content-Encoding"
    package static let contentLength = "Content-Length"
    package static let ifNoneMatch = "If-None-Match"
    package static let retryAfter = "Retry-After"
    package static let location = "Location"
    package static let etag = "ETag"
    /// Pending backend agreement (HTTP 4): a request id the server may return, for the DEBUG line.
    package static let requestId = "X-Request-Id"

    package static let json = "application/json; charset=utf-8"
    package static let gzip = "gzip"

    private static let reserved: Set<String> = [
        "authorization", "content-type", "content-encoding", "content-length", "user-agent", "host", "if-none-match",
    ]
    private static let reservedPrefix = "x-rubicon-"

    /// Whether `network.headers` may not set `name`: the SDK sets it itself; any letter case.
    package static func isReserved(_ name: String) -> Bool {
        let lower = name.lowercased()
        return reserved.contains(lower) || lower.hasPrefix(reservedPrefix)
    }
}
