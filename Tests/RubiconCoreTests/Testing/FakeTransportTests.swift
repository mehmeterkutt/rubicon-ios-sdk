import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("FakeTransport and HTTP types")
struct FakeTransportTests {
    private func post(_ path: String) -> HttpRequest {
        HttpRequest(method: .post, url: URL(string: "https://h\(path)")!, body: Data("{}".utf8))
    }

    @Test("returns scripted results in order, then the default")
    func scripted() {
        let transport = FakeTransport()
        let failure = HttpResult.networkFailure(kind: .dns, cause: URLError(.cannotFindHost))
        transport.enqueue(.httpError(code: 503, body: nil, retryAfterMs: nil), failure)
        transport.enqueue(.success(code: 204))

        let results = (0..<4).map { _ in transport.execute(post("/v1/batch")) }

        #expect(
            results == [
                .httpError(code: 503, body: nil, retryAfterMs: nil), failure, .success(code: 204), .success(code: 200),
            ])
    }

    @Test("the default result can be chosen and requests are recorded in order")
    func recorded() {
        let transport = FakeTransport(whenEmpty: .httpError(code: 401, body: "denied", retryAfterMs: nil))
        let before = transport.requests

        #expect(transport.execute(post("/v1/batch")) == .httpError(code: 401, body: "denied", retryAfterMs: nil))
        _ = transport.execute(HttpRequest(method: .get, url: URL(string: "https://h/v1/config")!))
        transport.shutdown()

        #expect(before.isEmpty)
        #expect(transport.requests.map(\.url.path) == ["/v1/batch", "/v1/config"])
        #expect(transport.requests.map(\.method) == [.post, .get])
        #expect(transport.shutdowns == 1)
    }

    @Test("a request's description names method, url and body size, never the body or headers")
    func requestDescription() {
        let request = HttpRequest(
            method: .post, url: URL(string: "https://h/v1/batch")!, headers: ["Authorization": "Bearer secret"],
            body: Data("{\"secret\":1}".utf8))
        #expect(request.description == "HttpRequest(POST https://h/v1/batch, body=12 bytes)")
        #expect(
            TransportSettings(
                apiKey: "secret", headers: ["X": "y"], log: Log(level: .off, logger: nil, platformLogger: noOpLogger)
            ).description
                == "TransportSettings(1 custom headers)")
    }

    @Test("results compare by value and describe themselves without bodies")
    func results() {
        let cause = URLError(.networkConnectionLost)
        #expect(HttpResult.success(code: 200) == .success(code: 200))
        #expect(
            HttpResult.httpError(code: 429, body: "x", retryAfterMs: 120_000)
                == .httpError(code: 429, body: "x", retryAfterMs: 120_000))
        #expect(HttpResult.networkFailure(kind: .io, cause: cause) == .networkFailure(kind: .io, cause: cause))
        #expect(HttpResult.networkFailure(kind: .io, cause: cause) != .networkFailure(kind: .timeout, cause: cause))
        #expect(HttpResult.success(code: 200) != .httpError(code: 200, body: nil, retryAfterMs: nil))
        #expect(FailureKind.allCases.count == 8)
        #expect(
            HttpResult.httpError(code: 500, body: "secret body", retryAfterMs: nil).description
                == "HttpError(500, retryAfterMs=nil)")
        #expect(HttpResult.success(code: 200, body: "secret").description == "Success(200)")
    }
}
