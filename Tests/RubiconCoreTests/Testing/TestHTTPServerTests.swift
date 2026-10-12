import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

extension RealWorldSuites {
    @Suite("TestHTTPServer", .serialized)
    struct TestHTTPServerTests {
        private func send(_ request: URLRequest) -> (Int?, Data?, (any Error)?) {
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let done = DispatchSemaphore(value: 0)
            let result = Locked<(Int?, Data?, (any Error)?)>((nil, nil, nil))
            session.dataTask(with: request) { data, response, error in
                result.withLock { $0 = ((response as? HTTPURLResponse)?.statusCode, data, error) }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 10)
            return result.current
        }

        @Test("answers a scripted response and records the request with headers and raw body")
        func scriptedResponse() throws {
            let server = try TestHTTPServer()
            defer { server.stop() }
            server.enqueue(.init(status: 429, headers: ["Retry-After": "120"], body: Data("slow down".utf8)))
            let body = Data([0x1f, 0x8b, 0x08, 0x00, 0x01, 0x02, 0x03])
            var request = URLRequest(url: server.url(path: "/v1/batch"))
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            request.setValue("Bearer k", forHTTPHeaderField: "Authorization")

            let (status, data, error) = send(request)

            #expect(error == nil)
            #expect(status == 429)
            #expect(data == Data("slow down".utf8))
            let recorded = try #require(server.waitForRequest())
            #expect(recorded.method == "POST")
            #expect(recorded.path == "/v1/batch")
            #expect(recorded.header("content-encoding") == "gzip")
            #expect(recorded.header("Authorization") == "Bearer k")
            #expect(recorded.header("Content-Length") == "7")
            #expect(recorded.body == body)
            #expect(server.requests.count == 1)
        }

        @Test("answers 200 with an empty body once the script is used up, and records a GET")
        func defaultResponse() throws {
            let server = try TestHTTPServer()
            defer { server.stop() }
            var request = URLRequest(url: server.url(path: "/v1/config?x=1"))
            request.setValue("\"etag\"", forHTTPHeaderField: "If-None-Match")

            let (status, data, _) = send(request)

            #expect(status == 200)
            #expect(data?.isEmpty == true)
            let recorded = try #require(server.waitForRequest())
            #expect(recorded.method == "GET")
            #expect(recorded.path == "/v1/config?x=1")
            #expect(recorded.header("If-None-Match") == "\"etag\"")
        }

        @Test("a dropped response surfaces as an error to the client")
        func dropped() throws {
            let server = try TestHTTPServer()
            defer { server.stop() }
            // URLSession retries a GET whose connection dropped, so a POST shows the failure.
            server.enqueue(.dropped, .dropped)
            var request = URLRequest(url: server.url(path: "/v1/batch"))
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)

            let (status, _, error) = send(request)

            #expect(status == nil)
            #expect(error != nil)
        }

        @Test("a delayed response arrives after the delay")
        func delayed() throws {
            let server = try TestHTTPServer()
            defer { server.stop() }
            server.enqueue(.init(status: 204, delayMillis: 300))
            let start = Date()

            let (status, _, _) = send(URLRequest(url: server.url(path: "/")))

            #expect(status == 204)
            #expect(Date().timeIntervalSince(start) >= 0.3)
        }
    }
}
