import Foundation
import RubiconTesting

@testable import RubiconCore

/// The real core on macOS (plan section 5, component integration): real files under a temporary
/// directory, the real `URLSession` transport against `TestHTTPServer`, the real dispatch queues and
/// clocks. Only the iOS parts are fakes. The port of the Android `IntegrationSupport`.
enum IntegrationSupport {
    static let apiKey = "rk_integration"

    struct SystemClock: Clock {
        func now() -> Date { Date() }
    }

    /// Monotonic within the test process; the production clock lives in the `Rubicon` target.
    struct SystemElapsedClock: ElapsedClock {
        func elapsedMillis() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
    }

    static func platform(
        root: URL, network: FakeNetworkMonitor = FakeNetworkMonitor(),
        lifecycle: FakeLifecycleSource = FakeLifecycleSource(),
        logger: RecordingLogger = RecordingLogger(), developerErrors: Locked<[String]> = Locked([])
    ) -> Platform {
        Platform(
            clock: SystemClock(), elapsedClock: SystemElapsedClock(), random: SeededRandom(seed: 7),
            scheduler: GCDScheduler(), networkMonitor: network, transportFactory: URLSessionTransport.factory,
            contextProvider: FakeContextProvider(), processFacts: FakeProcessFacts(), lifecycleSource: lifecycle,
            logger: logger.asLogger, storageRoot: root, fileSystem: PosixFileSystem(),
            developerError: { message in developerErrors.withLock { $0.append(message) } })
    }

    static func config(_ server: TestHTTPServer, configure: (inout AnalyticsConfiguration) -> Void = { _ in })
        -> AnalyticsConfiguration
    {
        var config = AnalyticsConfiguration(apiKey: apiKey)
        config.host = server.hostString
        config.logging.sendDiagnostics = false
        // The Android default; on iOS `debug` defaults to true in a debug build (iOS Configuration 2),
        // and these tests say so explicitly when they want it.
        config.debug = false
        configure(&config)
        return config
    }

    /// A server whose `/v1/config` answers 404 (no remote values) and whose `/v1/batch` answers the
    /// scripted responses in order, then 200.
    static func server() throws -> TestHTTPServer {
        let server = try TestHTTPServer()
        server.respond(to: "/v1/config", with: .init(status: 404))
        return server
    }

    /// The decompressed body of an upload.
    static func body(_ request: TestHTTPServer.RecordedRequest) throws -> [String: JSONValue] {
        let bytes = request.header("Content-Encoding") == "gzip" ? try Gzip.decompress(request.body) : request.body
        guard case .object(let object) = try JSONValue.parse(String(decoding: bytes, as: UTF8.self)) else {
            throw NSError(domain: "IntegrationSupport", code: 1, userInfo: [NSLocalizedDescriptionKey: "not an object"])
        }
        return object
    }

    static func events(_ request: TestHTTPServer.RecordedRequest) throws -> [[String: JSONValue]] {
        guard case .array(let items)? = try body(request)["batch"] else { return [] }
        return items.compactMap {
            if case .object(let object) = $0 { return object }
            return nil
        }
    }

    static func names(_ request: TestHTTPServer.RecordedRequest) throws -> [String] {
        try events(request).map { event in
            if case .string(let name)? = event["event"] { return name }
            if case .string(let type)? = event["type"] { return type }
            return "?"
        }
    }

    static func string(_ event: [String: JSONValue], _ key: String) -> String? {
        if case .string(let value)? = event[key] { return value }
        return nil
    }

    /// Uploads only: the requests to `/v1/batch`, oldest first.
    static func uploads(_ server: TestHTTPServer) -> [TestHTTPServer.RecordedRequest] {
        server.requests.filter { $0.path == "/v1/batch" }
    }

    /// Waits up to `seconds` for the `count`th upload.
    static func waitForUploads(_ server: TestHTTPServer, count: Int, seconds: Double = 5)
        -> [TestHTTPServer.RecordedRequest]
    {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let uploads = uploads(server)
            if uploads.count >= count { return uploads }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return uploads(server)
    }
}
