import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The port of the Android `IdentityTest`; the Android test names are kept.
@Suite("Identity")
struct IdentityTests {
    final class Fixture: @unchecked Sendable {
        let support = StoreTestSupport()
        let clock = TestClock(start: Date(epochMillis: 1_759_147_000_000))
        let optedOut = Locked(false)
        let persistRequests = Locked(0)
        let cleared = Locked<[IdentitySnapshot]>([])
        let ids = Locked(0)

        var developerErrors: [String] { support.test.developerErrors.current }

        func stores() -> (PersonStore, DeviceStore) {
            let device = DeviceStore(
                keyValueStore: support.files, log: debugLog, clock: clock,
                newDeviceId: { [ids] in
                    ids.withLock {
                        $0 += 1
                        return "device-\($0)"
                    }
                })
            return (PersonStore(keyValueStore: support.files, log: debugLog), device)
        }

        /// The support's log, but recording developer errors instead of trapping.
        lazy var debugLog: Log = support.test.log()

        func identity(debug: Bool = false, load: Bool = true) -> (Identity, PersonStore, DeviceStore) {
            let (person, device) = stores()
            let identity = Identity(
                personStore: person, deviceStore: device, log: debugLog, debug: debug,
                eventsAllowed: { [optedOut] in !optedOut.current },
                requestPersist: { [persistRequests] in persistRequests.withLock { $0 += 1 } },
                onPersonCleared: { [cleared] snapshot in cleared.withLock { $0.append(snapshot) } })
            if load { loadAll(identity, person, device) }
            return (identity, person, device)
        }

        // What the writer does first (Privacy 2), then the identity's replay.
        func loadAll(_ identity: Identity, _ person: PersonStore, _ device: DeviceStore) {
            device.load()
            person.load()
            identity.load()
        }

        func warned(_ code: Code) -> Bool { support.warned(code) }
        var infoLines: [String] { support.test.logger.lines.filter { $0.level == .info }.map(\.message) }
        var messages: [String] { support.test.logger.lines.map(\.message) }
    }

    let f = Fixture()

    private func sent(_ ticket: IdentifyTicket?) throws -> (traits: [String: PropertyValue], identity: IdentitySnapshot)
    {
        guard case .sendEvent(let traits, let identity)? = ticket?.decision else {
            throw Failure("no identify event was decided: \(String(describing: ticket?.decision))")
        }
        return (traits, identity)
    }

    private func current(_ identity: Identity) throws -> IdentitySnapshot {
        guard let value = identity.snapshot().value else { throw Failure("the snapshot is not filled") }
        return value
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: identify rules

    @Test("anonymous: the id is set and an identify event is sent")
    func anonymousIdentify() throws {
        let (identity, person, _) = f.identity()

        let event = try sent(identity.identify("user-42", traits: ["plan": "pro"]))

        #expect(person.state?.userId == "user-42")
        #expect(event.traits == ["plan": .string("pro")])
        #expect(event.identity.userId == "user-42")
        #expect(event.identity.deviceId == "device-1")
    }

    @Test("anonymous without traits still sends the identify event")
    func anonymousWithoutTraits() throws {
        let (identity, _, _) = f.identity()
        #expect(try sent(identity.identify("user-42", traits: [:])).traits.isEmpty)
    }

    @Test("the same id with traits sends an identify event")
    func sameIdWithTraits() throws {
        let (identity, _, _) = f.identity()
        _ = identity.identify("user-42", traits: [:])

        #expect(try sent(identity.identify("user-42", traits: ["plan": "free"])).traits == ["plan": .string("free")])
    }

    @Test("the same id without traits does nothing")
    func sameIdWithoutTraits() throws {
        let (identity, _, _) = f.identity()
        _ = identity.identify("user-42", traits: [:])
        identity.register("plan", value: "pro")

        #expect(identity.identify("user-42", traits: [:])?.decision == .noEvent)
        #expect(try current(identity).superProperties == ["plan": .string("pro")])
        #expect(f.cleared.current.isEmpty)
    }

    @Test("a different id clears the person's state first, logs INFO without ids and sends")
    func differentId() throws {
        let (identity, person, _) = f.identity()
        _ = identity.identify("user-42", traits: [:])
        identity.register("plan", value: "pro")
        person.update {
            with($0) {
                $0.session = SessionState(id: "s1", startedAt: Date(epochMillis: 1), lastActivity: Date(epochMillis: 2))
            }
        }

        let event = try sent(identity.identify("user-77", traits: [:]))

        #expect(person.state?.userId == "user-77")
        #expect(person.state?.superProperties == [:])
        #expect(person.state?.session == nil)
        #expect(event.identity.userId == "user-77")
        #expect(f.cleared.current.map(\.userId) == ["user-42"])
        #expect(f.cleared.current.first?.superProperties == ["plan": .string("pro")])
        let info = try #require(f.infoLines.first)
        #expect(f.infoLines.count == 1)
        #expect(!info.contains("user-42") && !info.contains("user-77"))
    }

    @Test("while opted out the id changes but no event is sent")
    func optedOut() {
        let (identity, person, _) = f.identity()
        f.optedOut.withLock { $0 = true }

        #expect(identity.identify("user-42", traits: ["plan": "pro"])?.decision == .noEvent)
        #expect(person.state?.userId == "user-42")
    }

    @Test("traits are normalized and never stored")
    func traitsNeverStored() throws {
        let (identity, person, _) = f.identity()

        let event = try sent(identity.identify("user-42", traits: ["trait_plan": "trait-value", "signup": Data([1])]))
        person.persist()

        #expect(event.traits == ["trait_plan": .string("trait-value")])
        #expect(f.warned(.propertyDropped))
        guard case .present(let stored) = f.support.files.read(PersonStore.fileName) else {
            throw Failure("person.json is not present")
        }
        #expect(stored.contains("user-42"))
        #expect(!stored.contains("trait_plan") && !stored.contains("trait-value"))
    }

    // MARK: invalid user ids

    @Test("blank and 256-character ids are ignored with a warning in release")
    func invalidIdsRelease() {
        let (identity, person, _) = f.identity(debug: false)

        #expect(identity.identify("", traits: [:]) == nil)
        #expect(identity.identify("   ", traits: [:]) == nil)
        #expect(identity.identify(String(repeating: "x", count: 256), traits: [:]) == nil)

        #expect(person.state?.userId == nil)
        #expect(f.warned(.invalidUserId))
        #expect(!f.messages.contains { $0.contains(String(repeating: "x", count: 20)) })
        #expect(f.developerErrors.isEmpty)
    }

    @Test("blank and 256-character ids are developer errors in debug")
    func invalidIdsDebug() {
        let (identity, person, _) = f.identity(debug: true)

        #expect(identity.identify(" ", traits: [:]) == nil)
        #expect(identity.identify(String(repeating: "x", count: 256), traits: [:]) == nil)

        #expect(person.state?.userId == nil)
        #expect(
            f.developerErrors == [
                "identify: the user id is blank", "identify: the user id is longer than 255 characters",
            ])
    }

    @Test("255 characters are fine and ids are never trimmed")
    func maxLength() {
        let (identity, person, _) = f.identity()

        _ = identity.identify(String(repeating: "x", count: 255), traits: [:])
        #expect(person.state?.userId?.utf16.count == 255)
        _ = identity.identify(" user-42 ", traits: [:])
        #expect(person.state?.userId == " user-42 ")
    }

    @Test("the length limit counts UTF-16 units, as every limit does")
    func utf16Length() {
        let (identity, person, _) = f.identity()
        let emoji = String(repeating: "\u{1F600}", count: 128)  // 128 characters, 256 UTF-16 units

        #expect(identity.identify(emoji, traits: [:]) == nil)
        #expect(person.state?.userId == nil)
        #expect(identity.identify(String(emoji.dropLast()), traits: [:]) != nil)
        #expect(person.state?.userId?.utf16.count == 254)
    }

    // MARK: reset and super properties

    @Test("reset clears user and all super properties, keeps the device id and sends nothing")
    func reset() throws {
        let (identity, person, device) = f.identity()
        _ = identity.identify("user-42", traits: [:])
        identity.register("theme", value: "dark")

        identity.reset()

        let after = try current(identity)
        #expect(after.userId == nil)
        #expect(after.superProperties == [:])
        #expect(after.deviceId == "device-1")
        #expect(device.state?.deviceId == "device-1")
        #expect(f.ids.current == 1)
        #expect(person.state == .anonymous)
        #expect(f.cleared.current.map(\.userId) == ["user-42"])
    }

    @Test("a nil super property is stored and sent as null")
    func nullSuperProperty() throws {
        let (identity, person, _) = f.identity()

        #expect(identity.register("coupon", value: NSNull()))
        #expect(identity.register("code", value: Optional<String>.none as Any))
        person.persist()

        #expect(try current(identity).superProperties == ["coupon": .null, "code": .null])
        guard case .present(let stored) = f.support.files.read(PersonStore.fileName) else {
            throw Failure("person.json is not present")
        }
        #expect(stored.contains("\"coupon\":null"))
    }

    @Test("super properties are validated at register")
    func validatedAtRegister() throws {
        let (identity, _, _) = f.identity(debug: false)

        #expect(!identity.register("at", value: Data([1])))
        #expect(!identity.register("", value: "x"))
        #expect(identity.register("long", value: String(repeating: "y", count: 2_000)))

        let properties = try current(identity).superProperties
        #expect(Set(properties.keys) == ["long"])
        #expect(properties["long"] == .string(String(repeating: "y", count: 1_024)))
        #expect(f.developerErrors.isEmpty)

        let (debugIdentity, _, _) = f.identity(debug: true)
        #expect(!debugIdentity.register("at", value: Data([1])))
        #expect(f.developerErrors.count == 1)
    }

    @Test("unregister removes a key")
    func unregister() throws {
        let (identity, _, _) = f.identity()
        identity.register("a", value: 1)
        identity.register("b", value: 2)

        identity.unregister("a")
        identity.unregister("missing")

        #expect(try current(identity).superProperties == ["b": .int(2)])
    }

    @Test("every change asks the writer to persist")
    func persistRequests() {
        let (identity, _, _) = f.identity()
        let before = f.persistRequests.current

        _ = identity.identify("u", traits: [:])
        identity.register("a", value: 1)
        identity.unregister("a")
        identity.reset()

        #expect(f.persistRequests.current == before + 4)
    }

    @Test("clearLocalData renews the device id, clears the person and keeps consent, versions and remote config")
    func clearLocalData() throws {
        let (identity, person, device) = f.identity()
        _ = identity.identify("user-42", traits: [:])
        identity.register("a", value: 1)
        device.update {
            with($0) {
                $0.consent = .denied
                $0.lastVersion = "1.0"
                $0.retry = RetryState(step: 3)
                $0.diagnostics = DiagnosticsState(dropped: ["queue_full": 1])
            }
        }
        device.updateRemoteConfig(RemoteConfigCache(etag: "e", values: [:]))

        identity.clearLocalData(newDeviceId: "device-new")

        #expect(person.state == .anonymous)
        #expect(device.state?.deviceId == "device-new")
        #expect(device.state?.consent == .denied)
        #expect(device.state?.lastVersion == "1.0")
        #expect(device.state?.retry == RetryState.none)
        #expect(device.state?.diagnostics == .empty)
        #expect(device.remoteConfig?.etag == "e")
        #expect(try current(identity).deviceId == "device-new")
        #expect(f.cleared.current.isEmpty)
    }

    // MARK: ordering

    @Test("identify then a snapshot on the same thread carries the new id")
    func identifyThenSnapshot() throws {
        let (identity, _, _) = f.identity()

        _ = identity.identify("user-42", traits: [:])

        #expect(try current(identity).userId == "user-42")
    }

    @Test("calls before the stores are loaded apply at load, in call order")
    func beforeLoad() throws {
        let (identity, person, device) = f.identity(load: false)

        let first = identity.snapshot()
        let ticket = try #require(identity.identify("user-42", traits: [:]))
        identity.register("plan", value: "pro")
        let second = identity.snapshot()
        identity.reset()
        let third = identity.snapshot()

        #expect(first.value == nil)
        #expect(ticket.decision == nil)
        f.loadAll(identity, person, device)

        #expect(try #require(first.value).userId == nil)
        #expect(try sent(ticket).identity.userId == "user-42")
        #expect(second.value?.userId == "user-42")
        #expect(second.value?.superProperties == ["plan": .string("pro")])
        #expect(try #require(third.value).userId == nil)
        #expect(third.value?.superProperties == [:])
    }

    @Test("an identify before load uses the stored id to decide")
    func identifyBeforeLoadUsesStoredId() throws {
        let (earlier, earlierPerson, _) = f.identity()
        _ = earlier.identify("user-42", traits: [:])
        earlierPerson.persist()
        let (identity, person, device) = f.identity(load: false)

        let same = try #require(identity.identify("user-42", traits: [:]))
        f.loadAll(identity, person, device)

        #expect(same.decision == .noEvent)
    }

    @Test("invalid input is rejected on the calling thread, before load")
    func invalidBeforeLoad() {
        let (identity, _, _) = f.identity(debug: true, load: false)

        #expect(identity.identify("", traits: [:]) == nil)
        #expect(f.developerErrors.count == 1)
    }

    @Test("snapshots from many threads never see a half-made change")
    func concurrentSnapshots() throws {
        let (identity, _, _) = f.identity()
        let failures = Locked(0)

        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for i in 0..<500 {
                identity.register("k\(thread)", value: i)
                guard let properties = identity.snapshot().value?.superProperties else {
                    failures.withLock { $0 += 1 }
                    continue
                }
                for _ in properties {}
            }
        }

        #expect(failures.current == 0)
        #expect(try current(identity).superProperties.count == 8)
    }

    // MARK: device id

    @Test("reading it before the writer loads reads the file once and writes nothing")
    func deviceIdBeforeLoad() {
        let (identity, person, device) = f.identity(load: false)

        let early = identity.deviceId

        #expect(early == "device-1")
        #expect(f.support.files.read(DeviceStore.fileName) == .missing)
        f.loadAll(identity, person, device)
        #expect(identity.deviceId == "device-1")
        #expect(f.ids.current == 1)
        guard case .present = f.support.files.read(DeviceStore.fileName) else {
            Issue.record("device.json was not written by load")
            return
        }
    }

    @Test("an unreadable device file gives a temporary id and stays untouched")
    func unreadableDeviceFile() throws {
        try f.support.writeRaw(DeviceStore.fileName, #"{"v":9,"device_id":"kept"}"#)
        let before = try f.support.rawBytes(DeviceStore.fileName)

        let (identity, _, device) = f.identity()
        _ = identity.identify("user-42", traits: [:])
        device.persist()

        #expect(identity.deviceId == "device-1")
        #expect(try f.support.rawBytes(DeviceStore.fileName) == before)
        #expect(f.warned(.storeUnreadable))
    }

    @Test("before the first unlock deviceId is empty, nothing is minted, and calls apply after the unlock")
    func lockedDevice() throws {
        try f.support.writeRaw(DeviceStore.fileName, #"{"v":1,"device_id":"real"}"#)
        f.support.test.fileSystem.locked = true
        let (identity, person, device) = f.identity(load: false)

        #expect(identity.deviceId == "")
        #expect(f.ids.current == 0)
        let ticket = try #require(identity.identify("user-42", traits: [:]))
        #expect(!device.load())

        f.support.test.fileSystem.locked = false
        f.loadAll(identity, person, device)

        #expect(identity.deviceId == "real")
        #expect(try sent(ticket).identity.deviceId == "real")
        #expect(person.state?.userId == "user-42")
    }
}
