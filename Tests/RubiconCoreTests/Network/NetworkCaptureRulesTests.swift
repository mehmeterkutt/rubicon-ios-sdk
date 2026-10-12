import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The rules of network capture (Privacy 5c, iOS HTTP 3): hosts, masking, the error names and the
/// golden properties. The observer itself is tested in the `Rubicon` target.
@Suite("Network capture rules")
struct NetworkCaptureRulesTests {
    let test = TestPlatform()

    @Test("hosts match exactly or by a leading wildcard, ignoring case")
    func hostPatterns() {
        let patterns = HostPatterns.parse(["API.shop.com", "*.cdn.example.com"], debug: false, log: nil)

        #expect(patterns.matches("api.shop.com"))
        #expect(patterns.matches("Api.Shop.Com"))
        #expect(!patterns.matches("img.shop.com"))
        #expect(!patterns.matches("shop.com"))
        #expect(patterns.matches("eu.cdn.example.com"))
        #expect(patterns.matches("a.b.cdn.example.com"))
        #expect(!patterns.matches("cdn.example.com"))
        #expect(!patterns.matches("evilcdn.example.com"))
    }

    @Test("an invalid host pattern warns and is ignored, and is a developer error in debug")
    func invalidPatterns() {
        let invalid = [
            "*.com", "https://api.shop.com", "api.shop.com/v1", "api.shop.com:443", "*api.shop.com", "", "api.*.com",
        ]
        let log = test.log()

        for pattern in invalid {
            let patterns = HostPatterns.parse([pattern], debug: false, log: log)
            #expect(!patterns.matches("api.shop.com"), "\(pattern)")
            #expect(patterns.isEmpty)
        }
        #expect(test.developerErrors.current.isEmpty)
        _ = HostPatterns.parse(["*.com"], debug: true, log: log)
        #expect(test.developerErrors.current.count == 1)
        #expect(
            test.logger.lines.filter { $0.message.contains(Code.invalidCaptureHost.rawValue) }.count == invalid.count
                + 1)
    }

    @Test("ids are digits, UUIDs or hexadecimal longer than 16 characters")
    func ids() throws {
        #expect(NetworkRequestProperties.isId("12345"))
        #expect(NetworkRequestProperties.isId("3f2a9c1e-0b1c-4d2e-8f3a-7b2d9c1e0b1c"))
        #expect(NetworkRequestProperties.isId("0123456789abcdef0"))
        #expect(!NetworkRequestProperties.isId("0123456789abcdef"))
        #expect(!NetworkRequestProperties.isId("search"))
        #expect(!NetworkRequestProperties.isId("v1"))

        let url = try #require(
            URL(string: "https://h.example/files/3f2a9c1e-0b1c-4d2e-8f3a-7b2d9c1e0b1c/download/v1/products/search"))
        #expect(NetworkRequestProperties.path(url, maskPathIds: true) == "/files/:id/download/v1/products/search")
        #expect(
            NetworkRequestProperties.path(url, maskPathIds: false)
                == "/files/3f2a9c1e-0b1c-4d2e-8f3a-7b2d9c1e0b1c/download/v1/products/search")
        #expect(NetworkRequestProperties.path(try #require(URL(string: "https://h.example")), maskPathIds: true) == "/")
    }

    @Test("the properties keep a non-default port and bracket an IPv6 host, never the query or fragment")
    func urlForms() throws {
        let local = NetworkRequestProperties.build(
            method: "POST", url: try #require(URL(string: "http://127.0.0.1:8080/users/7?token=s#f")), statusCode: 201,
            error: nil, durationMs: 3, requestBytes: 3, responseBytes: nil, maskPathIds: true)
        #expect(local["url"] as? String == "http://127.0.0.1:8080/users/:id")
        #expect(local["path"] as? String == "/users/:id")
        #expect(local["request_bytes"] as? Int64 == 3)
        #expect(local["response_bytes"] == nil)
        #expect(!local.values.contains { "\($0)".contains("token") || "\($0)".contains("#f") })

        let v6 = NetworkRequestProperties.build(
            method: "GET", url: try #require(URL(string: "https://[::1]/a")), statusCode: nil, error: "connect",
            durationMs: 1, requestBytes: nil, responseBytes: nil, maskPathIds: true)
        #expect(v6["url"] as? String == "https://[::1]/a")
        #expect(v6["status_code"] == nil)
        #expect(v6["error"] as? String == "connect")
    }

    @Test("Network Request properties match the golden file")
    func golden() throws {
        let url = try #require(URL(string: "https://api.shop.example.com/users/12345/orders?page=2#top"))

        let properties = NetworkRequestProperties.build(
            method: "GET", url: url, statusCode: 200, error: nil, durationMs: 184, requestBytes: nil,
            responseBytes: 5120, maskPathIds: true)

        guard case .object(let event) = try SampleEvents.golden("network-request"),
            case .object(let expected)? = event["properties"]
        else { throw NSError(domain: "test", code: 1) }
        let normalized = PropertyNormalizer.normalize(properties).values
        var actual: [String: JSONValue] = [:]
        for (key, value) in normalized { actual[key] = JSONValue(value) }
        #expect(actual == expected)
    }

    @Test("the error names follow the iOS HTTP 3 table")
    func errorNames() {
        func name(_ code: URLError.Code) -> String { NetworkErrors.name(for: URLError(code)) }
        #expect(name(.cancelled) == "canceled")
        #expect(name(.timedOut) == "timeout")
        #expect(name(.cannotFindHost) == "unknown_host")
        #expect(name(.dnsLookupFailed) == "unknown_host")
        #expect(name(.cannotConnectToHost) == "connect")
        #expect(name(.notConnectedToInternet) == "connect")
        #expect(name(.secureConnectionFailed) == "tls")
        #expect(name(.appTransportSecurityRequiresSecureConnection) == "tls")
        #expect(name(.networkConnectionLost) == "url_error_-1005")
        #expect(NetworkErrors.name(for: NSError(domain: "other", code: 9)) == "unknown")
    }
}
