import CryptoKit
import Foundation
import Testing

@testable import RubiconCore

@Suite("HttpDates")
struct HttpDatesTests {
    @Test("parses the IMF-fixdate example of RFC 9110 and other valid dates")
    func validDates() {
        #expect(HttpDates.parse("Sun, 06 Nov 1994 08:49:37 GMT") == 784_111_777_000)
        #expect(HttpDates.parse("Thu, 01 Jan 1970 00:00:00 GMT") == 0)
        #expect(HttpDates.parse("Thu, 29 Feb 2024 12:34:56 GMT") == 1_709_210_096_000)
        #expect(HttpDates.parse("Mon, 29 Sep 2025 12:02:00 GMT") == 1_759_147_320_000)
    }

    @Test("follows the leap year rule for centuries")
    func centuries() {
        #expect(HttpDates.parse("Tue, 29 Feb 2000 00:00:00 GMT") == 951_782_400_000)
        #expect(HttpDates.parse("Mon, 29 Feb 2100 00:00:00 GMT") == nil)
    }

    @Test("ignores whitespace, does not check the day name, counts a leap second as the next minute")
    func lenientParts() throws {
        #expect(HttpDates.parse("  Sun, 06 Nov 1994 08:49:37 GMT \t") == 784_111_777_000)
        #expect(HttpDates.parse("Mon, 06 Nov 1994 08:49:37 GMT") == 784_111_777_000)
        let before = try #require(HttpDates.parse("Sat, 31 Dec 2016 23:59:59 GMT"))
        #expect(HttpDates.parse("Sat, 31 Dec 2016 23:59:60 GMT") == before + 1_000)
    }

    @Test(
        "rejects anything else",
        arguments: [
            // The obsolete forms of RFC 9110 count as absent.
            "Sunday, 06-Nov-94 08:49:37 GMT",
            "Sun Nov  6 08:49:37 1994",
            // Seconds are Retry-After's other form, parsed elsewhere.
            "120",
            "",
            "Sun, 06 Nov 1994 08:49:37 gmt",
            "sun, 06 Nov 1994 08:49:37 GMT",
            "Sun 06 Nov 1994 08:49:37 GMT",
            "Sun, 6 Nov 1994 08:49:37 GMT",
            "Sun, 06 Nov 94 08:49:37 GMT",
            "Sun, 06 November 1994 08:49:37 GMT",
            "Sun, 06 Nov 1994 08:49:37 UTC",
            "Sun, 06 Nov 1994 08:49:37 +0000",
            "Sun, 06 Nov 1994 08:49 GMT",
            "Sun, 06 Nov 1994 08:49:37 GMT extra",
            "Sun, 31 Nov 1994 08:49:37 GMT",
            "Wed, 29 Feb 2023 00:00:00 GMT",
            "Sun, 00 Nov 1994 08:49:37 GMT",
            "Sun, 06 Nov 1994 24:00:00 GMT",
            "Sun, 06 Nov 1994 08:60:00 GMT",
            "Sun, 06 Nov 1994 08:49:61 GMT",
        ])
    func rejects(value: String) {
        #expect(HttpDates.parse(value) == nil)
    }
}

@Suite("Hashing")
struct HashingTests {
    @Test("matches the published SHA-256 test vectors")
    func vectors() {
        #expect(Hashing.sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(Hashing.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            Hashing.sha256Hex("The quick brown fox jumps over the lazy dog")
                == "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
    }

    @Test("hashes the UTF-8 bytes")
    func utf8() {
        let text = "rk_live_ğüşıöç"
        let expected = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(Hashing.sha256Hex(text) == expected)
        #expect(Hashing.sha256Hex(text).count == 64)
    }
}
