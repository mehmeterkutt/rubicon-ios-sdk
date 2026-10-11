import Foundation
import Testing

@testable import RubiconCore

/// The Android golden wire files are the contract (Serialization 5). Until the serializer exists
/// (step 3.2), this suite proves the fixtures are in the bundle and parse with Foundation.
@Suite("Golden fixtures")
struct GoldenFixturesTests {
    static let expectedFiles = [
        "application-backgrounded", "application-installed", "application-opened",
        "application-updated", "deep-link-opened", "envelope", "identify", "network-request",
        "screen", "sdk-diagnostics", "session-ended", "session-started", "track",
    ]

    @Test("every golden file is bundled and parses as a JSON object", arguments: expectedFiles)
    func goldenFileParses(name: String) throws {
        let url = try #require(
            Bundle.module.url(
                forResource: name, withExtension: "json", subdirectory: "Fixtures/golden"))
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        #expect(object is [String: Any])
    }

    @Test("the version constant is a semantic version")
    func versionIsSemantic() {
        let parts = SDKVersion.current.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }
}
