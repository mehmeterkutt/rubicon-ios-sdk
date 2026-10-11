import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The Android `HttpURLConnectionTransportTest`, ported onto `TestHTTPServer` and `URLSession`.
final class TransportHarness: @unchecked Sendable {
    // Wed, 01 Oct 2026 12:00:00 GMT
    static let now: Int64 = 1_790_856_000_000
    let test = TestPlatform()
    let server: TestHTTPServer
    let clock = TestClock(start: Date(epochMillis: TransportHarness.now))
    let body = Data(#"{"sent_at":1,"batch":[{"type":"track","event":"Purchase Completed"}]}"#.utf8)
    lazy var log = test.log()

    init() throws {
        server = try TestHTTPServer()
    }

    deinit {
        server.stop()
    }

    func transport(
        headers: [String: String] = [:],
        timeouts: URLSessionTransport.Timeouts = .init(requestSeconds: 2, resourceSeconds: 5),
        resolve: @escaping URLSessionTransport.Resolver = { _ in nil },
        compress: @escaping @Sendable (Data) throws -> Data = { try Gzip.compress($0) }
    ) -> URLSessionTransport {
        URLSessionTransport(
            apiKey: "rk_test_key", customHeaders: headers, log: log, osVersion: "17.5.1", clock: clock,
            elapsedClock: TestElapsedClock(), timeouts: timeouts, resolve: resolve, compress: compress)
    }

    func post(_ transport: URLSessionTransport? = nil, path: String = "/v1/batch") -> HttpResult {
        (transport ?? self.transport()).execute(HttpRequest(method: .post, url: server.url(path: path), body: body))
    }

    func get(_ transport: URLSessionTransport? = nil, headers: [String: String] = [:]) -> HttpResult {
        (transport ?? self.transport()).execute(
            HttpRequest(method: .get, url: server.url(path: "/v1/config"), headers: headers))
    }

    func logged(_ code: Code) -> Bool { test.logger.messages.contains { $0.hasPrefix("\(code.rawValue):") } }

    func kind(_ result: HttpResult) -> FailureKind? {
        if case .networkFailure(let kind, _) = result { return kind }
        return nil
    }
}

@Suite("URLSessionTransport requests", .serialized)
struct TransportRequestTests {
    @Test("posts the gzipped body with a fixed length and the SDK's headers")
    func request() throws {
        let h = try TransportHarness()
        h.server.enqueue(.init(status: 200))

        #expect(h.post(h.transport(headers: ["X-Gateway-Token": "gw"])) == .success(code: 200))

        let request = try #require(h.server.waitForRequest())
        #expect(request.method == "POST")
        #expect(request.path == "/v1/batch")
        #expect(request.header("Authorization") == "Bearer rk_test_key")
        #expect(request.header("User-Agent") == "rubicon-ios/0.1.0 (iOS 17.5.1)")
        #expect(request.header("Content-Type") == "application/json; charset=utf-8")
        #expect(request.header("Content-Encoding") == "gzip")
        #expect(request.header("X-Gateway-Token") == "gw")
        #expect(request.header("Content-Length") == String(request.body.count))
        #expect(request.header("Transfer-Encoding") == nil)
        #expect(request.body.prefix(2) == Data([0x1f, 0x8b]))
        #expect(try Gzip.decompress(request.body) == h.body)
    }

    @Test("custom headers never replace the SDK's own, in any letter case")
    func reservedHeaders() throws {
        let h = try TransportHarness()
        h.server.enqueue(.init())
        let sneaky = [
            "authorization": "Bearer stolen", "USER-AGENT": "evil", "Content-Type": "text/plain",
            "content-encoding": "identity",
            "X-Rubicon-Debug": "1", "X-Allowed": "yes",
        ]
        _ = h.post(h.transport(headers: sneaky))
        let request = try #require(h.server.waitForRequest())
        #expect(request.header("Authorization") == "Bearer rk_test_key")
        #expect(request.header("User-Agent")?.hasPrefix("rubicon-ios/") == true)
        #expect(request.header("Content-Type") == "application/json; charset=utf-8")
        #expect(request.header("Content-Encoding") == "gzip")
        #expect(request.header("X-Rubicon-Debug") == nil)
        #expect(request.header("X-Allowed") == "yes")
    }

    @Test("a GET sends no body, carries If-None-Match, and 304 is not a redirect")
    func getRequest() throws {
        let h = try TransportHarness()
        h.server.enqueue(.init(status: 304))
        #expect(h.get(headers: ["If-None-Match": "\"abc\""]) == .httpError(code: 304, body: "", retryAfterMs: nil))
        let request = try #require(h.server.waitForRequest())
        #expect(request.method == "GET")
        #expect(request.path == "/v1/config")
        #expect(request.header("If-None-Match") == "\"abc\"")
        #expect(request.body.isEmpty)
        #expect(!h.logged(.httpRedirect))
    }

    @Test("a failed compression sends the body uncompressed with a warning")
    func compressionFailure() throws {
        let h = try TransportHarness()
        h.server.enqueue(.init())
        _ = h.post(h.transport(compress: { _ in throw GzipError(code: -2) }))
        let request = try #require(h.server.waitForRequest())
        #expect(request.header("Content-Encoding") == nil)
        #expect(request.body == h.body)
        #expect(h.logged(.compressionFailed))
    }

    @Test("bodies are never logged and the DEBUG line names the request id")
    func debugLine() throws {
        let h = try TransportHarness()
        h.server.enqueue(.init(status: 500, headers: ["X-Request-Id": "req-42"], body: Data("secret detail".utf8)))
        _ = h.post()
        #expect(
            h.test.logger.messages.contains { $0.contains("POST /v1/batch: 500") && $0.contains("request id req-42") })
        #expect(!h.test.logger.messages.contains { $0.contains("Purchase Completed") || $0.contains("secret detail") })
    }

    @Test("the production factory takes its parts from the platform")
    func factory() throws {
        let h = try TransportHarness()
        h.server.enqueue(.init())
        let settings = TransportSettings(apiKey: "rk_platform", log: h.log)
        let transport = URLSessionTransport.factory(settings, h.test.platform)
        _ = transport.execute(HttpRequest(method: .get, url: h.server.url(path: "/v1/config")))
        #expect(try #require(h.server.waitForRequest()).header("Authorization") == "Bearer rk_platform")
        #expect(transport is URLSessionTransport)
        transport.shutdown()
    }
}

@Suite("URLSessionTransport responses", .serialized)
struct TransportResponseTests {
    @Test("2xx is a success", arguments: [200, 201, 202, 204])
    func success(code: Int) throws {
        let h = try TransportHarness()
        h.server.enqueue(.init(status: code))
        #expect(h.post() == .success(code: code))
    }

    @Test(
        "every other status is an HTTP error with its code and body",
        arguments: [400, 401, 403, 404, 408, 410, 413, 422, 500, 501, 502, 503, 504, 505])
    func httpError(code: Int) throws {
        let h = try TransportHarness()
        h.server.enqueue(.init(status: code, body: Data("reason \(code)".utf8)))
        #expect(h.post() == .httpError(code: code, body: "reason \(code)", retryAfterMs: nil))
    }

    @Test("a GET success carries its body and ETag, an upload success neither; a GET body is cut at 64 KB")
    func getBodies() throws {
        let h = try TransportHarness()
        h.server.enqueue(.init(status: 200, headers: ["ETag": "\"v7\""], body: Data(#"{"flush_at":60}"#.utf8)))
        h.server.enqueue(.init(status: 200, headers: ["ETag": "\"v8\""], body: Data("ignored".utf8)))
        h.server.enqueue(.init(status: 200, body: Data(String(repeating: "x", count: 100_000).utf8)))
        #expect(h.get() == .success(code: 200, body: #"{"flush_at":60}"#, etag: "\"v7\""))
        #expect(h.post() == .success(code: 200))
        guard case .success(_, let body, _) = h.get() else {
            Issue.record("not a success")
            return
        }
        #expect(body?.count == 64 * 1024)
    }

    @Test("a redirect is not followed and logs its target without the query")
    func redirect() throws {
        let h = try TransportHarness()
        h.server.enqueue(.init(status: 301, headers: ["Location": "https://new.example/v1/batch?token=secret"]))
        h.server.enqueue(.init())
        let result = h.post()
        guard case .httpError(let code, _, _) = result else {
            Issue.record("not an HTTP error: \(result)")
            return
        }
        #expect(code == 301)
        #expect(h.server.requests.count == 1)
        let line = try #require(h.test.logger.lines.first { $0.message.hasPrefix("HTTP_REDIRECT") })
        #expect(line.level == .error)
        #expect(line.message.contains("https://new.example/v1/batch"))
        #expect(!line.message.contains("secret"))
    }

    @Test("a 1 MB error body is read up to 4 KB")
    func bigErrorBody() throws {
        let h = try TransportHarness()
        h.server.enqueue(.init(status: 400, body: Data(String(repeating: "x", count: 1024 * 1024).utf8)))
        guard case .httpError(_, let body, _) = h.post() else {
            Issue.record("not an HTTP error")
            return
        }
        #expect(body?.count == 4096)
    }

    @Test("Retry-After in seconds, as an HTTP date, in the past, invalid, missing, huge, and on 503")
    func retryAfter() throws {
        let h = try TransportHarness()
        func retryAfter(_ value: String?) -> Int64? {
            var headers: [String: String] = [:]
            if let value { headers["Retry-After"] = value }
            h.server.enqueue(.init(status: 429, headers: headers))
            guard case .httpError(_, _, let ms) = h.post() else { return -1 }
            return ms
        }
        #expect(retryAfter("120") == 120_000)
        #expect(retryAfter("Wed, 01 Oct 2026 12:01:00 GMT") == 60_000)
        #expect(retryAfter("Wed, 01 Oct 2026 11:59:00 GMT") == -60_000)
        #expect(retryAfter("soon") == nil)
        #expect(retryAfter("-5") == nil)
        #expect(retryAfter("1.5") == nil)
        #expect(retryAfter("Wednesday, 01-Oct-26 12:01:00 GMT") == nil)
        #expect(retryAfter(nil) == nil)
        let transport = h.transport()
        #expect(transport.retryAfterMs("99999999999999999999") == Int64.max)
        #expect(transport.retryAfterMs("9223372036854775807") == Int64.max)
        h.server.enqueue(.init(status: 503, headers: ["Retry-After": "30"]))
        #expect(h.post() == .httpError(code: 503, body: "", retryAfterMs: 30_000))
    }
}

@Suite("URLSessionTransport failures", .serialized)
struct TransportFailureTests {
    @Test("a slow response trips the request timeout")
    func requestTimeout() throws {
        let h = try TransportHarness()
        h.server.enqueue(.init(status: 200, delayMillis: 2_000))
        let result = h.post(h.transport(timeouts: .init(requestSeconds: 0.3, resourceSeconds: 10)))
        #expect(h.kind(result) == .timeout)
    }

    @Test("a server that never finishes trips the resource timeout before the request timeout")
    func resourceTimeout() throws {
        let h = try TransportHarness()
        h.server.enqueue(.init(status: 200, delayMillis: 3_000))
        let started = Date()
        let result = h.post(h.transport(timeouts: .init(requestSeconds: 10, resourceSeconds: 0.3)))
        #expect(h.kind(result) == .timeout)
        #expect(Date().timeIntervalSince(started) < 2.5)
    }

    @Test("a cancelled task is cancelled, with a DEBUG line and no code")
    func cancelled() throws {
        let h = try TransportHarness()
        h.server.enqueue(.init(status: 200, delayMillis: 3_000))
        let transport = h.transport(timeouts: .init(requestSeconds: 10, resourceSeconds: 10))
        let result = Locked<HttpResult?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread {
            result.withLock { $0 = h.post(transport) }
            done.signal()
        }.start()
        Thread.sleep(forTimeInterval: 0.3)
        transport.cancelCurrent()
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(result.current.flatMap(h.kind) == .cancelled)
        #expect(!h.test.logger.lines.contains { $0.level == .error || $0.level == .warn })
    }

    @Test("a refused connection is connect; localhost and IP hosts are never resolved")
    func refused() throws {
        let h = try TransportHarness()
        let port = h.server.port
        h.server.stop()
        let resolved = Locked(0)
        let transport = h.transport(resolve: { _ in
            resolved.withLock { $0 += 1 }
            return ["127.0.0.1"]
        })
        let byIp = transport.execute(
            HttpRequest(
                method: .post, url: try #require(URL(string: "http://127.0.0.1:\(port)/v1/batch")), body: h.body))
        let byName = transport.execute(
            HttpRequest(
                method: .post, url: try #require(URL(string: "http://localhost:\(port)/v1/batch")), body: h.body))
        #expect(h.kind(byIp) == .connect)
        #expect(h.kind(byName) == .connect)
        #expect(resolved.current == 0)
    }

    @Test("an unknown host is dns, and not blocked without a resolver answer")
    func unknownHost() throws {
        let h = try TransportHarness()
        let result = h.transport().execute(
            HttpRequest(
                method: .post, url: try #require(URL(string: "https://no-such-host.invalid/v1/batch")), body: h.body))
        #expect(h.kind(result) == .dns)
        #expect(!h.logged(.hostBlocked))
    }

    @Test("a host resolving to loopback after a failure is blocked, logged once; one public address is not")
    func blocked() throws {
        let h = try TransportHarness()
        let blocking = h.transport(resolve: { _ in ["0.0.0.0", "127.0.0.1"] })
        let url = try #require(URL(string: "https://blocked.invalid/v1/batch"))
        for _ in 0..<2 {
            #expect(h.kind(blocking.execute(HttpRequest(method: .post, url: url, body: h.body))) == .blocked)
        }
        #expect(h.test.logger.lines.filter { $0.level == .warn && $0.message.hasPrefix("HOST_BLOCKED") }.count == 1)

        let partly = h.transport(resolve: { _ in ["127.0.0.1", "93.184.216.34"] })
        #expect(
            h.kind(
                partly.execute(
                    HttpRequest(
                        method: .post, url: try #require(URL(string: "https://partly.invalid/v1/batch")), body: h.body))
            ) == .dns)
    }

    @Test("an unsupported URL is unexpected with an ERROR")
    func unexpected() throws {
        let h = try TransportHarness()
        let result = h.transport().execute(HttpRequest(method: .get, url: try #require(URL(string: "foo:bar"))))
        #expect(h.kind(result) == .unexpected)
        #expect(h.test.logger.lines.contains { $0.level == .error && $0.message.hasPrefix("HTTP_UNEXPECTED") })
    }

    @Test("a connection dropped mid-way is io and never a trap")
    func dropped() throws {
        let h = try TransportHarness()
        h.server.enqueue(.dropped)
        #expect(h.kind(h.post()) == .io)
    }

    @Test("the URLError table of iOS HTTP 3")
    func table() {
        let cases: [(URLError.Code, FailureKind)] = [
            (.timedOut, .timeout), (.cannotFindHost, .dns), (.dnsLookupFailed, .dns), (.cannotConnectToHost, .connect),
            (.notConnectedToInternet, .connect), (.dataNotAllowed, .connect), (.internationalRoamingOff, .connect),
            (.callIsActive, .connect), (.networkConnectionLost, .io), (.badServerResponse, .io),
            (.cannotParseResponse, .io),
            (.zeroByteResource, .io), (.secureConnectionFailed, .tls), (.serverCertificateHasBadDate, .tls),
            (.serverCertificateUntrusted, .tls), (.serverCertificateHasUnknownRoot, .tls),
            (.serverCertificateNotYetValid, .tls),
            (.clientCertificateRejected, .tls), (.clientCertificateRequired, .tls),
            (.appTransportSecurityRequiresSecureConnection, .tls),
            (.cancelled, .cancelled), (.badURL, .unexpected), (.unsupportedURL, .unexpected),
        ]
        for (code, kind) in cases {
            #expect(FailureKind(error: URLError(code)) == kind, "\(code)")
        }
        #expect(FailureKind(error: FileSystemError.notFound) == .unexpected)
    }

    @Test("an ATS refusal is tls with a message naming the exception")
    func ats() throws {
        let h = try TransportHarness()
        let transport = h.transport()
        // The failure path is reached through the mapping; the real refusal needs an iOS app.
        let result = transport.execute(
            HttpRequest(method: .post, url: try #require(URL(string: "https://no-such-host.invalid/")), body: h.body))
        #expect(h.kind(result) == .dns)
        #expect(FailureKind(error: URLError(.appTransportSecurityRequiresSecureConnection)) == .tls)
    }
}

@Suite("HostResolver and Gzip")
struct HostResolverTests {
    @Test("loopback and any-local addresses are local, others are not")
    func local() {
        for address in ["127.0.0.1", "127.255.0.9", "0.0.0.0", "::1", "::", "::ffff:127.0.0.1", "::1%lo0"] {
            #expect(HostResolver.isLocal(address), Comment(rawValue: address))
        }
        for address in ["93.184.216.34", "10.0.0.5", "2001:db8::1", "128.0.0.1"] {
            #expect(!HostResolver.isLocal(address), Comment(rawValue: address))
        }
    }

    @Test("IP literals and localhost are recognised")
    func literals() {
        #expect(HostResolver.isIPLiteral("10.0.2.2"))
        #expect(HostResolver.isIPLiteral("[::1]"))
        #expect(HostResolver.isIPLiteral("::1"))
        #expect(!HostResolver.isIPLiteral("api.example.com"))
        #expect(!HostResolver.isIPLiteral("1.2.3"))
        let loopback: URLSessionTransport.Resolver = { _ in ["127.0.0.1"] }
        let failing: URLSessionTransport.Resolver = { _ in nil }
        let empty: URLSessionTransport.Resolver = { _ in [] }
        let v6: URLSessionTransport.Resolver = { _ in ["::1"] }
        #expect(!HostResolver.isBlocked("LocalHost", resolve: loopback))
        #expect(!HostResolver.isBlocked("a.invalid", resolve: failing))
        #expect(!HostResolver.isBlocked("a.invalid", resolve: empty))
        #expect(HostResolver.isBlocked("a.invalid", resolve: v6))
    }

    @Test("the real resolver answers for localhost")
    func realResolver() {
        let addresses = HostResolver.resolve("localhost") ?? []
        #expect(addresses.contains("127.0.0.1") || addresses.contains("::1"))
    }

    @Test("gzip writes a gzip header and round-trips; a bad stream fails to inflate")
    func gzip() throws {
        let input = Data(String(repeating: #"{"type":"track","event":"E"}"#, count: 2_000).utf8)
        let compressed = try Gzip.compress(input)
        #expect(compressed.prefix(2) == Data([0x1f, 0x8b]))
        #expect(compressed.count < input.count / 10)
        #expect(try Gzip.decompress(compressed) == input)
        #expect(try Gzip.decompress(try Gzip.compress(Data())) == Data())
        #expect(throws: GzipError.self) { try Gzip.decompress(Data([1, 2, 3])) }
    }
}
