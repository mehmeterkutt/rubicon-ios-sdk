import Foundation

/// What belongs to the person using the app, cleared by `reset()` and `clearLocalData()` (Identity
/// 5). A new persisted value goes here unless it should carry over when another person logs in on
/// this device; then it belongs to `DeviceStore`. `PersonStoreTests` pins the exact keys.
package struct PersonState: Sendable, Equatable {
    /// `nil` while anonymous.
    package var userId: String?
    /// Normalized values, as `register` stored them (Context 5).
    package var superProperties: [String: PropertyValue]
    package var session: SessionState?

    package init(userId: String? = nil, superProperties: [String: PropertyValue] = [:], session: SessionState? = nil) {
        self.userId = userId
        self.superProperties = superProperties
        self.session = session
    }

    package static let anonymous = PersonState()
}

/// The open session (Session 6); wall-clock times.
package struct SessionState: Sendable, Equatable {
    package var id: String
    package var startedAt: Date
    package var lastActivity: Date

    package init(id: String, startedAt: Date, lastActivity: Date) {
        self.id = id
        self.startedAt = startedAt
        self.lastActivity = lastActivity
    }
}

/// `person.json` (Disk 7): `{"v":1,"user_id":..,"super_properties":{..},"session":{"id",
/// "started_at","last_activity"}}`. Missing: anonymous, written at once. Unreadable: anonymous in
/// memory, the file left untouched (Identity 1). Locked: not loaded; `load` runs again later.
package final class PersonStore: Sendable {
    package static let fileName = "person.json"
    package static let userId = "user_id"
    package static let superProperties = "super_properties"
    package static let session = "session"
    package static let sessionId = "id"
    package static let startedAt = "started_at"
    package static let lastActivity = "last_activity"

    private let file: StoreFile<Codec>

    package init(keyValueStore: any KeyValueStore, log: Log) {
        file = StoreFile(name: Self.fileName, keyValueStore: keyValueStore, log: log, codec: Codec())
    }

    /// Reads the file; on the writer, before anything else uses the store. `false` while locked.
    @discardableResult
    package func load() -> Bool {
        file.load(onMissing: { .anonymous }, onUnreadable: { .anonymous })
    }

    package var isLoaded: Bool { file.isLoaded }
    package var isLocked: Bool { file.isLocked }

    /// The state; `nil` until loaded.
    package var state: PersonState? { file.value }

    /// Changes the state in memory at once; `persist` writes it later.
    package func update(_ transform: (PersonState) -> PersonState) {
        file.update { transform($0 ?? .anonymous) }
    }

    /// Writes the latest state if it changed; on the writer only.
    @discardableResult
    package func persist() -> Bool {
        file.persist()
    }

    struct Codec: StoreCodec {
        func encode(_ value: PersonState) -> [String: PropertyValue] {
            [
                PersonStore.userId: value.userId.map(PropertyValue.string) ?? .null,
                PersonStore.superProperties: .object(value.superProperties),
                PersonStore.session: value.session.map {
                    .object([
                        PersonStore.sessionId: .string($0.id), PersonStore.startedAt: .int($0.startedAt.epochMillis),
                        PersonStore.lastActivity: .int($0.lastActivity.epochMillis),
                    ])
                } ?? .null,
            ]
        }

        func decode(_ fields: JsonFields) -> PersonState? {
            let f = StoreFields(fields)
            do {
                var session: SessionState?
                if let s = try f.optionalFields(PersonStore.session) {
                    session = SessionState(
                        id: try s.requiredString(PersonStore.sessionId),
                        startedAt: try s.requiredDate(PersonStore.startedAt),
                        lastActivity: try s.requiredDate(PersonStore.lastActivity))
                }
                return PersonState(
                    userId: try f.optionalString(PersonStore.userId),
                    superProperties: try f.optionalObject(PersonStore.superProperties) ?? [:], session: session)
            } catch {
                return nil
            }
        }
    }
}
