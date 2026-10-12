import Foundation
import Testing

@testable import Rubicon

/// The privacy manifest the `Rubicon` target ships (iOS Privacy 1, step 7.8): read from the built
/// resource bundle, so what is pinned is what an app receives, and compared with the decision's
/// table key by key. Apple's identifiers were verified against the documentation on 2026-10-12.
@Suite("PrivacyManifest")
struct PrivacyManifestTests {
    static let expectedTypes: [(type: String, linked: Bool, purposes: [String])] = [
        ("NSPrivacyCollectedDataTypeDeviceID", true, ["NSPrivacyCollectedDataTypePurposeAnalytics"]),
        ("NSPrivacyCollectedDataTypeUserID", true, ["NSPrivacyCollectedDataTypePurposeAnalytics"]),
        ("NSPrivacyCollectedDataTypeProductInteraction", true, ["NSPrivacyCollectedDataTypePurposeAnalytics"]),
        ("NSPrivacyCollectedDataTypePerformanceData", true, ["NSPrivacyCollectedDataTypePurposeAnalytics"]),
        ("NSPrivacyCollectedDataTypeCoarseLocation", true, ["NSPrivacyCollectedDataTypePurposeAnalytics"]),
        ("NSPrivacyCollectedDataTypeOtherDiagnosticData", false, ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]),
    ]

    static let expectedAPIs: [String: [String]] = [
        "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
    ]

    func manifest() throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let data = try Data(contentsOf: url)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("the manifest ships in the resource bundle with exactly the four top-level keys")
    func topLevel() throws {
        let manifest = try manifest()
        #expect(
            Set(manifest.keys) == [
                "NSPrivacyTracking", "NSPrivacyTrackingDomains", "NSPrivacyCollectedDataTypes",
                "NSPrivacyAccessedAPITypes",
            ])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
    }

    @Test("the collected data types are the six of the decision, in order, none used for tracking")
    func collectedDataTypes() throws {
        let entries = try #require(try manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(entries.count == Self.expectedTypes.count)
        for (entry, expected) in zip(entries, Self.expectedTypes) {
            #expect(
                Set(entry.keys) == [
                    "NSPrivacyCollectedDataType", "NSPrivacyCollectedDataTypeLinked",
                    "NSPrivacyCollectedDataTypeTracking", "NSPrivacyCollectedDataTypePurposes",
                ])
            #expect(entry["NSPrivacyCollectedDataType"] as? String == expected.type)
            #expect(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool == expected.linked)
            #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
            #expect(entry["NSPrivacyCollectedDataTypePurposes"] as? [String] == expected.purposes)
        }
    }

    @Test("the required-reason APIs are the two categories with their one reason each")
    func accessedAPITypes() throws {
        let entries = try #require(try manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var seen: [String: [String]] = [:]
        for entry in entries {
            #expect(Set(entry.keys) == ["NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPITypeReasons"])
            let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
            seen[category] = entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        #expect(seen == Self.expectedAPIs)
    }
}
