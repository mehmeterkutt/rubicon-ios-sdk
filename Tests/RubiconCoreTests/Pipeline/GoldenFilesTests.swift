import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The wire contract of the automatic events (Serialization 5, step 8.4), the port of the Android
/// `GoldenFilesTest`: each golden file is compared structurally with what the real writer stores
/// and parsed by an independent parser. Ids are random, so they are checked to be UUIDv7 and taken
/// from the file; the library group is taken from the file too, since its name is the platform's
/// and its version changes with every release. The two Android-only context fields are removed
/// from the file before comparing (`SampleEvents.golden`).
///
/// `track`, `screen`, `identify` are compared in `EventGoldenTests`, `SDK Diagnostics` in
/// `DiagnosticsTests.golden`, the envelope in `FileEventStoreTests.envelope`, and the files
/// themselves in `GoldenFixturesTests`.
@Suite("Golden files of the automatic events")
struct GoldenFilesTests {
    // 2025-09-29T12:00:00.000Z and the two dates of the install and update files.
    static let t0 = Date(epochMillis: 1_759_147_200_000)
    static let installedAt = Date(epochMillis: 1_759_060_800_000)
    static let updatedAt = Date(epochMillis: 1_759_140_000_000)
    static let uuid = "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"

    // The golden context is Android's; the fakes report the same values, so the comparison is exact.
    static let staticValues = StaticValues(
        appName: "Rubicon", appVersion: "1.4.0", appBuild: "140", appNamespace: "com.rubicon.demo",
        deviceManufacturer: "Google", deviceModel: "Pixel 8", deviceType: "phone", deviceIsEmulator: false,
        osName: "Android", osVersion: "16", screenWidth: 1080, screenHeight: 2400, screenDensity: 2.625)
    static let callTime = CallTimeValues(networkType: "wifi", locale: "tr-TR", timezone: "Europe/Istanbul")

    final class Fixture {
        let h: WriterHarness

        init(configure: (inout AnalyticsConfiguration) -> Void = { _ in }) {
            h = WriterHarness(configure: configure)
            h.test.clock.set(GoldenFilesTests.t0)
            h.test.contextProvider.staticValues = GoldenFilesTests.staticValues
            h.test.contextProvider.callTimeValues = GoldenFilesTests.callTime
        }

        deinit {
            h.writer.shutdown()
            h.cleanUp()
        }

        func event(_ name: String) throws -> [String: JSONValue] {
            let matches = try h.lines().compactMap { line -> [String: JSONValue]? in
                guard case .object(let object) = try JSONValue.parse(line) else { return nil }
                let eventName = object["event"] ?? object["name"]
                return eventName == .string(name) ? object : nil
            }
            try #require(matches.count == 1, Comment(rawValue: "\(name): \(matches.count) events in \(h.names())"))
            return matches[0]
        }

        func advance(_ millis: Int64) {
            h.test.clock.advance(byMillis: millis)
            h.test.elapsedClock.advance(byMillis: millis)
        }
    }

    static func expectGolden(_ name: String, _ actual: [String: JSONValue]) throws {
        guard case .object(let expected) = try SampleEvents.golden(name) else {
            Issue.record("\(name).json is not an object")
            return
        }
        let stable = try withStableValues(of: expected, actual)
        #expect(JSONValue.object(stable) == .object(expected), Comment(rawValue: name))
    }

    /// The ids must be UUIDv7 and the library group ours; their values come from the golden file.
    static func withStableValues(of golden: [String: JSONValue], _ actual: [String: JSONValue]) throws
        -> [String: JSONValue]
    {
        var stable = actual
        for key in ["message_id", "device_id"] {
            guard case .string(let id)? = actual[key] else { throw Failure("\(key) missing") }
            #expect(id.range(of: uuid, options: .regularExpression) != nil, Comment(rawValue: "\(key) \(id)"))
            stable[key] = golden[key]
        }
        guard case .object(var context)? = actual["context"], case .object(let goldenContext)? = golden["context"]
        else { throw Failure("context missing") }
        if case .object(var session)? = context["session"] {
            guard case .string(let id)? = session["id"] else { throw Failure("session id missing") }
            #expect(id.range(of: uuid, options: .regularExpression) != nil, Comment(rawValue: "session id \(id)"))
            if case .object(let goldenSession)? = goldenContext["session"] { session["id"] = goldenSession["id"] }
            context["session"] = .object(session)
        }
        guard case .object(let library)? = context["library"] else { throw Failure("library missing") }
        #expect(library["name"] == .string(EventPipeline.libraryName))
        #expect(library["version"] == .string(SDKVersion.current))
        context["library"] = goldenContext["library"]
        stable["context"] = .object(context)
        return stable
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: lifecycle and session events

    @Test("a first launch, a background and a return after the session timeout")
    func firstLaunch() throws {
        let f = Fixture()
        f.h.test.processFacts.installed = InstalledApp(
            version: "1.4.0", build: "140", installTime: Self.installedAt, updateTime: Self.installedAt)
        f.h.writer.start()
        f.h.runCurrent()
        f.h.test.lifecycleSource.moveToForeground()
        f.h.runCurrent()
        f.advance(65_000)
        f.h.test.lifecycleSource.moveToBackground()
        f.h.runCurrent()

        try Self.expectGolden("session-started", f.event("Session Started"))
        try Self.expectGolden("application-installed", f.event("Application Installed"))
        try Self.expectGolden("application-opened", f.event("Application Opened"))
        try Self.expectGolden("application-backgrounded", f.event("Application Backgrounded"))

        f.advance(600_000)
        f.h.test.lifecycleSource.moveToForeground()
        f.h.runCurrent()

        try Self.expectGolden("session-ended", f.event("Session Ended"))
    }

    @Test("an update from an earlier version")
    func update() throws {
        let f = Fixture()
        _ = f.h.deviceStore.load()
        f.h.deviceStore.update { state in
            var state = state
            state.lastVersion = "1.3.2"
            state.lastBuild = "132"
            return state
        }
        _ = f.h.deviceStore.persist()
        f.h.test.processFacts.installed = InstalledApp(
            version: "1.4.0", build: "140", installTime: Self.installedAt, updateTime: Self.updatedAt)
        f.h.writer.start()
        f.h.runCurrent()
        f.h.test.lifecycleSource.moveToForeground()
        f.h.runCurrent()

        try Self.expectGolden("application-updated", f.event("Application Updated"))
    }

    // MARK: events with properties from the Rubicon target

    /// Enqueues an automatic event with the golden file's properties, as the iOS target does after
    /// it built them (`DeepLink`, `NetworkRequestProperties`, whose own tests check the properties).
    func capture(_ f: Fixture, _ name: String, gate: Autocapture) throws {
        guard case .object(let golden) = try SampleEvents.golden(name), case .string(let event)? = golden["event"],
            case .object(let properties)? = golden["properties"]
        else { throw Failure("\(name).json shape") }
        let accepted = f.h.writer.enqueue(
            CapturedEvent(
                kind: .track, name: event, values: properties.mapValues(Self.property), source: .auto,
                messageId: "0192e4a3-2000-7000-8000-000000000001", timestamp: f.h.test.clock.now(),
                identity: f.h.identity.snapshot(), callTime: Self.callTime, gate: gate))
        #expect(accepted)
    }

    static func property(_ value: JSONValue) -> PropertyValue {
        switch value {
        case .string(let text): return .string(text)
        case .number(let number):
            return number == number.rounded() && abs(number) < 1e15 ? .int(Int64(number)) : .double(number)
        case .bool(let flag): return .bool(flag)
        case .null: return .null
        case .array(let items): return .array(items.map(property))
        case .object(let fields): return .object(fields.mapValues(property))
        }
    }

    @Test("Deep Link Opened")
    func deepLink() throws {
        let f = Fixture { $0.autocapture.enabled.insert(.deepLinks) }
        f.h.writer.start()
        f.h.runCurrent()
        f.h.test.lifecycleSource.moveToForeground()
        f.h.runCurrent()
        try capture(f, "deep-link-opened", gate: .deepLinks)
        f.h.runCurrent()

        try Self.expectGolden("deep-link-opened", f.event("Deep Link Opened"))
    }

    @Test("Network Request")
    func networkRequest() throws {
        let f = Fixture()
        f.h.writer.start()
        f.h.runCurrent()
        f.h.test.lifecycleSource.moveToForeground()
        f.h.runCurrent()
        try capture(f, "network-request", gate: .networkRequests)
        f.h.runCurrent()

        try Self.expectGolden("network-request", f.event("Network Request"))
    }
}
