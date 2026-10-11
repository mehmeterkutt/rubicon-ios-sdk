import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The port of the Android `DiagnosticsTest` outside the writer; the `in the writer` tests are
/// ported with the writer (step 6.3b, `DiagnosticsWriterTests`).
@Suite("Diagnostics")
struct DiagnosticsTests {
    static let now = Date(epochMillis: 1_759_147_200_000)
    let hour = Diagnostics.intervalMs
    var now: Date { Self.now }

    func counted(lastSentAt: Date? = nil) -> DiagnosticsState {
        DiagnosticsState(
            periodStart: now.addingTimeInterval(-Double(hour) / 1000), lastSentAt: lastSentAt, dropped: ["expired": 2],
            issues: [:])
    }

    func at(_ millis: Int64) -> Date { Date(epochMillis: now.epochMillis + millis) }

    // MARK: when it is due

    @Test("never when nothing was counted")
    func neverWhenEmpty() {
        #expect(!Diagnostics.isDue(.empty, now: now))
    }

    @Test("at once the first time, then once an hour")
    func onceAnHour() {
        #expect(Diagnostics.isDue(counted(), now: now))
        #expect(!Diagnostics.isDue(counted(lastSentAt: at(-hour + 1)), now: now))
        #expect(Diagnostics.isDue(counted(lastSentAt: at(-hour)), now: now))
    }

    @Test("a last time in the future counts as now")
    func futureLastTime() {
        #expect(!Diagnostics.isDue(counted(lastSentAt: at(10 * hour)), now: now))
    }

    // MARK: the properties

    @Test("match the golden file as a whole event")
    func golden() throws {
        let state = DiagnosticsState(
            periodStart: at(-4 * hour), lastSentAt: nil,
            dropped: ["queue_full": 1200, "expired": 37, "before_send": 3],
            issues: ["STORAGE_WRITE_FAILED": 3, "HOST_BLOCKED": 12])
        let test = TestPlatform()
        let log = test.log(level: .off)
        let person = PersonStore(
            keyValueStore: FileKeyValueStore(root: test.storageRoot, fileSystem: test.fileSystem), log: log)
        person.load()
        let sessions = SessionManager(
            personStore: person, clock: TestClock(start: now), elapsedClock: TestElapsedClock(),
            backgroundTimeoutMs: 300_000, emitEvents: true, newSessionId: { "s" }, log: log, requestPersist: {})
        let provider = FakeContextProvider(staticValues: StaticValues(osName: "Android", osVersion: "16"))
        let pipeline = EventPipeline(
            hooks: [{ _ in nil }], disabledFields: [], debug: false, contextProvider: provider, sessions: sessions,
            newMessageId: { "unused" }, log: log)
        let identity = IdentityRef()
        identity.fill(
            IdentitySnapshot(userId: nil, deviceId: "0191d0c2-1a2b-7c3d-9e4f-5a6b7c8d9e0f", superProperties: [:]))
        let event = CapturedEvent(
            kind: .track, name: Diagnostics.eventName, values: Diagnostics.properties(state, now: now), source: .auto,
            messageId: "0192e4a2-0000-7000-8000-000000000001", timestamp: now, identity: identity, callTime: .none,
            skipsHooks: true)

        let results = pipeline.process(event)
        guard results.count == 1, case .accepted(_, let line) = results[0] else {
            Issue.record("not accepted: \(results)")
            return
        }

        guard case .object(var expected) = try SampleEvents.golden("sdk-diagnostics"),
            case .object(var context)? = expected["context"]
        else {
            Issue.record("the golden file is not an object")
            return
        }
        context["library"] = .object([
            "name": .string(EventPipeline.libraryName), "version": .string(SDKVersion.current),
        ])
        expected["context"] = .object(context)
        #expect(try JSONValue.parse(line) == .object(expected))
    }

    @Test("carry an empty issues object and a zero total when only one side counted")
    func oneSide() {
        let properties = Diagnostics.properties(
            DiagnosticsState(periodStart: nil, lastSentAt: nil, dropped: [:], issues: ["TLS_FAILED": 1]), now: now)

        #expect(properties["dropped"] == .object(["total": .int(0)]))
        #expect(properties["issues"] == .object(["TLS_FAILED": .int(1)]))
        #expect(properties["period_start"] == .string("2025-09-29T12:00:00.000Z"))
    }

    @Test("counts made while it is written are kept for the next period")
    func countsKept() {
        let support = StoreTestSupport()
        let store = DeviceStore(
            keyValueStore: support.files, log: support.log, clock: TestClock(start: now), newDeviceId: { "device-1" })
        store.load()
        store.countDropped(.expired, count: 2)
        guard let reported = store.state?.diagnostics else {
            Issue.record("no state")
            return
        }
        store.countDropped(.expired, count: 3)

        store.diagnosticsReported(reported, at: now)

        #expect(store.state?.diagnostics.dropped == ["expired": 3])
        #expect(store.state?.diagnostics.periodStart == now)
    }
}
