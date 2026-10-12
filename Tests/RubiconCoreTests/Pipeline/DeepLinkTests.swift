import Foundation
import Testing

@testable import RubiconCore

/// Privacy 5b and iOS Lifecycle 3: what a deep link may reveal.
@Suite("DeepLink")
struct DeepLinkTests {
    @Test("scheme, host, path, the utm parameters and the referrer; nothing else")
    func properties() throws {
        let url = try #require(
            URL(
                string:
                    "https://shop.example.com/invite/abc?utm_source=mail&utm_campaign=spring&token=secret&utm_term=#frag"
            ))

        let properties = DeepLink.properties(url: url, referrer: "com.apple.mobilemail")

        #expect(
            properties == [
                "scheme": "https", "host": "shop.example.com", "path": "/invite/abc", "utm_source": "mail",
                "utm_campaign": "spring", "referrer": "com.apple.mobilemail",
            ])
    }

    @Test("a custom scheme without a host or query keeps what it has")
    func customScheme() throws {
        let url = try #require(URL(string: "myapp://open/settings"))

        #expect(
            DeepLink.properties(url: url, referrer: nil) == ["scheme": "myapp", "host": "open", "path": "/settings"])
    }

    @Test("the referrer of a universal link is the linking page's host only")
    func referrer() {
        #expect(DeepLink.referrer(of: URL(string: "https://news.example.org/article/42?x=1")) == "news.example.org")
        #expect(DeepLink.referrer(of: nil) == nil)
    }
}
