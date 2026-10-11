import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("DeviceStore")
struct DeviceStoreTests {
    let support = StoreTestSupport()
    let clock = TestClock(start: Date(epochMillis: 1_759_147_000_000))

    private func store() -> DeviceStore {
        DeviceStore(keyValueStore: support.files, log: support.log, clock: clock, newDeviceId: support.newDeviceId)
    }

    private func loaded() -> DeviceStore {
        let store = store()
        store.load()
        return store
    }

    let full = DeviceState(
        deviceId: "0191d0c2-1a2b-7c3d-9e4f-5a6b7c8d9e0f", consent: .denied, lastVersion: "1.4.0", lastBuild: "140",
        retry: RetryState(
            pausedUntil: Date(epochMillis: 1_759_150_860_000), pauseKind: .throttle, step: 3, lastFailure: "cancelled",
            batches: ["0000000041": 6]),
        diagnostics: DiagnosticsState(
            periodStart: Date(epochMillis: 1_759_100_000_000), lastSentAt: Date(epochMillis: 1_759_000_000_000),
            dropped: ["queue_full": 12], issues: ["HOST_BLOCKED": 2]))

    @Test("device.json and remote-config.json have exactly the decided keys")
    func keys() throws {
        let store = loaded()
        store.update { _ in full }
        store.updateRemoteConfig(RemoteConfigCache(etag: "\"abc\"", values: ["flush_at": .int(10)]))
        store.persist()

        let device = try support.stored(DeviceStore.fileName)
        #expect(
            Set(device.keys) == ["v", "device_id", "consent", "last_version", "last_build", "retry", "diagnostics"])
        guard case .object(let retry)? = device["retry"], case .object(let diagnostics)? = device["diagnostics"] else {
            Issue.record("nested objects missing")
            return
        }
        #expect(Set(retry.keys) == ["paused_until", "pause_kind", "step", "last_failure", "batches"])
        #expect(retry["last_failure"] == .string("cancelled"))
        #expect(retry["paused_until"] == .number(1_759_150_860_000))
        #expect(Set(diagnostics.keys) == ["period_start", "last_sent_at", "dropped", "issues"])
        #expect(Set(try support.stored(DeviceStore.remoteConfigFileName).keys) == ["v", "etag", "values"])
    }

    @Test("the state and the cache read back as written; consent is null, granted or denied")
    func roundTrip() throws {
        let cache = RemoteConfigCache(etag: "\"abc\"", values: ["enabled": .bool(true), "flush_at": .int(10)])
        let first = loaded()
        #expect(first.state?.consent == nil)
        first.update { _ in full }
        first.updateRemoteConfig(cache)
        first.persist()

        let reloaded = loaded()
        #expect(reloaded.state == full)
        #expect(reloaded.remoteConfig == cache)
        #expect(try support.stored(DeviceStore.fileName)["consent"] == .string("denied"))
    }

    @Test("a deleted remote config cache removes the file")
    func deleteCache() {
        let store = loaded()
        store.updateRemoteConfig(RemoteConfigCache(etag: nil, values: [:]))
        store.persist()
        store.updateRemoteConfig(nil)
        store.persist()
        #expect(support.files.read(DeviceStore.remoteConfigFileName) == .missing)
    }

    @Test("a missing device file gets a new id, written at once; a missing remote config writes nothing")
    func missing() {
        let store = loaded()
        #expect(store.state?.deviceId == "device-1")
        #expect(loaded().state?.deviceId == "device-1")
        #expect(store.isDeviceFileWritable)
        #expect(store.remoteConfig == nil)
        #expect(support.files.read(DeviceStore.remoteConfigFileName) == .missing)
    }

    @Test("an unreadable device file uses a temporary id and is never written; the next process reads it again")
    func unreadable() throws {
        try support.writeRaw(DeviceStore.fileName, "not json")
        let writes = support.writeCount

        let store = loaded()
        store.update { with($0) { $0.consent = .granted } }
        store.persist()

        #expect(store.state?.deviceId == "device-1")
        #expect(!store.isDeviceFileWritable)
        #expect(support.writeCount == writes)
        #expect(support.warned(.storeUnreadable))

        try support.writeRaw(DeviceStore.fileName, #"{"v":1,"device_id":"kept"}"#)
        #expect(loaded().state?.deviceId == "kept")
    }

    @Test(
        "files that cannot be used are left byte-identical",
        arguments: [
            (DeviceStore.fileName, "not json"),
            (DeviceStore.fileName, #"{"v":3,"device_id":"0191"}"#),
            (DeviceStore.fileName, #"{"v":1,"consent":"granted"}"#),
            (DeviceStore.fileName, #"{"v":1,"device_id":"x","consent":"maybe"}"#),
            (DeviceStore.fileName, #"{"v":1,"device_id":"x","retry":{"pause_kind":"forever"}}"#),
            (DeviceStore.fileName, #"{"v":1,"device_id":"x","diagnostics":{"dropped":{"corrupt":"3"}}}"#),
            (DeviceStore.fileName, #"{"v":1,"device_id":"  "}"#),
            (DeviceStore.remoteConfigFileName, #"{"v":2,"values":{}}"#),
        ])
    func untouched(name: String, content: String) throws {
        try support.writeRaw(name, content)
        let before = try support.rawBytes(name)

        let store = loaded()
        store.update { with($0) { $0.lastBuild = "141" } }
        store.updateRemoteConfig(RemoteConfigCache(etag: "\"new\"", values: [:]))
        store.persist()

        #expect(try support.rawBytes(name) == before)
        #expect(support.warned(.storeUnreadable))
    }

    @Test("drops and issues add up, start the period, and are persisted with the next write")
    func counters() {
        let store = loaded()
        store.countDropped(.queueFull, count: 3)
        store.countDropped(.queueFull)
        store.issueCounter(.hostBlocked)
        clock.advance(byMillis: 5_000)
        store.issueCounter(.hostBlocked)

        let diagnostics = store.state?.diagnostics
        #expect(diagnostics?.dropped == ["queue_full": 4])
        #expect(diagnostics?.issues == ["HOST_BLOCKED": 2])
        #expect(diagnostics?.periodStart == Date(epochMillis: 1_759_147_000_000))

        store.persist()
        #expect(loaded().state?.diagnostics.dropped == ["queue_full": 4])
    }

    @Test("counts made before load are kept, including the unreadable warning itself")
    func earlyCounts() throws {
        try support.writeRaw(DeviceStore.fileName, "not json")
        let holder = Locked<DeviceStore?>(nil)
        // The log of the instance counts through the store, as in production.
        let log = Log(level: .warn, logger: nil, platformLogger: support.test.logger.asLogger) { code in
            holder.current?.issueCounter(code)
        }
        let store = DeviceStore(keyValueStore: support.files, log: log, clock: clock, newDeviceId: support.newDeviceId)
        holder.withLock { $0 = store }

        store.countDropped(.backpressure, count: 2)
        store.load()

        #expect(store.state?.diagnostics.dropped == ["backpressure": 2])
        #expect(store.state?.diagnostics.issues == ["STORE_UNREADABLE": 1])
    }

    @Test("a count never wraps around, and reporting takes counts off")
    func saturationAndReporting() {
        let store = loaded()
        store.update { with($0) { $0.diagnostics.dropped = ["expired": Int(Int32.max) - 1] } }
        store.countDropped(.expired, count: 5)
        #expect(store.state?.diagnostics.dropped["expired"] == Int(Int32.max))

        store.countDropped(.corrupt, count: 2)
        let reported = store.state?.diagnostics ?? .empty
        store.countDropped(.corrupt)
        let at = Date(epochMillis: 1_759_147_999_000)
        store.diagnosticsReported(reported, at: at)

        #expect(store.state?.diagnostics.dropped == ["corrupt": 1])
        #expect(store.state?.diagnostics.lastSentAt == at)
        #expect(store.state?.diagnostics.periodStart == at)
        store.diagnosticsReported(store.state?.diagnostics ?? .empty, at: at)
        #expect(store.state?.diagnostics.isEmpty == true)
        #expect(store.state?.diagnostics.periodStart == nil)
    }

    @Test("many updates in a row produce one write")
    func coalesced() {
        let store = loaded()
        let writes = support.writeCount
        for _ in 0..<100 { store.countDropped(.queueFull) }
        store.update { with($0) { $0.lastVersion = "1.5.0" } }
        store.persist()
        #expect(support.writeCount == writes + 1)
    }

    @Test("a locked device loads nothing, mints no id and writes nothing; load succeeds after unlock")
    func locked() throws {
        try support.writeRaw(DeviceStore.fileName, #"{"v":1,"device_id":"real"}"#)
        support.test.fileSystem.locked = true
        let store = store()

        #expect(!store.load())
        #expect(store.state == nil)
        #expect(!store.isLoaded)
        #expect(store.isLocked)
        store.readEarly()
        #expect(store.state == nil)
        #expect(!support.warned(.storeUnreadable))
        #expect(support.counted.current.isEmpty)

        support.test.fileSystem.locked = false
        #expect(store.load())
        #expect(store.state?.deviceId == "real")
        #expect(!store.isLocked)
    }

    @Test("a write while locked is kept in memory and written after unlock without an error")
    func lockedWrite() throws {
        let store = loaded()
        support.test.fileSystem.locked = true
        store.update { with($0) { $0.lastBuild = "9" } }

        #expect(store.persist())
        #expect(store.isLocked)
        #expect(!support.errored(.storageWriteFailed))

        support.test.fileSystem.locked = false
        #expect(store.persist())
        #expect(loaded().state?.lastBuild == "9")
    }

    @Test("readEarly reads once on the calling thread and load then only writes")
    func readEarly() {
        let store = store()
        store.readEarly()
        #expect(store.state?.deviceId == "device-1")
        #expect(support.files.read(DeviceStore.fileName) == .missing)
        store.load()
        #expect(store.state?.deviceId == "device-1")
        #expect(support.files.read(DeviceStore.fileName) != .missing)
    }
}
