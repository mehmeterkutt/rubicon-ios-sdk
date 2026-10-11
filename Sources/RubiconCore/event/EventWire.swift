import Foundation

/// The wire form of events (Event Model 1, 2, 5; Serialization 4): `snake_case` keys written by
/// hand, so the contract is visible here, and epoch milliseconds for times (iOS Event Model 2).
/// One line per event is exactly what is stored and sent (Disk 3). The golden files under
/// `Tests/RubiconCoreTests/Fixtures/golden` pin it.
///
/// - `user_id` is always present, `null` while anonymous, since it is part of the event's identity.
/// - A context value that is `nil` is omitted, and so is a context group left empty.
package enum EventWire {
    /// The compact JSON line of `event`.
    package static func line(_ event: any Event) throws(JsonError) -> String {
        try Json.write(toObject(event))
    }

    package static func toObject(_ event: any Event) -> [String: PropertyValue] {
        var object: [String: PropertyValue] = [:]
        switch event {
        case let track as TrackEvent:
            object["type"] = .string("track")
            object["event"] = .string(track.name)
            object["properties"] = .object(track.properties)
        case let screen as ScreenEvent:
            object["type"] = .string("screen")
            object["name"] = .string(screen.name)
            object["properties"] = .object(screen.properties)
        case let identify as IdentifyEvent:
            object["type"] = .string("identify")
            object["traits"] = .object(identify.traits)
        default:
            // A conformance from outside the SDK never reaches the writer: the pipeline accepts
            // only the three kinds (iOS Event Model 1).
            object["type"] = .string("unknown")
        }
        object["source"] = .string(event.source.rawValue)
        object["message_id"] = .string(event.messageId)
        object["timestamp"] = .int(event.timestamp.epochMillis)
        object["user_id"] = event.userId.map(PropertyValue.string) ?? .null
        object["device_id"] = .string(event.deviceId)
        object["context"] = .object(contextObject(event.context))
        return object
    }

    private static func contextObject(_ context: EventContext) -> [String: PropertyValue] {
        var object: [String: PropertyValue] = [:]
        group(
            &object, "app",
            [
                ("name", context.app.name.map(PropertyValue.string)),
                ("version", context.app.version.map(PropertyValue.string)),
                ("build", context.app.build.map(PropertyValue.string)),
                ("namespace", context.app.namespace.map(PropertyValue.string)),
            ])
        group(
            &object, "device",
            [
                ("manufacturer", context.device.manufacturer.map(PropertyValue.string)),
                ("model", context.device.model.map(PropertyValue.string)),
                ("type", context.device.type.map(PropertyValue.string)),
                ("is_emulator", context.device.isEmulator.map(PropertyValue.bool)),
            ])
        group(
            &object, "os",
            [
                ("name", context.os.name.map(PropertyValue.string)),
                ("version", context.os.version.map(PropertyValue.string)),
            ])
        group(
            &object, "screen",
            [
                ("width", context.screen.width.map { PropertyValue.int(Int64($0)) }),
                ("height", context.screen.height.map { PropertyValue.int(Int64($0)) }),
                ("density", context.screen.density.map(PropertyValue.double)),
            ])
        group(&object, "network", [("type", context.network.type.map(PropertyValue.string))])
        if let locale = context.locale { object["locale"] = .string(locale) }
        if let timezone = context.timezone { object["timezone"] = .string(timezone) }
        if let session = context.session {
            object["session"] = .object(["id": .string(session.id), "started_at": .int(session.startedAt.epochMillis)])
        }
        object["library"] = .object([
            "name": .string(context.library.name), "version": .string(context.library.version),
        ])
        return object
    }

    private static func group(
        _ object: inout [String: PropertyValue], _ name: String, _ fields: [(String, PropertyValue?)]
    ) {
        var present: [String: PropertyValue] = [:]
        for (key, value) in fields {
            if let value { present[key] = value }
        }
        if !present.isEmpty { object[name] = .object(present) }
    }
}
