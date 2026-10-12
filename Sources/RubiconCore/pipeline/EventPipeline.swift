import Foundation

/// An event as captured on the calling thread (Public API 9, Context 2): what the developer passed,
/// normalized, with its id, time, identity and the time-dependent context of that moment.
package struct CapturedEvent: Sendable, CustomStringConvertible {
    package enum Kind: Sendable {
        case track, screen, identify
    }

    package let kind: Kind
    /// The event or screen name; `nil` for identify.
    package let name: String?
    /// Normalized properties, or traits for identify.
    package let values: [String: PropertyValue]
    package let source: EventSource
    package let messageId: String
    package let timestamp: Date
    package let identity: IdentityRef
    package let callTime: CallTimeValues
    /// `SDK Diagnostics` reports on the SDK itself and never reaches a hook (Logging 5).
    package let skipsHooks: Bool
    /// For identify: whether to send it is decided by the identity, possibly only when the stores
    /// are loaded (Android log 6.1); the writer reads it in call order.
    package let ticket: IdentifyTicket?
    /// For an event `Rubicon` captured itself: written only while this type is effective.
    package let gate: Autocapture?

    package init(
        kind: Kind, name: String?, values: [String: PropertyValue], source: EventSource, messageId: String,
        timestamp: Date, identity: IdentityRef, callTime: CallTimeValues, skipsHooks: Bool = false,
        ticket: IdentifyTicket? = nil, gate: Autocapture? = nil
    ) {
        self.kind = kind
        self.name = name
        self.values = values
        self.source = source
        self.messageId = messageId
        self.timestamp = timestamp
        self.identity = identity
        self.callTime = callTime
        self.skipsHooks = skipsHooks
        self.ticket = ticket
        self.gate = gate
    }

    package var description: String { "CapturedEvent(\(kind), \(messageId))" }
}

/// What became of one event in the pipeline.
package enum PipelineResult: Sendable {
    /// Ready to append; `line` is exactly what is stored and sent (Disk 3).
    case accepted(event: any Event, line: String)
    case dropped(messageId: String, reason: DropReason)

    package var messageId: String {
        switch self {
        case .accepted(let event, _): return event.messageId
        case .dropped(let messageId, _): return messageId
        }
    }
}

/// The internal steps an event passes on the writer (Public API 4, Event Model 3): session, context,
/// super properties, the `beforeSend` chain, a second validation, and serialization with the 32 KB
/// check (Serialization 3). Session events the session step produces pass the same steps, right
/// before the event that caused them (Session 5).
///
/// Hook rules (Public API 4, iOS Public API 6, `HookRules`): a hook that returns `nil` drops the
/// event (`before_send`). On an automatic event the name and the top-level keys must stay and `nil`
/// is not allowed; a result that is not a copy of its input is never accepted. A breach drops the
/// event with `HOOK_VIOLATION`; with `debug` on it is a developer error first. A Swift hook cannot
/// throw: a trap stops the app, and only the Objective-C wrapper reports `HOOK_THREW`.
///
/// Runs on the writer only.
package final class EventPipeline {
    /// Serialization 3: one serialized line, UTF-8.
    package static let maxEventBytes = 32 * 1024

    package static let libraryName = "rubicon-ios"
    package static let sessionStarted = "Session Started"
    package static let sessionEnded = "Session Ended"
    package static let durationMs = "duration_ms"

    private let hooks: [BeforeSend]
    private let disabledFields: Set<ContextField>
    private let debug: Bool
    private let contextProvider: any ContextProvider
    private let sessions: SessionManager
    private let newMessageId: () -> String
    private let log: Log

    // Collected once, on first need, on the writer (Context 2).
    private lazy var staticValues: StaticValues = contextProvider.staticValues(disabled: disabledFields)

    package init(
        hooks: [BeforeSend], disabledFields: Set<ContextField>, debug: Bool, contextProvider: any ContextProvider,
        sessions: SessionManager, newMessageId: @escaping () -> String, log: Log
    ) {
        self.hooks = hooks
        self.disabledFields = disabledFields
        self.debug = debug
        self.contextProvider = contextProvider
        self.sessions = sessions
        self.newMessageId = newMessageId
        self.log = log
    }

    /// The results for `captured`, with the session events it caused first.
    package func process(_ captured: CapturedEvent) -> [PipelineResult] {
        guard let identity = captured.identity.value else {
            // The writer fills every snapshot before it processes the event; an unfilled one is an
            // SDK bug, counted like a failed write rather than crashing the host (root rules).
            log.error(.workerFailed) { "The identity of an event was not resolved before processing; it was dropped" }
            return [.dropped(messageId: captured.messageId, reason: .storageError)]
        }
        let outcome = sessions.onEvent(timestamp: captured.timestamp)
        var results: [PipelineResult] = []
        results.reserveCapacity(outcome.before.count + 1)
        for event in outcome.before {
            results.append(process(prepare(event, callTime: captured.callTime, current: identity)))
        }
        results.append(process(captured, identity: identity, session: outcome.session))
        return results
    }

    /// Session events produced outside an event: on returning to the foreground, at process start, or
    /// at a reset or user switch (Session 5). `current` is the identity now; an end caused by a person
    /// change carries its own.
    package func processSessionEvents(
        _ events: [SessionEvent], current: IdentitySnapshot, callTime: CallTimeValues
    ) -> [PipelineResult] {
        events.map { process(prepare($0, callTime: callTime, current: current)) }
    }

    private func process(_ prepared: Prepared) -> PipelineResult {
        process(prepared.captured, identity: prepared.identity, session: prepared.session)
    }

    private func process(_ captured: CapturedEvent, identity: IdentitySnapshot, session: SessionContext?)
        -> PipelineResult
    {
        let built = build(captured, identity: identity, session: session)
        let hooked: any Event
        if captured.skipsHooks {
            hooked = built
        } else {
            guard let result = runHooks(built) else {
                return .dropped(messageId: captured.messageId, reason: .beforeSend)
            }
            hooked = result
        }
        let validated = validateAgain(hooked)
        let line: String
        do {
            line = try EventWire.line(validated)
        } catch {
            // Unreachable: the second validation drops non-finite numbers, the only value the
            // writer refuses. Counted like a failed write if a Foundation change ever gets here.
            log.error(.workerFailed) { "An event could not be serialized; it was dropped" }
            return .dropped(messageId: captured.messageId, reason: .storageError)
        }
        let size = line.utf8.count
        if size > Self.maxEventBytes {
            let message = "An event of \(size) bytes is over the limit of \(Self.maxEventBytes); it was dropped"
            if debug { log.developerError(message) }
            log.warn(.eventOversize) { message }
            return .dropped(messageId: captured.messageId, reason: .oversize)
        }
        return .accepted(event: validated, line: line)
    }

    private func build(_ captured: CapturedEvent, identity: IdentitySnapshot, session: SessionContext?) -> any Event {
        let context = context(callTime(captured.callTime), session: session)
        switch captured.kind {
        case .identify:
            return IdentifyEvent(
                source: captured.source, messageId: captured.messageId, timestamp: captured.timestamp,
                userId: identity.userId, deviceId: identity.deviceId, context: context, traits: captured.values)
        case .track:
            return TrackEvent(
                source: captured.source, messageId: captured.messageId, timestamp: captured.timestamp,
                userId: identity.userId, deviceId: identity.deviceId, context: context, name: captured.name ?? "",
                properties: withSuperProperties(captured.values, identity))
        case .screen:
            return ScreenEvent(
                source: captured.source, messageId: captured.messageId, timestamp: captured.timestamp,
                userId: identity.userId, deviceId: identity.deviceId, context: context, name: captured.name ?? "",
                properties: withSuperProperties(captured.values, identity))
        }
    }

    // The event's own key wins; above 256 the super properties go first (Context 5, Serialization 3).
    private func withSuperProperties(_ own: [String: PropertyValue], _ identity: IdentitySnapshot)
        -> [String: PropertyValue]
    {
        if identity.superProperties.isEmpty { return own }
        let merged = PropertyNormalizer.mergeSuperProperties(own: own, superProperties: identity.superProperties)
        PropertyProblem.report(merged.problems, debug: debug, log: log)
        return merged.values
    }

    // Values the cache could not give at call time are taken now (Context 2).
    private func callTime(_ captured: CallTimeValues) -> CallTimeValues {
        captured.pending ? contextProvider.callTimeValues(disabled: disabledFields) : captured
    }

    // A disabled field is left out here too, whatever the provider returned (Context 6).
    private func context(_ callTime: CallTimeValues, session: SessionContext?) -> EventContext {
        let s = staticValues
        return EventContext(
            app: AppContext(
                name: on(.appName, s.appName), version: on(.appVersion, s.appVersion),
                build: on(.appBuild, s.appBuild), namespace: on(.appNamespace, s.appNamespace)),
            device: DeviceContext(
                manufacturer: on(.deviceManufacturer, s.deviceManufacturer), model: on(.deviceModel, s.deviceModel),
                type: on(.deviceType, s.deviceType), isEmulator: on(.deviceIsEmulator, s.deviceIsEmulator)),
            os: OsContext(name: on(.osName, s.osName), version: on(.osVersion, s.osVersion)),
            screen: ScreenContext(
                width: on(.screenWidth, s.screenWidth), height: on(.screenHeight, s.screenHeight),
                density: on(.screenDensity, s.screenDensity)),
            network: NetworkContext(type: on(.networkType, callTime.networkType)),
            locale: on(.locale, callTime.locale), timezone: on(.timezone, callTime.timezone), session: session,
            library: LibraryContext(name: Self.libraryName, version: SDKVersion.current))
    }

    private func on<T>(_ field: ContextField, _ value: T?) -> T? {
        disabledFields.contains(field) ? nil : value
    }

    private func runHooks(_ event: any Event) -> (any Event)? {
        var current = event
        for hook in hooks {
            let result = hook(current)
            if let violation = HookRules.check(result, against: current) {
                return self.violation(violation)
            }
            guard let result else {
                log.debug { "A beforeSend hook dropped \(current.messageId)" }
                return nil
            }
            current = result
        }
        return current
    }

    private func violation(_ violation: HookRules.Violation) -> (any Event)? {
        let problem: String
        switch violation {
        case .droppedAutomaticEvent: problem = "returned nil for an automatic event"
        case .otherKind: problem = "returned an event of another kind"
        case .changedFixedFields: problem = "returned an event that is not a copy of its input"
        case .renamedAutomaticEvent: problem = "renamed an automatic event"
        case .changedAutomaticKeys: problem = "added or removed top-level keys of an automatic event"
        case .invalidName: problem = "returned an invalid event name"
        }
        if debug { log.developerError("beforeSend: a hook \(problem)") }
        log.error(.hookViolation) { "A beforeSend hook \(problem); the event was dropped" }
        return nil
    }

    // The values a hook returned are normalized like a public call's (Event Model 3).
    private func validateAgain(_ event: any Event) -> any Event {
        switch event {
        case var track as TrackEvent:
            let normalized = PropertyNormalizer.normalize(values: track.properties)
            PropertyProblem.report(normalized.problems, debug: debug, log: log)
            if normalized.problems.isEmpty { return event }
            track.properties = normalized.values
            return track
        case var screen as ScreenEvent:
            let normalized = PropertyNormalizer.normalize(values: screen.properties)
            PropertyProblem.report(normalized.problems, debug: debug, log: log)
            if normalized.problems.isEmpty { return event }
            screen.properties = normalized.values
            return screen
        case var identify as IdentifyEvent:
            let normalized = PropertyNormalizer.normalize(values: identify.traits)
            PropertyProblem.report(normalized.problems, debug: debug, log: log)
            if normalized.problems.isEmpty { return event }
            identify.traits = normalized.values
            return identify
        default:
            // `HookRules` accepts only the three kinds; `build` creates only those.
            return event
        }
    }

    private func prepare(_ event: SessionEvent, callTime: CallTimeValues, current: IdentitySnapshot) -> Prepared {
        switch event {
        case .started(let session):
            return Prepared(
                captured: automatic(Self.sessionStarted, [:], timestamp: session.startedAt, callTime: callTime),
                identity: current, session: SessionContext(id: session.id, startedAt: session.startedAt))
        case .ended(let session, let identity):
            return Prepared(
                captured: automatic(
                    Self.sessionEnded, [Self.durationMs: .int(event.durationMs)], timestamp: session.lastActivity,
                    callTime: callTime),
                identity: identity ?? current, session: SessionContext(id: session.id, startedAt: session.startedAt))
        }
    }

    private func automatic(
        _ name: String, _ properties: [String: PropertyValue], timestamp: Date, callTime: CallTimeValues
    ) -> CapturedEvent {
        CapturedEvent(
            kind: .track, name: name, values: properties, source: .auto, messageId: newMessageId(),
            timestamp: timestamp, identity: IdentityRef(), callTime: callTime)
    }

    private struct Prepared {
        let captured: CapturedEvent
        let identity: IdentitySnapshot
        let session: SessionContext?
    }
}
