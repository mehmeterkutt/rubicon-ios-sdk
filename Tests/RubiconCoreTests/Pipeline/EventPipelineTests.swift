import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The port of the Android `EventPipelineTest`; the Android test names are kept. The tests of a
/// throwing hook have no counterpart: a Swift hook cannot throw (iOS Public API 6).
@Suite("EventPipeline")
struct EventPipelineTests {
    static let now = Date(epochMillis: 1_759_147_200_123)
    static let deviceId = "0191d0c2-1a2b-7c3d-9e4f-5a6b7c8d9e0f"

    static let staticValues = StaticValues(
        appName: "Rubicon", appVersion: "1.4.0", appBuild: "140", appNamespace: "com.rubicon.demo",
        deviceManufacturer: "Google", deviceModel: "Pixel 8", deviceType: "phone", deviceIsEmulator: false,
        osName: "Android", osVersion: "16", screenWidth: 1080, screenHeight: 2400, screenDensity: 2.625)

    static let callTime = CallTimeValues(networkType: "wifi", locale: "tr-TR", timezone: "Europe/Istanbul")

    final class Fixture: @unchecked Sendable {
        let test = TestPlatform()
        let clock = TestClock(start: EventPipelineTests.now)
        let elapsed = TestElapsedClock()
        let provider = FakeContextProvider(
            staticValues: EventPipelineTests.staticValues, callTimeValues: EventPipelineTests.callTime)
        var ids = 0
        lazy var log = test.log()
        lazy var person: PersonStore = {
            let store = PersonStore(
                keyValueStore: FileKeyValueStore(root: test.storageRoot, fileSystem: test.fileSystem), log: log)
            store.load()
            return store
        }()
        lazy var sessions = SessionManager(
            personStore: person, clock: clock, elapsedClock: elapsed, backgroundTimeoutMs: 300_000, emitEvents: true,
            newSessionId: { [unowned self] in
                ids += 1
                return "session-\(ids)"
            }, log: log, requestPersist: {})

        func pipeline(hooks: [BeforeSend] = [], debug: Bool = false, disabled: Set<ContextField> = [])
            -> EventPipeline
        {
            EventPipeline(
                hooks: hooks, disabledFields: disabled, debug: debug, contextProvider: provider, sessions: sessions,
                newMessageId: { [unowned self] in
                    ids += 1
                    return "generated-\(ids)"
                }, log: log)
        }

        /// Lines with `code` at any level: the first occurrence is logged at ERROR, later ones at
        /// DEBUG (Logging 2), and the Android test counts them the same way.
        func errors(_ code: Code) -> Int {
            test.logger.lines.filter { $0.message.contains(code.rawValue) }.count
        }
        func warned(_ code: Code) -> Bool {
            test.logger.lines.contains { $0.level == .warn && $0.message.contains(code.rawValue) }
        }
        var developerErrors: [String] { test.developerErrors.current }
    }

    let f = Fixture()
    let identity = IdentitySnapshot(userId: "user-42", deviceId: deviceId, superProperties: [:])

    func captured(
        kind: CapturedEvent.Kind = .track, name: String? = "Purchase Completed",
        values: [String: PropertyValue] = ["amount": .double(9.99)], source: EventSource = .app,
        identity: IdentitySnapshot? = nil, skipsHooks: Bool = false, messageId: String = "m-1",
        timestamp: Date = EventPipelineTests.now
    ) -> CapturedEvent {
        let ref = IdentityRef()
        ref.fill(identity ?? self.identity)
        return CapturedEvent(
            kind: kind, name: name, values: values, source: source, messageId: messageId, timestamp: timestamp,
            identity: ref, callTime: Self.callTime, skipsHooks: skipsHooks)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    func single(_ results: [PipelineResult]) throws -> PipelineResult {
        guard results.count == 1 else { throw Failure("expected one result, got \(results.count)") }
        return results[0]
    }

    func accepted(_ result: PipelineResult) throws -> any Event {
        guard case .accepted(let event, _) = result else { throw Failure("not accepted: \(result)") }
        return event
    }

    func line(_ result: PipelineResult) throws -> String {
        guard case .accepted(_, let line) = result else { throw Failure("not accepted: \(result)") }
        return line
    }

    func dropReason(_ result: PipelineResult) throws -> DropReason {
        guard case .dropped(_, let reason) = result else { throw Failure("not dropped: \(result)") }
        return reason
    }

    func track(_ event: any Event) throws -> TrackEvent {
        guard let track = event as? TrackEvent else { throw Failure("not a track event: \(event)") }
        return track
    }

    // MARK: building the event

    @Test("a track event matches the golden file")
    func goldenTrack() throws {
        f.person.update {
            with($0) {
                $0.session = SessionState(
                    id: "0192e49f-0b1c-7d2e-8f3a-4b5c6d7e8f90", startedAt: Date(epochMillis: 1_759_147_082_000),
                    lastActivity: Self.now.addingTimeInterval(-60))
            }
        }
        _ = f.sessions.start()
        let event = captured(
            values: [
                "amount": .double(9.99), "currency": .string("USD"),
                "trial_ends_at": .string("2026-10-13T00:00:00.000Z"), "ab_group": .string("B"),
                "items": .array([.object(["sku": .string("A1"), "qty": .int(2)])]), "coupon": .null,
            ], messageId: "0192e4a1-7c3f-7a2b-8d4e-1f2a3b4c5d6e", timestamp: Date(epochMillis: 1_759_147_200_123))

        let line = try line(try single(f.pipeline().process(event)))

        // The library is this SDK's; everything else is the Android file.
        guard case .object(var expected) = try SampleEvents.golden("track"),
            case .object(var context)? = expected["context"]
        else { throw Failure("the golden file is not an object") }
        context["library"] = .object([
            "name": .string(EventPipeline.libraryName), "version": .string(SDKVersion.current),
        ])
        expected["context"] = .object(context)
        #expect(try JSONValue.parse(line) == .object(expected))
    }

    @Test("static context is read once, on first need")
    func staticOnce() {
        let pipeline = f.pipeline()

        for _ in 0..<3 { _ = pipeline.process(captured()) }

        #expect(f.provider.staticReads == 1)
    }

    @Test("disabled fields are passed to the provider and left out of the event")
    func disabledFields() throws {
        let disabled: Set<ContextField> = [.deviceModel, .timezone, .screenWidth]

        let event = try accepted(try single(f.pipeline(disabled: disabled).process(captured())))

        #expect(f.provider.lastDisabled == disabled)
        #expect(event.context.device.model == nil)
        #expect(event.context.timezone == nil)
        #expect(event.context.screen.width == nil)
        #expect(event.context.screen.height == 2400)
        #expect(event.context.network.type == "wifi")
    }

    @Test("a disabled field is left out even when the provider returns it")
    func disabledDespiteProvider() throws {
        let strict = FakeContextProvider(staticValues: Self.staticValues, callTimeValues: Self.callTime)
        let pipeline = EventPipeline(
            hooks: [], disabledFields: [.locale], debug: false, contextProvider: strict, sessions: f.sessions,
            newMessageId: { "x" }, log: f.log)
        // The call-time values of the captured event were taken before the field was disabled.
        let event = try accepted(try single(pipeline.process(captured())))
        #expect(event.context.locale == nil)
    }

    @Test("pending call-time values are read from the provider on the writer")
    func pendingCallTime() throws {
        let ref = IdentityRef()
        ref.fill(identity)
        let event = CapturedEvent(
            kind: .track, name: "x", values: [:], source: .app, messageId: "m-1", timestamp: Self.now, identity: ref,
            callTime: CallTimeValues(pending: true))

        let built = try accepted(try single(f.pipeline().process(event)))

        #expect(built.context.network.type == "wifi")
        #expect(f.provider.callTimeReads == 1)
    }

    @Test("super properties merge, the event's own key wins")
    func superPropertiesMerge() throws {
        let withSupers = IdentitySnapshot(
            userId: "user-42", deviceId: Self.deviceId, superProperties: ["plan": .string("pro"), "amount": .int(1)])

        let event = try track(try accepted(try single(f.pipeline().process(captured(identity: withSupers)))))

        #expect(event.properties == ["plan": .string("pro"), "amount": .double(9.99)])
    }

    @Test("identify carries traits only, never super properties")
    func identifyTraitsOnly() throws {
        let withSupers = IdentitySnapshot(
            userId: "user-42", deviceId: Self.deviceId, superProperties: ["plan": .string("pro")])

        let event = try accepted(
            try single(
                f.pipeline().process(
                    captured(kind: .identify, name: nil, values: ["tier": .int(2)], identity: withSupers))))

        #expect((event as? IdentifyEvent)?.traits == ["tier": .int(2)])
    }

    @Test("screen events carry their name and merged properties")
    func screenEvents() throws {
        let event = try accepted(
            try single(f.pipeline().process(captured(kind: .screen, name: "checkout", values: [:]))))

        #expect((event as? ScreenEvent)?.name == "checkout")
    }

    // MARK: session events

    @Test("the first foreground event gets Session Started right before it, in the new session")
    func sessionStarted() throws {
        _ = f.sessions.onForeground()

        let results = f.pipeline().process(captured())

        try #require(results.count == 2)
        let started = try track(try accepted(results[0]))
        let event = try accepted(results[1])
        #expect(started.name == "Session Started")
        #expect(started.source == .auto)
        #expect(started.properties == [:])
        #expect(started.timestamp == Self.now)
        #expect(started.context.session?.id == event.context.session?.id)
        #expect(event.context.session?.startedAt == Self.now)
    }

    @Test("Session Ended is backdated, carries the duration and the ended session")
    func sessionEnded() throws {
        let pipeline = f.pipeline()
        _ = f.sessions.onForeground()
        let first = try accepted(pipeline.process(captured())[1])
        f.clock.advance(byMillis: 60_000)
        f.elapsed.advance(byMillis: 60_000)
        f.sessions.onBackground()
        f.clock.advance(byMillis: 600_000)
        f.elapsed.advance(byMillis: 600_000)

        let results = pipeline.processSessionEvents(
            f.sessions.onForeground(), current: identity, callTime: Self.callTime)

        let ended = try track(try accepted(try single(results)))
        #expect(ended.name == "Session Ended")
        #expect(ended.source == .auto)
        #expect(ended.timestamp == Self.now.addingTimeInterval(60))
        #expect(ended.properties == ["duration_ms": .int(60_000)])
        #expect(ended.context.session?.id == first.context.session?.id)
        let next = pipeline.process(captured(messageId: "m-2", timestamp: f.clock.now()))
        #expect(try track(try accepted(next[0])).name == "Session Started")
    }

    @Test("a session ended by a person change carries the previous user")
    func personChange() throws {
        let pipeline = f.pipeline()
        _ = f.sessions.onForeground()
        _ = pipeline.process(captured())
        let previous = IdentitySnapshot(
            userId: "user-42", deviceId: Self.deviceId, superProperties: ["plan": .string("pro")])

        let ended = try track(
            try accepted(
                try single(
                    pipeline.processSessionEvents(
                        f.sessions.onPersonCleared(previous),
                        current: IdentitySnapshot(userId: nil, deviceId: Self.deviceId, superProperties: [:]),
                        callTime: Self.callTime))))

        #expect(ended.userId == "user-42")
        #expect(ended.properties["plan"] == .string("pro"))
    }

    @Test("session events reach the hooks as automatic events")
    func sessionEventsReachHooks() {
        let seen = Locked<[String]>([])
        _ = f.sessions.onForeground()

        _ = f.pipeline(hooks: [
            { event in
                seen.withLock { $0.append("\((event as? TrackEvent)?.name ?? "?")/\(event.source.rawValue)") }
                return event
            }
        ]).process(captured())

        #expect(seen.current == ["Session Started/auto", "Purchase Completed/app"])
    }

    @Test("a background event without a session has no session context")
    func noSessionInBackground() throws {
        #expect(try accepted(try single(f.pipeline().process(captured()))).context.session == nil)
    }

    // MARK: hooks on the app's events

    @Test("run in list order, each seeing the previous result")
    func hookOrder() throws {
        let order = Locked<[Int]>([])
        let hooks: [BeforeSend] = [
            { event in
                order.withLock { $0.append(1) }
                guard var track = event as? TrackEvent else { return event }
                track.properties["a"] = .int(1)
                return track
            },
            { event in
                order.withLock { $0.append(2) }
                guard var track = event as? TrackEvent, case .int(let a)? = track.properties["a"] else { return event }
                track.name = "Order Placed"
                track.properties["b"] = .int(a + 1)
                return track
            },
        ]

        let event = try track(try accepted(try single(f.pipeline(hooks: hooks).process(captured()))))

        #expect(order.current == [1, 2])
        #expect(event.name == "Order Placed")
        #expect(event.properties == ["amount": .double(9.99), "a": .int(1), "b": .int(2)])
    }

    @Test("nil drops the event as before_send, quietly")
    func nilDrops() throws {
        let result = try single(f.pipeline(hooks: [{ _ in nil }]).process(captured()))

        #expect(try dropReason(result) == .beforeSend)
        #expect(result.messageId == "m-1")
        #expect(f.errors(.hookViolation) == 0)
        #expect(f.test.logger.lines.contains { $0.level == .debug && $0.message.contains("dropped m-1") })
    }

    @Test("an invalid property from a hook is dropped by the second validation")
    func secondValidation() throws {
        let hooks: [BeforeSend] = [
            { event in
                guard var track = event as? TrackEvent else { return event }
                track.properties["long"] = .string(String(repeating: "y", count: 2_000))
                track.properties["nan"] = .double(.nan)
                track.properties[""] = .int(1)
                return track
            }
        ]

        let event = try track(try accepted(try single(f.pipeline(hooks: hooks).process(captured()))))

        #expect(event.properties == ["amount": .double(9.99), "long": .string(String(repeating: "y", count: 1_024))])
        #expect(f.warned(.propertyDropped))
        #expect(f.warned(.propertyTruncated))
    }

    @Test("a renamed event with an invalid name is a violation")
    func invalidName() throws {
        let result = try single(
            f.pipeline(hooks: [
                { event in
                    guard var track = event as? TrackEvent else { return event }
                    track.name = " "
                    return track
                }
            ]).process(captured()))

        #expect(try dropReason(result) == .beforeSend)
        #expect(f.errors(.hookViolation) == 1)
    }

    // MARK: hooks on automatic events

    var auto: CapturedEvent {
        captured(
            name: "Deep Link Opened", values: ["path": .string("/invite/abc"), "nested": .object(["x": .int(1)])],
            source: .auto)
    }

    @Test("may change values, to null, to another type and nested")
    func automaticValues() throws {
        let hooks: [BeforeSend] = [
            { event in
                guard var track = event as? TrackEvent else { return event }
                track.properties = ["path": .null, "nested": .object(["y": .array([.int(1), .int(2)])])]
                return track
            }
        ]

        let event = try track(try accepted(try single(f.pipeline(hooks: hooks).process(auto))))

        #expect(event.properties == ["path": .null, "nested": .object(["y": .array([.int(1), .int(2)])])])
        #expect(f.errors(.hookViolation) == 0)
    }

    @Test("renaming, adding or removing a top-level key, or returning nil drops it")
    func automaticBreaches() throws {
        let breaches: [BeforeSend] = [
            { event in
                guard var track = event as? TrackEvent else { return event }
                track.name = "Link"
                return track
            },
            { event in
                guard var track = event as? TrackEvent else { return event }
                track.properties["extra"] = .int(1)
                return track
            },
            { event in
                guard var track = event as? TrackEvent else { return event }
                track.properties["nested"] = nil
                return track
            },
            { _ in nil },
        ]

        for breach in breaches {
            let result = try single(f.pipeline(hooks: [breach]).process(auto))
            #expect(try dropReason(result) == .beforeSend)
        }
        #expect(f.errors(.hookViolation) == 4)
        #expect(f.developerErrors.isEmpty)
    }

    @Test("a breach is a developer error in debug")
    func breachInDebug() throws {
        _ = f.pipeline(hooks: [{ _ in nil }], debug: true).process(auto)
        _ = f.pipeline(
            hooks: [
                { event in
                    guard var track = event as? TrackEvent else { return event }
                    track.name = "Link"
                    return track
                }
            ], debug: true
        ).process(auto)

        #expect(
            f.developerErrors == [
                "beforeSend: a hook returned nil for an automatic event",
                "beforeSend: a hook renamed an automatic event",
            ])
        #expect(f.errors(.hookViolation) == 2)
    }

    // MARK: results that are not a copy

    @Test("an event of another type is dropped")
    func otherType() throws {
        let other = try accepted(
            try single(f.pipeline().process(captured(kind: .screen, name: "checkout", values: [:]))))

        let result = try single(f.pipeline(hooks: [{ _ in other }]).process(captured()))

        #expect(try dropReason(result) == .beforeSend)
        #expect(f.errors(.hookViolation) == 1)
    }

    @Test("an event with another message id is dropped")
    func otherMessageId() throws {
        let impostor = try accepted(try single(f.pipeline().process(captured(messageId: "m-2"))))

        let result = try single(f.pipeline(hooks: [{ _ in impostor }]).process(captured()))

        #expect(try dropReason(result) == .beforeSend)
    }

    @Test("an event built from scratch is dropped")
    func builtFromScratch() throws {
        // A third-party conformance to Event, or an SDK event with another context, is never the input.
        struct Foreign: Event {
            let source: EventSource
            let messageId: String
            let timestamp: Date
            let userId: String?
            let deviceId: String
            let context: EventContext
        }
        let foreign: BeforeSend = { event in
            Foreign(
                source: event.source, messageId: event.messageId, timestamp: event.timestamp, userId: event.userId,
                deviceId: event.deviceId, context: event.context)
        }
        let otherContext = try accepted(try single(f.pipeline(disabled: [.locale]).process(captured()))).context
        let rebuilt: BeforeSend = { event in
            TrackEvent(
                source: event.source, messageId: event.messageId, timestamp: event.timestamp, userId: event.userId,
                deviceId: event.deviceId, context: otherContext, name: "Purchase Completed", properties: [:])
        }

        #expect(try dropReason(try single(f.pipeline(hooks: [foreign]).process(captured()))) == .beforeSend)
        #expect(try dropReason(try single(f.pipeline(hooks: [rebuilt]).process(captured()))) == .beforeSend)
        #expect(f.errors(.hookViolation) == 2)
    }

    // MARK: SDK Diagnostics

    @Test("never reaches a hook")
    func diagnosticsSkipHooks() throws {
        let called = Locked(false)

        let result = f.pipeline(hooks: [
            { _ in
                called.withLock { $0 = true }
                return nil
            }
        ]).process(
            captured(
                name: "SDK Diagnostics", values: ["dropped": .object(["total": .int(1)])], source: .auto,
                skipsHooks: true))

        #expect(!called.current)
        _ = try accepted(try single(result))
    }

    // MARK: size limit

    func big() -> [String: PropertyValue] {
        Dictionary(
            uniqueKeysWithValues: (1...40).map {
                ("k\($0)", PropertyValue.string(String(repeating: "x", count: 1_000)))
            })
    }

    @Test("an event over 32 KB is dropped as oversize with a warning")
    func oversize() throws {
        let result = try single(f.pipeline().process(captured(values: big())))

        #expect(try dropReason(result) == .oversize)
        #expect(f.warned(.eventOversize))
        #expect(f.developerErrors.isEmpty)
    }

    @Test("it is a developer error in debug")
    func oversizeInDebug() throws {
        _ = f.pipeline(debug: true).process(captured(values: big()))

        #expect(f.developerErrors.count == 1)
        #expect(f.developerErrors.first?.hasSuffix("over the limit of 32768; it was dropped") == true)
    }

    @Test("exactly 32 KB is kept, one byte more is dropped")
    func exactLimit() throws {
        // Strings are cut at 1024 characters, so the size is built from many shorter values.
        let filler = Dictionary(
            uniqueKeysWithValues: (1...31).map {
                (String(format: "k%02d", $0), PropertyValue.string(String(repeating: "y", count: 1_000)))
            })
        let base = try line(try single(f.pipeline().process(captured(values: filler)))).utf8.count
        // Adding ,"z":"..." costs 7 bytes plus the value.
        let room = EventPipeline.maxEventBytes - base - 7
        var fitsValues = filler
        fitsValues["z"] = .string(String(repeating: "y", count: room))
        var overValues = filler
        overValues["z"] = .string(String(repeating: "y", count: room + 1))

        let fits = try single(f.pipeline().process(captured(values: fitsValues)))
        let over = try single(f.pipeline().process(captured(values: overValues)))

        #expect(try line(fits).utf8.count == EventPipeline.maxEventBytes)
        #expect(try dropReason(over) == .oversize)
    }

    @Test("an unresolved identity is an SDK error, counted like a failed write")
    func unresolvedIdentity() throws {
        let event = CapturedEvent(
            kind: .track, name: "x", values: [:], source: .app, messageId: "m-9", timestamp: Self.now,
            identity: IdentityRef(), callTime: Self.callTime)

        let result = try single(f.pipeline().process(event))

        #expect(try dropReason(result) == .storageError)
        #expect(result.messageId == "m-9")
        #expect(f.errors(.workerFailed) == 1)
    }
}
