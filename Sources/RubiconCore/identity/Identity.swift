import Foundation

/// Who an event belongs to, taken when the event is tracked (Public API 9).
package struct IdentitySnapshot: Sendable, Equatable, CustomStringConvertible {
    /// `nil` while anonymous.
    package let userId: String?
    package let deviceId: String
    package let superProperties: [String: PropertyValue]

    package init(userId: String?, deviceId: String, superProperties: [String: PropertyValue]) {
        self.userId = userId
        self.deviceId = deviceId
        self.superProperties = superProperties
    }

    package var description: String { "IdentitySnapshot(\(superProperties.count) super properties)" }
}

/// An identity snapshot that may not exist yet: taken before the stores were loaded, it is filled
/// when the writer loads them, in call order, before the event it belongs to is processed.
package final class IdentityRef: Sendable {
    private let stored = Locked<IdentitySnapshot?>(nil)

    package init() {}

    package var value: IdentitySnapshot? { stored.current }

    fileprivate func fill(_ snapshot: IdentitySnapshot) {
        stored.withLock { $0 = snapshot }
    }
}

/// Whether an `identify` call produces an identify event; decided now, or at load.
package final class IdentifyTicket: Sendable {
    package enum Decision: Sendable, Equatable {
        case noEvent
        /// `traits` are normalized, sent with this event only and never stored (Identity 3).
        case sendEvent(traits: [String: PropertyValue], identity: IdentitySnapshot)
    }

    private let stored = Locked<Decision?>(nil)

    package init() {}

    package var decision: Decision? { stored.current }

    fileprivate func decide(_ decision: Decision) {
        stored.withLock { $0 = decision }
    }
}

/// The identity of the instance (Identity 1 to 5; Context 5): the user id and super properties in
/// `PersonStore`, the device id in `DeviceStore`.
///
/// - Every call changes memory at once on the calling thread and asks the writer to persist
///   (`requestPersist`), so a `track` after `identify` carries the new id (Public API 9).
/// - Before `load`, when the writer has not read the stores yet, calls are kept in call order and
///   applied at `load`; snapshots taken meanwhile are filled at the same point (Android log 6.1).
///   On iOS that also covers a process that started before the first unlock: the writer calls
///   `load` once protected data is available (iOS Disk 1).
/// - Validation runs on the calling thread before anything is kept: a blank or too long user id and
///   an unsupported super property are developer errors with `debug` on, and are ignored with a WARN.
///
/// `eventsAllowed` is `false` while opted out: `identify` then updates local state without an event
/// (Privacy 1). `onPersonCleared` is called with the identity before `reset()` or a user switch
/// cleared the person's state, for the session to end with the old user (Session 6, step 6.2).
// Mutable state (`loaded`, `pending`) is guarded by `lock`; the stores are thread-safe themselves.
package final class Identity: @unchecked Sendable {
    /// Identity 3: 1 to 255 characters, never trimmed. Counted in UTF-16 units, as every limit is.
    package static let maxUserIdLength = 255

    private let personStore: PersonStore
    private let deviceStore: DeviceStore
    private let log: Log
    private let debug: Bool
    private let eventsAllowed: @Sendable () -> Bool
    private let requestPersist: @Sendable () -> Void
    private let onPersonCleared: @Sendable (IdentitySnapshot) -> Void

    // A callback may call back into the identity (a session hook taking a snapshot), so the lock
    // is recursive, as `synchronized` is on Android.
    private let lock = NSRecursiveLock()
    // Guarded by `lock`.
    private var loaded = false
    private var pending: [() -> Void] = []

    package init(
        personStore: PersonStore, deviceStore: DeviceStore, log: Log, debug: Bool,
        eventsAllowed: @escaping @Sendable () -> Bool, requestPersist: @escaping @Sendable () -> Void,
        onPersonCleared: @escaping @Sendable (IdentitySnapshot) -> Void = { _ in }
    ) {
        self.personStore = personStore
        self.deviceStore = deviceStore
        self.log = log
        self.debug = debug
        self.eventsAllowed = eventsAllowed
        self.requestPersist = requestPersist
        self.onPersonCleared = onPersonCleared
    }

    /// Applies the calls made before the stores were loaded, in order; on the writer, after
    /// `DeviceStore.load` and `PersonStore.load` succeeded.
    package func load() {
        lock.lock()
        defer { lock.unlock() }
        let queued = pending
        pending = []
        for block in queued { block() }
        loaded = true
    }

    /// The installation id; reads `device.json` on this thread only if the writer has not yet.
    /// `""` while the device is locked before the first unlock, the no-op instance's value, until
    /// the writer loads the store (iOS Disk 1).
    package var deviceId: String {
        deviceStore.readEarly()
        return deviceStore.state?.deviceId ?? ""
    }

    /// The identity for an event tracked now.
    package func snapshot() -> IdentityRef {
        let ref = IdentityRef()
        whenLoaded { [self] in ref.fill(current()) }
        return ref
    }

    /// Applies the rules of Identity 3 and 4. Returns `nil` when `userId` is invalid and the call was
    /// ignored; a developer error first when `debug` is on.
    package func identify(_ userId: String, traits: [String: Any]) -> IdentifyTicket? {
        let blank = userId.allSatisfy(\.isWhitespace)
        if blank || userId.utf16.count > Self.maxUserIdLength {
            let reason = blank ? "blank" : "longer than \(Self.maxUserIdLength) characters"
            if debug { log.developerError("identify: the user id is \(reason)") }
            log.warn(.invalidUserId) { "identify was called with a user id that is \(reason); the call is ignored" }
            return nil
        }
        let normalized = PropertyNormalizer.normalize(traits)
        PropertyProblem.report(normalized.problems, debug: debug, log: log)
        let ticket = IdentifyTicket()
        whenLoaded { [self] in ticket.decide(applyIdentify(userId, traits: normalized.values)) }
        return ticket
    }

    /// Back to anonymous: clears the person's state, never the device's (Identity 5). No event.
    package func reset() {
        whenLoaded { [self] in
            clearPerson()
            persist()
        }
    }

    /// The identity part of `clearLocalData()` (Privacy 3): the person's state is cleared and the
    /// device gets `newDeviceId`, without retry state or drop counters; consent, the last version and
    /// build, and the remote configuration stay. No event, no `Session Ended`. Later calls on this
    /// thread see the new identity at once; the writer deletes the queue and the session.
    package func clearLocalData(newDeviceId: String) {
        whenLoaded { [self] in
            personStore.update { _ in .anonymous }
            deviceStore.update { state in
                with(state) {
                    $0.deviceId = newDeviceId
                    $0.retry = .none
                    $0.diagnostics = .empty
                }
            }
            persist()
        }
    }

    /// Adds a super property, validated now with the property rules (Context 5); `nil` and `NSNull`
    /// are the value `null`. Returns `false` when `value` or `key` was dropped and nothing changed.
    @discardableResult
    package func register(_ key: String, value: Any) -> Bool {
        let normalized = PropertyNormalizer.normalize([key: value])
        PropertyProblem.report(normalized.problems, debug: debug, log: log)
        guard let stored = normalized.values[key] else { return false }
        whenLoaded { [self] in
            personStore.update { state in with(state) { $0.superProperties[key] = stored } }
            persist()
        }
        return true
    }

    package func unregister(_ key: String) {
        whenLoaded { [self] in
            personStore.update { state in
                guard state.superProperties[key] != nil else { return state }
                return with(state) { $0.superProperties[key] = nil }
            }
            persist()
        }
    }

    private func applyIdentify(_ userId: String, traits: [String: PropertyValue]) -> IdentifyTicket.Decision {
        let known = personStore.state?.userId
        let send: Bool
        if known == nil {
            personStore.update { state in with(state) { $0.userId = userId } }
            send = true
        } else if known == userId {
            send = !traits.isEmpty
        } else {
            clearPerson()
            // Never the ids themselves (Logging 4a).
            log.info { "A different user was identified; the previous person's state was reset" }
            personStore.update { state in with(state) { $0.userId = userId } }
            send = true
        }
        persist()
        return send && eventsAllowed() ? .sendEvent(traits: traits, identity: current()) : .noEvent
    }

    private func clearPerson() {
        let previous = current()
        personStore.update { _ in .anonymous }
        onPersonCleared(previous)
    }

    private func current() -> IdentitySnapshot {
        let person = personStore.state ?? .anonymous
        return IdentitySnapshot(
            userId: person.userId, deviceId: deviceStore.state?.deviceId ?? "", superProperties: person.superProperties)
    }

    private func persist() {
        requestPersist()
    }

    // Runs now when the stores are loaded, else at load, in call order.
    private func whenLoaded(_ block: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if loaded { block() } else { pending.append(block) }
    }
}
