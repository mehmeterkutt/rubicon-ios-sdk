import Foundation

/// What a `beforeSend` result must be for the pipeline to accept it (Public API 4, Android log 6.3
/// and 3.2, iOS Event Model 1): the input's own kind with the input's fixed fields; for an
/// automatic event the same name and the same top-level keys, and never `nil`. Checked by the
/// pipeline (step 6.3a); the rules live here, next to the types they describe.
package enum HookRules {
    package enum Violation: Sendable, Equatable {
        /// `nil` for an automatic event.
        case droppedAutomaticEvent
        /// Another kind, or a conformance from outside the SDK.
        case otherKind
        /// A fixed field (source, ids, timestamp, context) differs from the input's.
        case changedFixedFields
        /// An automatic event with a new name.
        case renamedAutomaticEvent
        /// An automatic event with added or removed top-level keys.
        case changedAutomaticKeys
        /// A name that is blank or longer than 255 characters.
        case invalidName
    }

    /// `nil` when `result` is acceptable for `input`; a `nil` result is acceptable only for the
    /// app's own events.
    package static func check(_ result: (any Event)?, against input: any Event) -> Violation? {
        guard let result else {
            return input.source == .auto ? .droppedAutomaticEvent : nil
        }
        switch (input, result) {
        case (let a as TrackEvent, let b as TrackEvent):
            return check(fixed: a, b) ?? checkNamed(a.source, a.name, a.properties, b.name, b.properties)
        case (let a as ScreenEvent, let b as ScreenEvent):
            return check(fixed: a, b) ?? checkNamed(a.source, a.name, a.properties, b.name, b.properties)
        case (let a as IdentifyEvent, let b as IdentifyEvent):
            return check(fixed: a, b) ?? checkKeys(a.source, a.traits, b.traits)
        default:
            return .otherKind
        }
    }

    private static func check(fixed a: any Event, _ b: any Event) -> Violation? {
        let same =
            a.source == b.source && a.messageId == b.messageId && a.timestamp == b.timestamp && a.userId == b.userId
            && a.deviceId == b.deviceId && a.context == b.context
        return same ? nil : .changedFixedFields
    }

    private static func checkNamed(
        _ source: EventSource, _ inputName: String, _ inputProperties: [String: PropertyValue], _ name: String,
        _ properties: [String: PropertyValue]
    ) -> Violation? {
        if PropertyNormalizer.checkName(name) != nil { return .invalidName }
        guard source == .auto else { return nil }
        if name != inputName { return .renamedAutomaticEvent }
        return checkKeys(source, inputProperties, properties)
    }

    private static func checkKeys(
        _ source: EventSource, _ input: [String: PropertyValue], _ output: [String: PropertyValue]
    ) -> Violation? {
        guard source == .auto else { return nil }
        return Set(input.keys) == Set(output.keys) ? nil : .changedAutomaticKeys
    }
}
