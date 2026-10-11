import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("Event model")
struct EventModelTests {
    private func assertSameIdentity(
        _ expected: any Event, _ actual: any Event, _ location: SourceLocation = #_sourceLocation
    ) {
        #expect(expected.source == actual.source, sourceLocation: location)
        #expect(expected.messageId == actual.messageId, sourceLocation: location)
        #expect(expected.timestamp == actual.timestamp, sourceLocation: location)
        #expect(expected.userId == actual.userId, sourceLocation: location)
        #expect(expected.deviceId == actual.deviceId, sourceLocation: location)
        #expect(expected.context == actual.context, sourceLocation: location)
    }

    @Test("a hook mutates its copy and the original is unchanged")
    func copySemantics() {
        var renamed = SampleEvents.track
        renamed.name = "Order Placed"
        var stripped = SampleEvents.track
        stripped.properties = ["amount": .double(1)]
        var traits = SampleEvents.identify
        traits.traits = ["plan": .string("free")]

        #expect(renamed.name == "Order Placed")
        #expect(renamed.properties == SampleEvents.track.properties)
        #expect(SampleEvents.track.name == "Purchase Completed")
        #expect(stripped.properties == ["amount": .double(1)])
        #expect(traits.traits == ["plan": .string("free")])
        assertSameIdentity(SampleEvents.track, renamed)
        assertSameIdentity(SampleEvents.track, stripped)
        assertSameIdentity(SampleEvents.identify, traits)
        #expect(renamed != SampleEvents.track)
    }

    @Test("descriptions name the type, the name and the message id only")
    func descriptions() {
        #expect(
            SampleEvents.track.description
                == "TrackEvent(name: Purchase Completed, messageId: 0192e4a1-7c3f-7a2b-8d4e-1f2a3b4c5d6e)")
        #expect(
            SampleEvents.screen.description
                == "ScreenEvent(name: Checkout, messageId: 0192e4a1-6b2e-7f10-9a3b-2c4d6e8f0a1b)")
        #expect(SampleEvents.identify.description == "IdentifyEvent(messageId: 0192e4a1-5a1d-7e0f-8b2c-1d3e5f7a9b0c)")
        for event in [SampleEvents.track as any Event, SampleEvents.screen, SampleEvents.identify] {
            let text = String(describing: event) + event.context.description
            for secret in ["user-42", SampleEvents.deviceId, "USD", "9.99", "pro", "annotation", "Pixel 8", "Vodafone"]
            {
                #expect(!text.contains(secret), "\(secret) in \(text)")
            }
        }
    }

    @Test("updates describe ids, counts and reasons, not content")
    func updates() {
        #expect(EventUpdate.queued(SampleEvents.track).description == "queued(0192e4a1-7c3f-7a2b-8d4e-1f2a3b4c5d6e)")
        #expect(EventUpdate.sent(messageIds: ["a", "b"]).description == "sent(2 events)")
        #expect(
            EventUpdate.dropped(messageIds: ["a"], reason: .beforeSend).description == "dropped(1 events, before_send)")
    }

    @Test("sources and drop reasons carry their wire names")
    func wireNames() {
        #expect(EventSource.allCases.map(\.rawValue) == ["app", "auto"])
        #expect(
            DropReason.allCases.map(\.rawValue) == [
                "queue_full", "expired", "backpressure", "before_send", "storage_error", "corrupt", "api_key_changed",
                "oversize",
                "rejected", "retry_exhausted",
            ])
    }

    @Test("every public type of the block is Sendable")
    func sendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(TrackEvent.self)
        requireSendable(ScreenEvent.self)
        requireSendable(IdentifyEvent.self)
        requireSendable(EventContext.self)
        requireSendable(EventUpdate.self)
        requireSendable(DropReason.self)
        requireSendable(EventSource.self)
        requireSendable(PropertyValue.self)
        requireSendable(AnalyticsConfiguration.self)
        requireSendable((any Event).self)
    }
}

@Suite("Golden files of the three kinds")
struct EventGoldenTests {
    private func wire(_ event: any Event) throws -> JSONValue {
        try JSONValue.parse(try EventWire.line(event))
    }

    @Test("a track event matches track.json")
    func track() throws {
        #expect(try wire(SampleEvents.track) == SampleEvents.golden("track"))
    }

    @Test("a screen event matches screen.json")
    func screen() throws {
        #expect(try wire(SampleEvents.screen) == SampleEvents.golden("screen"))
    }

    @Test("an identify event matches identify.json")
    func identify() throws {
        #expect(try wire(SampleEvents.identify) == SampleEvents.golden("identify"))
    }

    @Test("an anonymous user is sent as a null user id, and times as epoch milliseconds")
    func anonymous() throws {
        guard case .object(let event) = try wire(SampleEvents.screen) else {
            Issue.record("not an object")
            return
        }
        #expect(event["user_id"] == .null)
        #expect(event["timestamp"] == .number(1_759_147_190_000))
    }

    @Test("unknown context values and empty groups are left out")
    func sparseContext() throws {
        guard case .object(let event) = try wire(SampleEvents.identify), case .object(let context)? = event["context"]
        else {
            Issue.record("not an object")
            return
        }
        #expect(Set(context.keys) == ["os", "library"])
        guard case .object(let screen) = try wire(SampleEvents.screen),
            case .object(let screenContext)? = screen["context"],
            case .object(let network)? = screenContext["network"]
        else {
            Issue.record("not an object")
            return
        }
        #expect(network["carrier"] == nil)
        #expect(network["type"] == .string("cellular"))
    }

    @Test("each line is one compact line")
    func compact() throws {
        for event in [SampleEvents.track as any Event, SampleEvents.screen, SampleEvents.identify] {
            let line = try EventWire.line(event)
            #expect(!line.contains("\n"))
            #expect(!line.contains { $0.isWhitespace && $0 != " " })
        }
    }
}

@Suite("Hook rules")
struct HookRulesTests {
    @Test("the input itself and a changed copy of an app event are accepted")
    func appEvents() {
        var copy = SampleEvents.track
        copy.name = "Renamed"
        copy.properties = ["other": .int(1)]
        #expect(HookRules.check(SampleEvents.track, against: SampleEvents.track) == nil)
        #expect(HookRules.check(copy, against: SampleEvents.track) == nil)
        #expect(HookRules.check(nil, against: SampleEvents.track) == nil)
    }

    @Test("an automatic event may change values only")
    func automaticEvents() {
        var values = SampleEvents.screen
        values.properties = ["name_source": .null]
        var renamed = SampleEvents.screen
        renamed.name = "Other"
        var keys = SampleEvents.screen
        keys.properties = ["name_source": .string("annotation"), "extra": .int(1)]

        #expect(HookRules.check(values, against: SampleEvents.screen) == nil)
        #expect(HookRules.check(nil, against: SampleEvents.screen) == .droppedAutomaticEvent)
        #expect(HookRules.check(renamed, against: SampleEvents.screen) == .renamedAutomaticEvent)
        #expect(HookRules.check(keys, against: SampleEvents.screen) == .changedAutomaticKeys)
    }

    @Test("another kind, changed fixed fields and an invalid name are rejected")
    func rejected() {
        #expect(HookRules.check(SampleEvents.screen, against: SampleEvents.track) == .otherKind)
        let forged = TrackEvent(
            source: .app, messageId: "other", timestamp: SampleEvents.track.timestamp, userId: "user-42",
            deviceId: SampleEvents.deviceId,
            context: SampleEvents.track.context, name: "Purchase Completed", properties: [:])
        #expect(HookRules.check(forged, against: SampleEvents.track) == .changedFixedFields)
        var blank = SampleEvents.track
        blank.name = "  "
        #expect(HookRules.check(blank, against: SampleEvents.track) == .invalidName)
        var traits = SampleEvents.identify
        traits.traits = [:]
        #expect(HookRules.check(traits, against: SampleEvents.identify) == nil)
    }

    @Test("a conformance from outside the SDK is another kind")
    func foreignEvent() {
        struct Foreign: Event {
            let source = EventSource.app
            let messageId = SampleEvents.track.messageId
            let timestamp = SampleEvents.track.timestamp
            let userId: String? = "user-42"
            let deviceId = SampleEvents.deviceId
            let context = SampleEvents.track.context
        }
        #expect(HookRules.check(Foreign(), against: SampleEvents.track) == .otherKind)
        #expect(EventWire.toObject(Foreign())["type"] == .string("unknown"))
    }
}
