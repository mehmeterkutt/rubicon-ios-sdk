import Foundation

/// An event as `beforeSend` hooks and the `eventObserver` see it (Event Model 2, 6; iOS Event
/// Model 1). Only the SDK creates events. The fixed fields are constants; a hook copies the event,
/// changes `name` and `properties` or `traits` on its copy and returns it. For an automatic event
/// (`source == .auto`) only property values may change: see `BeforeSend`.
///
/// Kinds may be added in minor versions: a hook should return a kind it does not know unchanged.
///
/// ```swift
/// config.beforeSend = [{ event in
///     guard var track = event as? TrackEvent else { return event }
///     track.properties["email"] = nil
///     return track
/// }]
/// ```
public protocol Event: Sendable {
    /// Whether the app or the SDK created the event.
    var source: EventSource { get }
    /// A UUIDv7, unique per event and never changed, also across retries.
    var messageId: String { get }
    /// When the event was created.
    var timestamp: Date { get }
    /// The identified user, or `nil` while anonymous.
    var userId: String? { get }
    /// The installation's id.
    var deviceId: String { get }
    /// What the SDK measured when the event was created; read-only for hooks (Context 4).
    var context: EventContext { get }
}

/// An action, sent by `track` or captured automatically, such as `Application Opened`.
public struct TrackEvent: Event, Equatable {
    /// Whether the app or the SDK created the event.
    public let source: EventSource
    /// A UUIDv7, unique per event and never changed, also across retries.
    public let messageId: String
    /// When the event was created.
    public let timestamp: Date
    /// The identified user, or `nil` while anonymous.
    public let userId: String?
    /// The installation's id.
    public let deviceId: String
    /// What the SDK measured when the event was created; read-only for hooks.
    public let context: EventContext
    /// The event name, such as `Purchase Completed`.
    public var name: String
    /// The event's properties, super properties merged in.
    public var properties: [String: PropertyValue]

    package init(
        source: EventSource, messageId: String, timestamp: Date, userId: String?, deviceId: String,
        context: EventContext, name: String, properties: [String: PropertyValue]
    ) {
        self.source = source
        self.messageId = messageId
        self.timestamp = timestamp
        self.userId = userId
        self.deviceId = deviceId
        self.context = context
        self.name = name
        self.properties = properties
    }
}

/// A screen view, sent by `screen` or captured automatically for a view controller.
public struct ScreenEvent: Event, Equatable {
    /// Whether the app or the SDK created the event.
    public let source: EventSource
    /// A UUIDv7, unique per event and never changed, also across retries.
    public let messageId: String
    /// When the event was created.
    public let timestamp: Date
    /// The identified user, or `nil` while anonymous.
    public let userId: String?
    /// The installation's id.
    public let deviceId: String
    /// What the SDK measured when the event was created; read-only for hooks.
    public let context: EventContext
    /// The screen name, the same key on every platform, such as `checkout`.
    public var name: String
    /// The screen view's properties, super properties merged in.
    public var properties: [String: PropertyValue]

    package init(
        source: EventSource, messageId: String, timestamp: Date, userId: String?, deviceId: String,
        context: EventContext, name: String, properties: [String: PropertyValue]
    ) {
        self.source = source
        self.messageId = messageId
        self.timestamp = timestamp
        self.userId = userId
        self.deviceId = deviceId
        self.context = context
        self.name = name
        self.properties = properties
    }
}

/// Who the user is, sent by `identify`. `traits` are sent with this event only and never stored.
public struct IdentifyEvent: Event, Equatable {
    /// Whether the app or the SDK created the event.
    public let source: EventSource
    /// A UUIDv7, unique per event and never changed, also across retries.
    public let messageId: String
    /// When the event was created.
    public let timestamp: Date
    /// The identified user, or `nil` while anonymous.
    public let userId: String?
    /// The installation's id.
    public let deviceId: String
    /// What the SDK measured when the event was created; read-only for hooks.
    public let context: EventContext
    /// The user's traits, as passed to `identify`.
    public var traits: [String: PropertyValue]

    package init(
        source: EventSource, messageId: String, timestamp: Date, userId: String?, deviceId: String,
        context: EventContext, traits: [String: PropertyValue]
    ) {
        self.source = source
        self.messageId = messageId
        self.timestamp = timestamp
        self.userId = userId
        self.deviceId = deviceId
        self.context = context
        self.traits = traits
    }
}

extension TrackEvent: CustomStringConvertible {
    /// The type, name and message id only: never properties (Logging 4).
    public var description: String { "TrackEvent(name: \(name), messageId: \(messageId))" }
}

extension ScreenEvent: CustomStringConvertible {
    /// The type, name and message id only: never properties (Logging 4).
    public var description: String { "ScreenEvent(name: \(name), messageId: \(messageId))" }
}

extension IdentifyEvent: CustomStringConvertible {
    /// The type and message id only: never traits (Logging 4).
    public var description: String { "IdentifyEvent(messageId: \(messageId))" }
}

/// A hook that sees each event before it is stored, set with `AnalyticsConfiguration.beforeSend`
/// (Public API 4, iOS Public API 6). It sees the app's events and the automatic ones, but never
/// `SDK Diagnostics`. It runs on the thread that called the SDK and must not trap.
///
/// - For the app's own events (`source == .app`) return the event, a copy with any name and
///   properties or traits, or `nil` to drop it.
/// - For automatic events (`source == .auto`) only the values of properties may change, for
///   example to mask a token: the name stays, the same top-level keys come out as went in, and
///   `nil` is not allowed. A value may become `.null` or another type, and nested values are free.
///   To stop an automatic event, switch its type off in `autocapture.enabled`; to name automatic
///   screens, conform the view controller to `ScreenNamed`.
///
/// A hook that returns what these rules do not allow, another kind, or an event with changed fixed
/// fields drops the event; with `debug` on, that is a developer error.
///
/// ```swift
/// config.beforeSend = [{ event in
///     guard var track = event as? TrackEvent, track.source == .auto else { return event }
///     track.properties = track.properties.mapValues { value in
///         if case let .string(text) = value { return .string(text.replacingOccurrences(of: inviteCode, with: "/invite/:code", options: .regularExpression)) }
///         return value
///     }
///     return track
/// }]
/// ```
public typealias BeforeSend = @Sendable (any Event) -> (any Event)?

/// Hears what became of each event, set with `logging.eventObserver` (Logging 4c, iOS Logging 2):
/// for QA screens in debug builds and for tests. Called on the SDK's queues, never on the main
/// thread; keep it fast and do not call the SDK from it (such calls are ignored).
public typealias EventObserver = @Sendable (EventUpdate) -> Void

/// What became of events (Logging 4c). Cases may be added in minor versions; a `switch` over it
/// should keep a `default`.
public enum EventUpdate: Sendable {
    /// The event passed the hooks and validation and was stored, exactly as it will be sent.
    case queued(any Event)
    /// The server accepted a batch with these events.
    case sent(messageIds: [String])
    /// These events were dropped for `reason`; events dropped before they were stored are included.
    case dropped(messageIds: [String], reason: DropReason)
}

extension EventUpdate: CustomStringConvertible {
    /// The message id or the count and reason only: never properties or traits (Logging 4).
    public var description: String {
        switch self {
        case .queued(let event): return "queued(\(event.messageId))"
        case .sent(let ids): return "sent(\(ids.count) events)"
        case .dropped(let ids, let reason): return "dropped(\(ids.count) events, \(reason.rawValue))"
        }
    }
}
