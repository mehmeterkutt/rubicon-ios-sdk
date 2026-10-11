import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("PersonStore")
struct PersonStoreTests {
    let support = StoreTestSupport()

    private func store() -> PersonStore { PersonStore(keyValueStore: support.files, log: support.log) }

    private func loaded() -> PersonStore {
        let store = store()
        store.load()
        return store
    }

    let identified = PersonState(
        userId: "user-42",
        superProperties: [
            "plan": .string("pro"), "beta": .bool(true), "tags": .array([.string("a"), .string("b")]), "gone": .null,
        ],
        session: SessionState(
            id: "0192e49f-0b1c-7d2e-8f3a-4b5c6d7e8f90", startedAt: Date(epochMillis: 1_759_147_082_000),
            lastActivity: Date(epochMillis: 1_759_147_260_000)))

    @Test("person.json has exactly the decided keys and reads back as written")
    func keys() throws {
        let store = loaded()
        store.update { _ in identified }
        store.persist()

        let stored = try support.stored(PersonStore.fileName)
        #expect(Set(stored.keys) == ["v", "user_id", "super_properties", "session"])
        guard case .object(let session)? = stored["session"] else {
            Issue.record("session missing")
            return
        }
        #expect(Set(session.keys) == ["id", "started_at", "last_activity"])
        #expect(session["started_at"] == .number(1_759_147_082_000))
        #expect(loaded().state == identified)
    }

    @Test("an anonymous person is written with null user and session, at once")
    func anonymous() throws {
        let store = loaded()
        #expect(store.state == .anonymous)
        #expect(support.writeCount == 1)
        let stored = try support.stored(PersonStore.fileName)
        #expect(stored["user_id"] == .null)
        #expect(stored["session"] == .null)
        #expect(stored["v"] == .number(1))
    }

    @Test("an unreadable file is anonymous in memory and never written")
    func unreadable() throws {
        try support.writeRaw(PersonStore.fileName, "{}")
        let writes = support.writeCount
        let store = loaded()
        store.update { _ in identified }
        store.persist()
        #expect(store.state == identified)
        #expect(support.writeCount == writes)
        #expect(support.warned(.storeUnreadable))
    }

    @Test(
        "files that cannot be used are left byte-identical",
        arguments: [
            #"{"v":1,"user_id":"user-42","#,
            #"{"v":2,"user_id":"user-42","super_properties":{},"session":null}"#,
            #"{"user_id":"user-42","super_properties":{},"session":null}"#,
            #"{"v":1,"user_id":42,"super_properties":{},"session":null}"#,
            #"{"v":1,"user_id":null,"super_properties":{},"session":{"id":"s"}}"#,
            #"{"v":1,"user_id":null,"super_properties":[],"session":null}"#,
        ])
    func untouched(content: String) throws {
        try support.writeRaw(PersonStore.fileName, content)
        let before = try support.rawBytes(PersonStore.fileName)
        let store = loaded()
        store.update { _ in identified }
        store.persist()
        #expect(store.state == identified)
        #expect(try support.rawBytes(PersonStore.fileName) == before)
        #expect(support.warned(.storeUnreadable))
    }

    @Test("many updates in a row produce one write; nothing is written when nothing changed")
    func coalesced() {
        let store = loaded()
        let writes = support.writeCount
        for i in 0..<50 { store.update { with($0) { $0.superProperties["n"] = .int(Int64(i)) } } }
        store.persist()
        #expect(support.writeCount == writes + 1)
        #expect(loaded().state?.superProperties["n"] == .int(49))

        store.update { $0 }
        store.persist()
        #expect(support.writeCount == writes + 1)
    }

    @Test("a failed write logs an error and is retried by the next persist")
    func failedWrite() {
        let store = loaded()
        support.test.fileSystem.failAlways(.openWrite)
        store.update { _ in identified }

        #expect(!store.persist())
        #expect(support.errored(.storageWriteFailed))

        support.test.fileSystem.heal()
        #expect(store.persist())
        #expect(loaded().state == identified)
    }

    @Test("a change is visible in memory before it is written")
    func inMemoryFirst() throws {
        let store = loaded()
        store.update { with($0) { $0.userId = "user-7" } }
        #expect(store.state?.userId == "user-7")
        #expect(try support.stored(PersonStore.fileName)["user_id"] == .null)
    }

    @Test("a locked device defers the load without a warning")
    func locked() throws {
        try support.writeRaw(PersonStore.fileName, #"{"v":1,"user_id":"u","super_properties":{},"session":null}"#)
        support.test.fileSystem.locked = true
        let store = store()
        #expect(!store.load())
        #expect(store.state == nil)
        #expect(store.isLocked)
        #expect(!support.warned(.storeUnreadable))
        support.test.fileSystem.locked = false
        #expect(store.load())
        #expect(store.state?.userId == "u")
    }
}
