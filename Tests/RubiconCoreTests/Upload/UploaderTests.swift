import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The port of the Android `UploaderTest` on the virtual scheduler; the Android test names are kept.
/// Waits are measured on the scheduler's own elapsed clock, as the real one runs with real time.
@Suite("Uploader")
struct UploaderTests {
    /// Counts requests in flight to prove that no two overlap.
    final class CountingTransport: HttpTransport, @unchecked Sendable {
        let inner: FakeTransport
        let inFlight = Locked(0)
        let maxInFlight = Locked(0)

        init(_ inner: FakeTransport) { self.inner = inner }

        func execute(_ request: HttpRequest) -> HttpResult {
            let now: Int = inFlight.withLock {
                $0 += 1
                return $0
            }
            maxInFlight.withLock { $0 = max($0, now) }
            defer { inFlight.withLock { $0 -= 1 } }
            return inner.execute(request)
        }

        func cancelCurrent() { inner.cancelCurrent() }
        func shutdown() { inner.shutdown() }
    }

    final class Harness: @unchecked Sendable {
        let test = TestPlatform()
        let updates = Locked<[EventUpdate]>([])
        lazy var log = test.log()
        let eventStore = InMemoryEventStore(maxEventsPerSegment: 2)
        let transport = FakeTransport()
        let remoteTransport = FakeTransport(whenEmpty: .httpError(code: 404, body: nil, retryAfterMs: nil))
        let flags = RuntimeFlags()
        let ready = Locked(true)
        let allowed = Locked(true)
        let persists = Locked(0)
        lazy var counting = CountingTransport(transport)
        lazy var deviceStore: DeviceStore = {
            let store = DeviceStore(
                keyValueStore: FileKeyValueStore(root: test.storageRoot, fileSystem: test.fileSystem), log: log,
                clock: test.clock, newDeviceId: { "device-1" })
            store.load()
            return store
        }()
        lazy var policy = RetryPolicy(
            deviceStore: deviceStore, clock: test.clock, elapsedClock: test.scheduler.elapsedClock,
            random: SeededRandom(seed: 1), log: log)
        lazy var code: ConfigSnapshot = {
            guard let snapshot = ConfigValidator.validate(AnalyticsConfiguration(apiKey: "rk_test")).snapshot else {
                fatalError("invalid configuration")
            }
            return snapshot
        }()
        lazy var remote = RemoteConfigClient(
            code: code, deviceStore: deviceStore, transport: remoteTransport, flags: flags, log: log)
        lazy var uploader = makeUploader(eventStore: eventStore, transport: counting, observe: true)

        func makeUploader(eventStore: any EventStore, transport: any HttpTransport, observe: Bool) -> Uploader {
            let updates = self.updates
            let ready = self.ready
            let persists = self.persists
            let allowed = self.allowed
            let recording: EventObserver = { update in updates.withLock { $0.append(update) } }
            let observer: EventObserver? = observe ? recording : nil
            return Uploader(
                eventStore: eventStore, transport: transport, batchURL: code.batchURL, policy: policy, remote: remote,
                networkMonitor: test.networkMonitor, scheduler: test.scheduler, flags: flags, deviceStore: deviceStore,
                clock: test.clock, log: log, observer: observer, writerReady: { ready.current },
                requestPersist: { persists.withLock { $0 += 1 } }, uploadsAllowed: { allowed.current })
        }

        private var seq = 0

        /// Appends `count` events and closes them into segments of two.
        @discardableResult
        func events(_ count: Int) -> [String] {
            var ids: [String] = []
            for _ in 0..<count {
                seq += 1
                ids.append("m-\(seq)")
            }
            for id in ids {
                _ = eventStore.append(
                    #"{"type":"track","event":"E","message_id":"\#(id)","timestamp":\#(test.clock.now().epochMillis)}"#)
            }
            eventStore.closeOpenSegment()
            return ids
        }

        func start() { uploader.start() }
        func signal() { uploader.signal() }
        func runCurrent() { test.scheduler.runUntilIdle() }
        func advance(_ millis: Int64) { test.scheduler.advance(byMillis: millis) }

        func sentBatches() -> [[String]] { transport.requests.map(batchIds) }

        func batchIds(_ request: HttpRequest) -> [String] {
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            var ids: [String] = []
            var rest = body[...]
            while let range = rest.range(of: "\"message_id\":\"") {
                rest = rest[range.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { break }
                ids.append(String(rest[..<end]))
                rest = rest[end...]
            }
            return ids
        }

        func sentAt(_ request: HttpRequest) -> Int64? {
            guard
                case .object(let object)? = try? JSONValue.parse(
                    String(decoding: request.body ?? Data(), as: UTF8.self)),
                case .number(let value)? = object["sent_at"]
            else { return nil }
            return Int64(value)
        }

        var sent: [[String]] {
            updates.current.compactMap {
                if case .sent(let ids) = $0 { return ids }
                return nil
            }
        }

        var dropped: [(ids: [String], reason: DropReason)] {
            updates.current.compactMap {
                if case .dropped(let ids, let reason) = $0 { return (ids, reason) }
                return nil
            }
        }
    }

    let h = Harness()

    func failure(_ kind: FailureKind) -> HttpResult {
        .networkFailure(kind: kind, cause: NSError(domain: "test", code: 1))
    }

    // MARK: sending

    @Test("batches go oldest first, are deleted after 2xx, and Sent lists their ids")
    func oldestFirst() {
        let ids = h.events(5)
        h.start()
        h.signal()
        h.runCurrent()

        #expect(h.sentBatches() == [Array(ids[0..<2]), Array(ids[2..<4]), Array(ids[4..<5])])
        #expect(h.eventStore.closedSegments().isEmpty)
        #expect(h.sent == [Array(ids[0..<2]), Array(ids[2..<4]), Array(ids[4..<5])])
    }

    @Test("the body is the envelope with sent_at, posted to the batch endpoint")
    func envelope() throws {
        h.events(1)
        h.start()
        h.signal()
        h.runCurrent()

        let request = try #require(h.transport.requests.first)
        #expect(h.transport.requests.count == 1)
        #expect(request.method == .post)
        #expect(request.url == h.code.batchURL)
        #expect(request.url.path.hasSuffix("/v1/batch"))
        #expect(h.sentAt(request) == h.test.clock.now().epochMillis)
    }

    @Test("a batch is kept on failure, retried after the wait with a new sent_at, and deleted after 2xx")
    func keptAndRetried() {
        h.events(1)
        h.transport.enqueue(.httpError(code: 503, body: nil, retryAfterMs: nil))
        h.start()
        h.signal()
        h.runCurrent()
        #expect(h.eventStore.closedSegments().count == 1)

        h.test.clock.advance(byMillis: 5_000)
        h.advance(5_000)
        h.runCurrent()

        #expect(h.transport.requests.count == 2)
        let sentAts = h.transport.requests.map(h.sentAt)
        #expect(sentAts[0] != sentAts[1])
        #expect(h.eventStore.closedSegments().isEmpty)
    }

    @Test("it stops at the first failure")
    func stopsAtFirstFailure() {
        h.events(6)
        h.transport.enqueue(.success(code: 200), .httpError(code: 500, body: nil, retryAfterMs: nil))
        h.start()
        h.signal()
        h.runCurrent()

        #expect(h.transport.requests.count == 2)
        #expect(h.eventStore.closedSegments().count == 2)
    }

    @Test("a rejected batch is deleted, counted and reported")
    func rejected() {
        let ids = h.events(2)
        h.transport.enqueue(.httpError(code: 400, body: nil, retryAfterMs: nil))
        h.start()
        h.signal()
        h.runCurrent()

        #expect(h.eventStore.closedSegments().isEmpty)
        #expect(h.deviceStore.state?.diagnostics.dropped == ["rejected": 2])
        #expect(h.dropped.count == 1)
        #expect(h.dropped.first?.ids == ids)
        #expect(h.dropped.first?.reason == .rejected)
    }

    @Test("a segment of only corrupt lines is deleted without a request")
    func corruptSegment() {
        // The corruption rules live in FileEventStore, not in the in-memory fake.
        let files = FileEventStore(root: h.test.storageRoot, fileSystem: h.test.fileSystem)
        _ = files.open(apiKey: "rk_test", clock: h.test.clock, log: h.log, drops: { _, _ in })
        _ = files.append("not json")
        files.closeOpenSegment()
        _ = files.append(
            #"{"type":"track","event":"E","message_id":"ok","timestamp":\#(h.test.clock.now().epochMillis)}"#)
        files.closeOpenSegment()
        let uploader = h.makeUploader(eventStore: files, transport: h.transport, observe: false)
        uploader.start()
        uploader.signal()
        h.runCurrent()

        #expect(h.sentBatches() == [["ok"]])
        #expect(files.closedSegments().isEmpty)
    }

    @Test("retry state changes are handed to the writer")
    func retryStatePersisted() {
        h.events(1)
        h.transport.enqueue(.httpError(code: 503, body: nil, retryAfterMs: nil))
        h.start()
        h.signal()
        h.runCurrent()

        #expect(h.persists.current >= 1)
        #expect(h.deviceStore.state?.retry.batches == ["0000000000": 1])
    }

    // MARK: gates

    @Test("offline blocks and the network coming back resumes")
    func offline() {
        h.test.networkMonitor.setConnected(false)
        h.events(1)
        h.start()
        h.signal()
        h.runCurrent()
        #expect(h.transport.requests.isEmpty)

        h.test.networkMonitor.setConnected(true)
        h.runCurrent()

        #expect(h.transport.requests.count == 1)
    }

    @Test("the kill switch blocks uploads")
    func killSwitch() {
        h.events(1)
        h.flags.stopCollecting()
        h.start()
        h.signal()
        h.runCurrent()

        #expect(h.transport.requests.isEmpty)
    }

    @Test("a closed consent gate blocks until it opens and the next wake")
    func consentGate() {
        h.events(1)
        h.allowed.withLock { $0 = false }
        h.start()
        h.signal()
        h.runCurrent()
        #expect(h.transport.requests.isEmpty)

        h.allowed.withLock { $0 = true }
        h.signal()
        h.runCurrent()

        #expect(h.transport.requests.count == 1)
    }

    @Test("a wait blocks new attempts until it ends")
    func waitBlocks() {
        h.events(1)
        h.transport.enqueue(.httpError(code: 429, body: nil, retryAfterMs: 60_000))
        h.start()
        h.signal()
        h.runCurrent()
        for _ in 0..<5 { h.signal() }
        h.advance(59_000)
        h.runCurrent()
        #expect(h.transport.requests.count == 1)

        h.advance(7_000)
        h.runCurrent()

        #expect(h.transport.requests.count == 2)
    }

    @Test("the network coming back ends a wait caused by the network")
    func networkEndsWait() {
        h.events(1)
        h.transport.enqueue(failure(.dns), failure(.dns), failure(.dns))
        h.start()
        h.signal()
        h.runCurrent()
        h.advance(1_000)
        h.runCurrent()
        let before = h.transport.requests.count

        h.test.networkMonitor.setConnected(false)
        h.test.networkMonitor.setConnected(true)
        h.runCurrent()

        #expect(h.transport.requests.count == before + 1)
    }

    @Test("leftovers wait for a flush trigger, nothing is sent at startup")
    func noStartupUpload() {
        h.events(3)
        h.start()
        h.runCurrent()
        #expect(h.transport.requests.isEmpty)

        h.signal()
        h.runCurrent()

        #expect(h.transport.requests.count == 2)
    }

    @Test("no two requests overlap under a burst of signals")
    func noOverlap() {
        h.events(8)
        h.start()
        for _ in 0..<50 { h.signal() }
        h.runCurrent()

        #expect(h.transport.requests.count == 4)
        #expect(h.counting.maxInFlight.current == 1)
    }

    @Test("nothing starts before the writer has loaded the stores")
    func waitsForWriter() {
        h.ready.withLock { $0 = false }
        h.events(1)
        h.start()
        h.signal()
        h.runCurrent()
        #expect(h.transport.requests.isEmpty)
        #expect(!h.uploader.isStarted)

        h.ready.withLock { $0 = true }
        h.start()
        h.runCurrent()

        #expect(h.transport.requests.count == 1)
    }

    // MARK: remote configuration

    @Test("is fetched once per launch")
    func remoteOnce() {
        h.start()
        h.signal()
        h.runCurrent()
        for _ in 0..<3 {
            h.signal()
            h.runCurrent()
        }

        #expect(h.remoteTransport.requests.count == 1)
    }

    @Test("is fetched when the network first comes back, also with uploads gated")
    func remoteWhenNetworkReturns() {
        h.test.networkMonitor.setConnected(false)
        h.allowed.withLock { $0 = false }
        h.start()
        h.signal()
        h.runCurrent()
        #expect(h.remoteTransport.requests.isEmpty)

        h.test.networkMonitor.setConnected(true)
        h.runCurrent()

        #expect(h.remoteTransport.requests.count == 1)
    }

    // MARK: the background flush (iOS Queue 2)

    @Test("the background flush reports done when nothing is pending, and at the first failure")
    func backgroundFlushDone() {
        let done = Locked(0)
        h.events(4)
        h.start()
        h.runCurrent()
        h.uploader.beginBackgroundFlush { done.withLock { $0 += 1 } }
        h.signal()
        h.runCurrent()
        #expect(done.current == 1)
        #expect(h.transport.requests.count == 2)

        h.events(4)
        h.transport.enqueue(.httpError(code: 500, body: nil, retryAfterMs: nil))
        h.uploader.beginBackgroundFlush { done.withLock { $0 += 1 } }
        h.signal()
        h.runCurrent()
        #expect(done.current == 2)
        #expect(h.transport.requests.count == 3)
        #expect(h.eventStore.closedSegments().count == 2)
    }

    @Test("the background flush is done at once when the uploader cannot run yet")
    func backgroundFlushNotReady() {
        let done = Locked(0)
        h.ready.withLock { $0 = false }
        h.uploader.beginBackgroundFlush { done.withLock { $0 += 1 } }
        h.runCurrent()

        #expect(done.current == 1)
    }

    @Test("expiration cancels the request in flight, and a cancelled upload is a waiting state")
    func expiration() {
        let done = Locked(0)
        h.events(2)
        h.transport.enqueue(failure(.cancelled))
        h.start()
        h.uploader.beginBackgroundFlush { done.withLock { $0 += 1 } }
        h.uploader.expireBackgroundFlush()
        h.signal()
        h.runCurrent()

        #expect(h.transport.cancels == 1)
        #expect(done.current == 0)
        #expect(h.eventStore.closedSegments().count == 1)
        let retry = h.deviceStore.state?.retry
        #expect(retry?.step == 0)
        #expect(retry?.pausedUntil == nil)
        #expect(retry?.lastFailure == "cancelled")
        #expect(retry?.batches == [:])

        h.signal()
        h.runCurrent()
        #expect(h.transport.requests.count == 2)
        #expect(h.eventStore.closedSegments().isEmpty)
    }
}
