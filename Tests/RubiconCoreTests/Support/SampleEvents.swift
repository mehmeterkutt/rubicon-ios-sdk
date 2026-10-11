import Foundation

@testable import RubiconCore

/// The events of the golden files, built through the package initializers. The files are the
/// Android ones verbatim, so the context carries Android's values; `os.api_level` and
/// `network.carrier` do not exist on iOS and are removed from the file before comparing (iOS
/// Context 1).
enum SampleEvents {
    static let deviceId = "0191d0c2-1a2b-7c3d-9e4f-5a6b7c8d9e0f"
    static let library = LibraryContext(name: "rubicon-android", version: "0.1.0")
    static let session = SessionContext(
        id: "0192e49f-0b1c-7d2e-8f3a-4b5c6d7e8f90", startedAt: Date(epochMillis: 1_759_147_082_000))

    static func fullContext(network: NetworkContext) -> EventContext {
        EventContext(
            app: AppContext(name: "Rubicon", version: "1.4.0", build: "140", namespace: "com.rubicon.demo"),
            device: DeviceContext(manufacturer: "Google", model: "Pixel 8", type: "phone", isEmulator: false),
            os: OsContext(name: "Android", version: "16"),
            screen: ScreenContext(width: 1080, height: 2400, density: 2.625),
            network: network, locale: "tr-TR", timezone: "Europe/Istanbul", session: session, library: library)
    }

    // Everything unknown except the OS: empty groups and missing values are left out.
    static let sparseContext = EventContext(
        app: AppContext(name: nil, version: nil, build: nil, namespace: nil),
        device: DeviceContext(manufacturer: nil, model: nil, type: nil, isEmulator: nil),
        os: OsContext(name: "Android", version: "16"), screen: ScreenContext(width: nil, height: nil, density: nil),
        network: NetworkContext(type: nil), locale: nil, timezone: nil, session: nil, library: library)

    static let track = TrackEvent(
        source: .app, messageId: "0192e4a1-7c3f-7a2b-8d4e-1f2a3b4c5d6e",
        timestamp: Date(epochMillis: 1_759_147_200_123),
        userId: "user-42", deviceId: deviceId, context: fullContext(network: NetworkContext(type: "wifi")),
        name: "Purchase Completed",
        properties: [
            "amount": .double(9.99), "currency": .string("USD"), "trial_ends_at": .string("2026-10-13T00:00:00.000Z"),
            "ab_group": .string("B"), "items": .array([.object(["sku": .string("A1"), "qty": .int(2)])]),
            "coupon": .null,
        ])

    static let screen = ScreenEvent(
        source: .auto, messageId: "0192e4a1-6b2e-7f10-9a3b-2c4d6e8f0a1b",
        timestamp: Date(epochMillis: 1_759_147_190_000),
        userId: nil, deviceId: deviceId, context: fullContext(network: NetworkContext(type: "cellular")),
        name: "Checkout",
        properties: ["name_source": .string("annotation")])

    static let identify = IdentifyEvent(
        source: .app, messageId: "0192e4a1-5a1d-7e0f-8b2c-1d3e5f7a9b0c",
        timestamp: Date(epochMillis: 1_759_147_100_000),
        userId: "user-42", deviceId: deviceId, context: sparseContext,
        traits: ["plan": .string("pro"), "signup_at": .string("2026-09-01T12:00:00.000Z")])

    /// A golden file as the independent parser sees it, with the two Android-only context fields
    /// removed.
    static func golden(_ name: String) throws -> JSONValue {
        let url = try require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/golden"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return removingAndroidOnlyFields(try JSONValue.parse(text))
    }

    static func removingAndroidOnlyFields(_ value: JSONValue) -> JSONValue {
        guard case .object(var event) = value, case .object(var context)? = event["context"] else { return value }
        if case .object(var os)? = context["os"] {
            os["api_level"] = nil
            context["os"] = .object(os)
        }
        if case .object(var network)? = context["network"] {
            network["carrier"] = nil
            context["network"] = network.isEmpty ? nil : .object(network)
        }
        event["context"] = .object(context)
        return .object(event)
    }
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "SampleEvents", code: 1) }
    return value
}
