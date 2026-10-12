import Foundation
import Rubicon
import RubiconCore

/// An event as a `beforeSend` block and the event observer see it (Event Model 1, 6; iOS Event
/// Model 1): the fixed fields are read-only, the name and the properties or traits can be set on an
/// `RBNTrackEvent`, `RBNScreenEvent` or `RBNIdentifyEvent`. Only the SDK creates events; a block
/// changes the one it was given and returns it, or returns `nil` to drop an app event.
@objc(RBNEvent)
public class RBNEvent: NSObject {
    let swift: any Event

    init(swift: any Event) {
        self.swift = swift
    }

    /// Whether the app or the SDK created the event.
    @objc public var source: RBNEventSource { RBNEventSource(swift.source) }
    /// A UUIDv7, unique per event and never changed, also across retries.
    @objc public var messageId: String { swift.messageId }
    /// When the event was created.
    @objc public var timestamp: Date { swift.timestamp }
    /// The identified user, or `nil` while anonymous.
    @objc public var userId: String? { swift.userId }
    /// The installation's id.
    @objc public var deviceId: String { swift.deviceId }
    /// What the SDK measured when the event was created, in its wire form; read-only (Context 4).
    @objc public var context: [String: Any] { EventWire.contextObject(swift.context).mapValues(\.foundationValue) }

    /// The Swift event with the block's changes applied; the pipeline validates it as any result.
    var updated: any Event { swift }

    /// The view of a Swift event, by kind.
    static func view(of event: any Event) -> RBNEvent {
        switch event {
        case let track as TrackEvent: return RBNTrackEvent(track)
        case let screen as ScreenEvent: return RBNScreenEvent(screen)
        case let identify as IdentifyEvent: return RBNIdentifyEvent(identify)
        default: return RBNEvent(swift: event)
        }
    }

    static func foundation(_ values: [String: PropertyValue]) -> [String: Any] {
        values.mapValues(\.foundationValue)
    }

    static func normalized(_ values: [String: Any]) -> [String: PropertyValue] {
        PropertyNormalizer.normalize(values).values
    }
}

/// An action, sent by `trackEvent:properties:` or captured automatically.
@objc(RBNTrackEvent)
public final class RBNTrackEvent: RBNEvent {
    private var event: TrackEvent

    init(_ event: TrackEvent) {
        self.event = event
        super.init(swift: event)
    }

    /// The event name; settable for app events only (Public API 4).
    @objc public var name: String {
        get { event.name }
        set { event.name = newValue }
    }

    /// The properties, validated like a public call's when set (iOS Public API 5).
    @objc public var properties: [String: Any] {
        get { Self.foundation(event.properties) }
        set { event.properties = Self.normalized(newValue) }
    }

    override var updated: any Event { event }
}

/// A screen view, sent by `trackScreen:properties:` or captured automatically.
@objc(RBNScreenEvent)
public final class RBNScreenEvent: RBNEvent {
    private var event: ScreenEvent

    init(_ event: ScreenEvent) {
        self.event = event
        super.init(swift: event)
    }

    /// The screen name; settable for app events only (Public API 4).
    @objc public var name: String {
        get { event.name }
        set { event.name = newValue }
    }

    /// The properties, validated like a public call's when set (iOS Public API 5).
    @objc public var properties: [String: Any] {
        get { Self.foundation(event.properties) }
        set { event.properties = Self.normalized(newValue) }
    }

    override var updated: any Event { event }
}

/// The identify event of `identifyUser:traits:`.
@objc(RBNIdentifyEvent)
public final class RBNIdentifyEvent: RBNEvent {
    private var event: IdentifyEvent

    init(_ event: IdentifyEvent) {
        self.event = event
        super.init(swift: event)
    }

    /// The traits, validated like a public call's when set (iOS Public API 5).
    @objc public var traits: [String: Any] {
        get { Self.foundation(event.traits) }
        set { event.traits = Self.normalized(newValue) }
    }

    override var updated: any Event { event }
}

/// What became of an event (Logging 4c, iOS Logging 2): `queued` carries the event, `sent` and
/// `dropped` the message ids, `dropped` also the reason.
@objc(RBNEventUpdate)
public final class RBNEventUpdate: NSObject {
    /// Which update this is.
    @objc public let kind: RBNEventUpdateKind
    /// The event, for `queued` only.
    @objc public let event: RBNEvent?
    /// The message ids, for `sent` and `dropped`; the queued event's id for `queued`.
    @objc public let messageIds: [String]
    /// The reason, for `dropped` only; `queueFull` otherwise, so check `kind` first.
    @objc public let dropReason: RBNDropReason
    /// The wire name of the reason, such as `queue_full`; empty unless `kind` is `dropped`.
    @objc public var dropReasonName: String { kind == .dropped ? dropReason.name : "" }

    init(_ update: EventUpdate) {
        switch update {
        case .queued(let event):
            kind = .queued
            self.event = RBNEvent.view(of: event)
            messageIds = [event.messageId]
            dropReason = .queueFull
        case .sent(let ids):
            kind = .sent
            event = nil
            messageIds = ids
            dropReason = .queueFull
        case .dropped(let ids, let reason):
            kind = .dropped
            event = nil
            messageIds = ids
            dropReason = RBNDropReason(reason)
        }
    }

    /// The kind and the ids or the count only: never properties or traits (Logging 4).
    public override var description: String {
        switch kind {
        case .queued: return "queued(\(messageIds.first ?? ""))"
        case .sent: return "sent(\(messageIds.count) events)"
        case .dropped: return "dropped(\(messageIds.count) events, \(dropReason.name))"
        }
    }
}
