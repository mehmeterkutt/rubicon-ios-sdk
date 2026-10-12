import Foundation
import RubiconTesting
import Testing

@testable import Rubicon
@testable import RubiconCore

/// The observer of iOS Lifecycle 5 against `TestHTTPServer` with a real delegate session (step 7.6).
@Suite("RubiconNetworkObserver")
struct RubiconNetworkObserverTests {
    struct Captured: Sendable {
        let gate: Autocapture
        let name: String
        let properties: [String: PropertyValue]
    }

    /// The SDK's instance as the observer sees it: an `Analytics` that is also `AutomaticCapture`.
    final class FakeSdk: Analytics, AutomaticCapture, @unchecked Sendable {
        let events = Locked<[Captured]>([])
        let capturing = Locked(true)
        let log: Log
        let sdkHost: String
        let debug: Bool

        init(log: Log, sdkHost: String = "api.rubicon.example", debug: Bool = false) {
            self.log = log
            self.sdkHost = sdkHost
            self.debug = debug
        }

        func track(gate: Autocapture, name: String, properties: [String: Any]) {
            events.withLock {
                $0.append(Captured(gate: gate, name: name, properties: PropertyNormalizer.normalize(properties).values))
            }
        }
        func screen(gate: Autocapture, name: String, properties: [String: Any]) {}
        var capturesNetworkRequests: Bool { capturing.current }

        func track(_ name: String, properties: [String: Any]) {}
        func screen(_ name: String, properties: [String: Any]) {}
        func identify(_ userId: String, traits: [String: Any]) {}
        func reset() {}
        func register(_ key: String, value: Any) {}
        func unregister(_ key: String) {}
        func flush() {}
        func optOut() {}
        func optIn() {}
        var isOptedOut: Bool { false }
        func clearLocalData() {}
        var deviceId: String { "" }
        func trackDeepLink(_ url: URL, referrer: String?) {}
        func trackDeepLink(_ activity: NSUserActivity) {}
    }

    /// The app's delegate, forwarding the two callbacks as the integration guide shows. A task made
    /// with a completion handler never reaches `didCompleteWithError`, so the data is collected here.
    final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let observer: RubiconNetworkObserver
        let completed = DispatchSemaphore(value: 0)
        let data = Locked(Data())
        let error = Locked<(any Error)?>(nil)
        init(observer: RubiconNetworkObserver) { self.observer = observer }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            self.data.withLock { $0.append(data) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics)
        {
            observer.urlSession(session, task: task, didFinishCollecting: metrics)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            observer.urlSession(session, task: task, didCompleteWithError: error)
            self.error.withLock { $0 = error }
            completed.signal()
        }
    }

    final class Fixture: @unchecked Sendable {
        let test = TestPlatform()
        let server: TestHTTPServer
        lazy var sdk = FakeSdk(log: test.log())

        init() throws { server = try TestHTTPServer() }
        deinit { server.stop() }

        var host: String { "127.0.0.1" }

        func observer(hosts: Set<String>? = nil, maskPathIds: Bool = true, analytics: (any Analytics)? = nil)
            -> RubiconNetworkObserver
        {
            RubiconNetworkObserver(analytics: analytics ?? sdk, hosts: hosts ?? [host], maskPathIds: maskPathIds)
        }

        /// Runs one request through a delegate session and waits for its completion.
        @discardableResult
        func call(
            _ observer: RubiconNetworkObserver, path: String = "/", method: String = "GET", body: Data? = nil,
            url: URL? = nil, timeout: TimeInterval = 5, cancelAfter: TimeInterval? = nil
        ) -> (data: Data?, response: HTTPURLResponse?, error: (any Error)?) {
            let delegate = Delegate(observer: observer)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            var request = URLRequest(url: url ?? server.url(path: path))
            request.httpMethod = method
            request.httpBody = body
            let task = session.dataTask(with: request)
            task.resume()
            if let cancelAfter {
                DispatchQueue.global().asyncAfter(deadline: .now() + cancelAfter) { task.cancel() }
            }
            _ = delegate.completed.wait(timeout: .now() + 15)
            session.finishTasksAndInvalidate()
            return (delegate.data.current, task.response as? HTTPURLResponse, delegate.error.current)
        }

        var events: [Captured] { sdk.events.current }
    }

    @Test("an event carries the decided fields, without query or fragment, ids masked")
    func eventShape() throws {
        let f = try Fixture()
        f.server.enqueue(.init(status: 200, body: Data("hello".utf8)))

        let result = f.call(
            f.observer(), path: "/users/12345/orders?token=secret#frag", method: "POST", body: Data("abc".utf8))

        #expect(String(decoding: result.data ?? Data(), as: UTF8.self) == "hello")
        let event = try #require(f.events.first)
        #expect(f.events.count == 1)
        #expect(event.gate == .networkRequests)
        #expect(event.name == "Network Request")
        let p = event.properties
        #expect(p["method"] == .string("POST"))
        #expect(p["url"] == .string("http://127.0.0.1:\(f.server.port)/users/:id/orders"))
        #expect(p["host"] == .string("127.0.0.1"))
        #expect(p["path"] == .string("/users/:id/orders"))
        #expect(p["status_code"] == .int(200))
        if case .int(let duration)? = p["duration_ms"] { #expect(duration >= 0) } else { Issue.record("no duration") }
        #expect(p["request_bytes"] == .int(3))
        #expect(p["response_bytes"] == .int(5))
        #expect(p["error"] == nil)
        #expect(!p.values.contains { "\($0)".contains("secret") || "\($0)".contains("frag") })
        #expect(
            Set(p.keys) == [
                "method", "url", "host", "path", "status_code", "duration_ms", "request_bytes", "response_bytes",
            ])
    }

    @Test("masking can be switched off")
    func maskingOff() throws {
        let f = try Fixture()
        f.server.enqueue(.init(status: 200))

        f.call(f.observer(maskPathIds: false), path: "/users/12345")

        #expect(f.events.first?.properties["path"] == .string("/users/12345"))
    }

    @Test("an unconfigured host, the SDK's own host and another Analytics are not captured")
    func passThrough() throws {
        let f = try Fixture()
        f.server.enqueue(.init(status: 200), .init(status: 200), .init(status: 200), .init(status: 200))

        f.call(f.observer(hosts: ["api.shop.com", "*.shop.com"]))
        f.call(f.observer(analytics: FakeSdk(log: f.test.log(), sdkHost: f.host)))
        f.call(f.observer(analytics: NoOpAnalytics()))
        f.sdk.capturing.withLock { $0 = false }
        f.call(f.observer())

        #expect(f.events.isEmpty)
        #expect(f.server.requests.count == 4)
    }

    @Test("a failed call is recorded with a short error and no status")
    func failures() throws {
        let f = try Fixture()
        let refused = try #require(URL(string: "http://127.0.0.1:1/a"))

        // The slow answers are bound to their paths, not queued: on the CI toolchain (Xcode 26.6) the
        // queued second answer was taken by a request other than `/cancel`, which then got an immediate
        // 200 from the empty queue and no `canceled`.
        f.server.respond(to: "/slow", with: .init(status: 200, delayMillis: 3_000))
        f.server.respond(to: "/cancel", with: .init(status: 200, delayMillis: 3_000))

        let refusedResult = f.call(f.observer(), url: refused)
        #expect(refusedResult.error != nil)
        let timedOut = f.call(f.observer(), path: "/slow", timeout: 0.5)
        #expect((timedOut.error as? URLError)?.code == .timedOut)
        let cancelled = f.call(f.observer(), path: "/cancel", cancelAfter: 0.2)
        #expect((cancelled.error as? URLError)?.code == .cancelled)

        let errors = f.events.map { $0.properties["error"] }
        #expect(errors == [.string("connect"), .string("timeout"), .string("canceled")])
        #expect(f.events.allSatisfy { $0.properties["status_code"] == nil })
    }

    @Test("the observer never changes the request the server receives")
    func untouched() throws {
        let f = try Fixture()
        f.server.enqueue(.init(status: 200))
        let delegate = Delegate(observer: f.observer())
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: f.server.url(path: "/a"))
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

        session.dataTask(with: request).resume()
        _ = delegate.completed.wait(timeout: .now() + 15)
        session.finishTasksAndInvalidate()

        let received = try #require(f.server.waitForRequest())
        #expect(received.header("Authorization") == "Bearer secret")
        #expect(received.path == "/a")
        #expect(!f.events.flatMap { $0.properties.values }.contains { "\($0)".contains("secret") })
    }
}
