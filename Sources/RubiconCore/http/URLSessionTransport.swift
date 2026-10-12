import Foundation

/// The `HttpTransport` of HTTP 1 to 6 on `URLSession` (iOS HTTP 1 to 4), with no dependency.
///
/// - One `URLSession` per instance from `.ephemeral`: request timeout 20 s (the longest silence),
///   resource timeout 45 s (the whole request, in place of the Android watchdog), one connection
///   per host, no connectivity wait, no cookies, no cache. The transport is the task delegate and
///   refuses redirects, so a 3xx is delivered as the response.
/// - One attempt, never a retry. Never throws: every outcome is an `HttpResult`. The uploader
///   queue waits for the completion on a semaphore bounded by the resource timeout; the background
///   expiration cancels the task from another thread (`cancelCurrent`), which completes it at once
///   with `cancelled` (iOS Queue 2).
/// - The body is gzipped in memory through `zlib` and sent with `Content-Length` (HTTP 2). If
///   compression fails, it is sent uncompressed with a WARN.
/// - Headers (HTTP 5): `network.headers` first, then the SDK's own, which therefore always win:
///   `Authorization: Bearer`, `User-Agent`, `Content-Type`, `Content-Encoding`. A 3xx other than 304
///   logs an ERROR naming the target without its query.
/// - `URLError` codes become `FailureKind`s by the table of iOS HTTP 3. After a `connect` or `dns`
///   failure the host is resolved once with `getaddrinfo`: if every address is loopback or
///   any-local, the result is `blocked` (HTTP 6).
/// - Bodies are never logged; at most 4 KB of an error body is read, for the retry layer.
package final class URLSessionTransport: NSObject, HttpTransport, URLSessionTaskDelegate, @unchecked Sendable {
    package struct Timeouts: Sendable {
        /// The longest silence between bytes, `timeoutIntervalForRequest`.
        package var requestSeconds: TimeInterval
        /// The whole request, `timeoutIntervalForResource`.
        package var resourceSeconds: TimeInterval

        package init(requestSeconds: TimeInterval, resourceSeconds: TimeInterval) {
            self.requestSeconds = requestSeconds
            self.resourceSeconds = resourceSeconds
        }

        package static let `default` = Timeouts(requestSeconds: 20, resourceSeconds: 45)
    }

    /// The addresses a host resolves to, as text (`127.0.0.1`, `::1`); `nil` when resolution failed.
    package typealias Resolver = @Sendable (String) -> [String]?

    private static let maxErrorBody = 4 * 1024
    private static let maxGetBody = 64 * 1024

    private let apiKey: String
    private let customHeaders: [String: String]
    private let log: Log
    private let osVersion: String
    private let clock: any Clock
    private let elapsedClock: any ElapsedClock
    private let resolve: Resolver
    private let compress: @Sendable (Data) throws -> Data
    private let session: URLSession
    // The task in flight, for `cancelCurrent`; guarded by `current`.
    // The request in flight and whether `shutdown` ran. A task is created and recorded under the
    // lock and never after `stopped`: a task created in an invalidated session is an `NSException`,
    // which nothing in Swift can catch (seen once in CI, plan section 15).
    private let state = Locked<(task: URLSessionTask?, stopped: Bool)>((nil, false))

    /// The production factory: the transport of `Platform.transportFactory` on iOS.
    package static let factory: HttpTransportFactory = { settings, platform in
        URLSessionTransport(settings: settings, platform: platform)
    }

    package convenience init(settings: TransportSettings, platform: Platform) {
        self.init(
            apiKey: settings.apiKey, customHeaders: settings.headers, log: settings.log,
            osVersion: platform.processFacts.osVersion, clock: platform.clock, elapsedClock: platform.elapsedClock)
    }

    package init(
        apiKey: String, customHeaders: [String: String], log: Log, osVersion: String, clock: any Clock,
        elapsedClock: any ElapsedClock, timeouts: Timeouts = .default,
        resolve: @escaping Resolver = HostResolver.resolve,
        compress: @escaping @Sendable (Data) throws -> Data = { try Gzip.compress($0) }
    ) {
        self.apiKey = apiKey
        // Reserved names are already removed by validation; dropping them again keeps the rule here too.
        self.customHeaders = customHeaders.filter { !Headers.isReserved($0.key) }
        self.log = log
        self.osVersion = osVersion
        self.clock = clock
        self.elapsedClock = elapsedClock
        self.resolve = resolve
        self.compress = compress
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeouts.requestSeconds
        configuration.timeoutIntervalForResource = timeouts.resourceSeconds
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateHolder = RedirectRefusingDelegate()
        session = URLSession(configuration: configuration, delegate: delegateHolder, delegateQueue: nil)
        super.init()
    }

    private var userAgent: String { "rubicon-ios/\(SDKVersion.current) (iOS \(osVersion))" }

    package func execute(_ request: HttpRequest) -> HttpResult {
        let started = elapsedClock.elapsedMillis()
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        for (name, value) in customHeaders { urlRequest.setValue(value, forHTTPHeaderField: name) }
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: Headers.authorization)
        urlRequest.setValue(userAgent, forHTTPHeaderField: Headers.userAgent)
        var sentBytes = 0
        var payload: Data?
        if let body = request.body {
            let compressed = compressed(body)
            sentBytes = compressed.bytes.count
            payload = compressed.bytes
            urlRequest.setValue(Headers.json, forHTTPHeaderField: Headers.contentType)
            if compressed.gzipped { urlRequest.setValue(Headers.gzip, forHTTPHeaderField: Headers.contentEncoding) }
            urlRequest.setValue(String(compressed.bytes.count), forHTTPHeaderField: Headers.contentLength)
        }
        let done = DispatchSemaphore(value: 0)
        let outcome = Locked<(Data?, URLResponse?, (any Error)?)>((nil, nil, nil))
        let completion: @Sendable (Data?, URLResponse?, (any Error)?) -> Void = { data, response, error in
            outcome.withLock { $0 = (data, response, error) }
            done.signal()
        }
        let task: URLSessionTask? = state.withLock { s in
            if s.stopped { return nil }
            let task: URLSessionTask
            if let payload {
                task = session.uploadTask(with: urlRequest, from: payload, completionHandler: completion)
            } else {
                task = session.dataTask(with: urlRequest, completionHandler: completion)
            }
            s.task = task
            return task
        }
        let result: HttpResult
        var response: URLResponse?
        if let task {
            task.resume()
            // The resource timeout ends the task first; the margin only guards against a stuck stack.
            _ = done.wait(timeout: .now() + session.configuration.timeoutIntervalForResource + 30)
            state.withLock { $0.task = nil }
            let (data, received, error) = outcome.current
            response = received
            if let error {
                result = failure(error, request: request)
            } else if let http = received as? HTTPURLResponse {
                result = receive(http, data: data ?? Data(), request: request)
            } else {
                result = failure(URLError(.badServerResponse), request: request)
            }
        } else {
            // After `shutdown`: nothing is sent, and the caller sees the same result as a cancelled task.
            result = failure(URLError(.cancelled), request: request)
        }
        let elapsed = elapsedClock.elapsedMillis() - started
        let requestId =
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: Headers.requestId).map { " (request id \($0))" }
            ?? ""
        log.debug {
            "\(request.method.rawValue) \(request.url.path): \(result.summary) in \(elapsed) ms, \(sentBytes) bytes sent\(requestId)"
        }
        return result
    }

    /// Cancels the request in flight, if any, from any thread; it completes with `cancelled`.
    package func cancelCurrent() {
        state.current.task?.cancel()
    }

    /// Invalidates the session; a request in flight completes with `cancelled`, a later `execute`
    /// returns `cancelled` without a task.
    package func shutdown() {
        state.withLock { $0.stopped = true }
        session.invalidateAndCancel()
    }

    // MARK: - Sending

    private func compressed(_ body: Data) -> (bytes: Data, gzipped: Bool) {
        do {
            return (try compress(body), true)
        } catch {
            log.warn(.compressionFailed, error) { "Could not compress a request; it is sent uncompressed" }
            return (body, false)
        }
    }

    // MARK: - Receiving

    private func receive(_ response: HTTPURLResponse, data: Data, request: HttpRequest) -> HttpResult {
        let code = response.statusCode
        if (200..<300).contains(code) {
            if request.method == .get {
                return .success(
                    code: code, body: Self.text(data.prefix(Self.maxGetBody)),
                    etag: response.value(forHTTPHeaderField: Headers.etag))
            }
            // The body of an upload's success is never used.
            return .success(code: code)
        }
        let body = Self.text(data.prefix(Self.maxErrorBody))
        if (300..<400).contains(code) && code != 304 {
            let target =
                response.value(forHTTPHeaderField: Headers.location).map(Self.withoutQuery) ?? "an unknown location"
            log.error(.httpRedirect) {
                "\(request.url.host ?? "the host") redirects (\(code)) to \(target); set host to the final URL"
            }
        }
        return .httpError(
            code: code, body: body, retryAfterMs: retryAfterMs(response.value(forHTTPHeaderField: Headers.retryAfter)))
    }

    /// `Retry-After` in milliseconds from now: seconds or an HTTP date (HTTP 4); `nil` if absent or
    /// invalid (Android log 5.1: whole seconds only, a huge number saturates, a past date is negative).
    package func retryAfterMs(_ value: String?) -> Int64? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.allSatisfy({ ("0"..."9").contains($0) }) {
            guard let seconds = Int64(text) else { return Int64.max }
            return seconds > Int64.max / 1000 ? Int64.max : seconds * 1000
        }
        return HttpDates.parse(text).map { $0 - clock.now().epochMillis }
    }

    // MARK: - Failures

    private func failure(_ error: any Error, request: HttpRequest) -> HttpResult {
        var kind = FailureKind(error: error)
        let host = request.url.host ?? ""
        if (kind == .connect || kind == .dns) && !host.isEmpty && HostResolver.isBlocked(host, resolve: resolve) {
            kind = .blocked
        }
        switch kind {
        case .blocked:
            log.warn(.hostBlocked) {
                "\(host) resolves to a local address, as content blockers and private DNS do; uploads wait"
            }
        case .unexpected:
            log.error(.httpUnexpected, error) { "The HTTP stack failed with \(Self.name(of: error))" }
        case .tls where (error as? URLError)?.code == .appTransportSecurityRequiresSecureConnection:
            log.error(.tlsFailed, error) {
                "\(host) uses http and iOS requires https; add an App Transport Security exception for it or use https"
            }
        case .tls:
            log.error(.tlsFailed, error) { "The TLS handshake with \(host) failed (\(Self.name(of: error)))" }
        default:
            log.debug { "\(request.method.rawValue) \(request.url.path): \(kind) (\(Self.name(of: error)))" }
        }
        return .networkFailure(kind: kind, cause: error)
    }

    private static func name(of error: any Error) -> String {
        if let urlError = error as? URLError { return "URLError \(urlError.code.rawValue)" }
        return String(describing: type(of: error))
    }

    /// A redirect target without query or fragment, which may carry personal data (Logging 4a).
    private static func withoutQuery(_ location: String) -> String {
        String(location.prefix { $0 != "?" && $0 != "#" })
    }

    private static func text(_ data: Data) -> String {
        // Lenient: an invalid byte becomes U+FFFD; the body is for logs and the retry layer only.
        String(decoding: data, as: UTF8.self)
    }

    /// The delegate that refuses redirects: a 3xx is delivered as the response (iOS HTTP 1).
    private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

extension FailureKind {
    /// The table of iOS HTTP 3, from a `URLError.Code`; anything outside `NSURLErrorDomain` is `unexpected`.
    package init(error: any Error) {
        guard let urlError = error as? URLError else {
            self = .unexpected
            return
        }
        switch urlError.code {
        case .timedOut:
            self = .timeout
        case .cannotFindHost, .dnsLookupFailed:
            self = .dns
        case .cannotConnectToHost, .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            self = .connect
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            self = .tls
        case .cancelled:
            self = .cancelled
        case .badURL, .unsupportedURL:
            self = .unexpected
        default:
            self = .io
        }
    }
}

extension HttpResult {
    /// The status or kind for the DEBUG line.
    fileprivate var summary: String {
        switch self {
        case .success(let code, _, _): return "\(code)"
        case .httpError(let code, _, _): return "\(code)"
        case .networkFailure(let kind, _): return "\(kind)"
        }
    }
}

/// The blocked-host check of HTTP 6 over `getaddrinfo` (iOS HTTP 3): POSIX, synchronous, on the
/// already blocking uploader queue.
package enum HostResolver {
    /// Every address `host` resolves to, as text; `nil` when resolution failed.
    package static let resolve: URLSessionTransport.Resolver = { host in
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                == 0
            {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                addresses.append(String(decoding: bytes, as: UTF8.self))
            }
            cursor = info.pointee.ai_next
        }
        return addresses
    }

    /// Every address is loopback or any-local (`127.0.0.0/8`, `::1`, `0.0.0.0`, `::`); skipped for
    /// `localhost` and IP literals (Android log 5.1).
    package static func isBlocked(_ host: String, resolve: URLSessionTransport.Resolver) -> Bool {
        if host.lowercased() == "localhost" || isIPLiteral(host) { return false }
        guard let addresses = resolve(host), !addresses.isEmpty else { return false }
        return addresses.allSatisfy(isLocal)
    }

    package static func isIPLiteral(_ host: String) -> Bool {
        if host.hasPrefix("[") || host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4
            && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { ("0"..."9").contains($0) } }
    }

    package static func isLocal(_ address: String) -> Bool {
        let text = address.split(separator: "%").first.map(String.init) ?? address
        if text == "0.0.0.0" || text == "::" || text == "::1" || text.lowercased() == "::ffff:127.0.0.1" { return true }
        if text.hasPrefix("127.") { return true }
        return false
    }
}
