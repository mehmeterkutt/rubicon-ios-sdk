import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The Android `RetryPolicyTest`, ported, plus the `cancelled` waiting state of iOS Retry 2.
final class RetryHarness: @unchecked Sendable {
    static let now: Int64 = 1_759_147_200_000
    let support = StoreTestSupport()
    let clock = TestClock(start: Date(epochMillis: RetryHarness.now))
    let elapsed = TestElapsedClock()
    lazy var store = deviceStore()
    lazy var policy = policy(store)

    func deviceStore() -> DeviceStore {
        let store = DeviceStore(keyValueStore: support.files, log: support.log, clock: clock) { "device-1" }
        store.load()
        return store
    }

    func policy(_ store: DeviceStore, random: any RandomSource = SeededRandom(seed: 7)) -> RetryPolicy {
        let policy = RetryPolicy(
            deviceStore: store, clock: clock, elapsedClock: elapsed, random: random, log: support.log)
        policy.restore()
        return policy
    }

    func http(_ code: Int, retryAfterMs: Int64? = nil) -> HttpResult {
        .httpError(code: code, body: nil, retryAfterMs: retryAfterMs)
    }
    func network(_ kind: FailureKind) -> HttpResult {
        .networkFailure(kind: kind, cause: URLError(.networkConnectionLost))
    }
    var retry: RetryState { store.state?.retry ?? .none }
    func errors(_ code: Code) -> Int {
        support.test.logger.lines.filter { $0.level == .error && $0.message.hasPrefix("\(code.rawValue):") }.count
    }
    func warned(_ code: Code) -> Bool {
        support.test.logger.lines.contains { $0.level == .warn && $0.message.hasPrefix("\(code.rawValue):") }
    }
}

@Suite("RetryGroup classification")
struct RetryGroupTests {
    @Test(
        "status codes",
        arguments: [
            (200, RetryGroup.success), (201, .success), (204, .success), (100, .transient), (199, .transient),
            (408, .transient),
            (500, .transient), (502, .transient), (503, .transient), (504, .transient), (599, .transient),
            (600, .transient),
            (-1, .transient), (429, .throttle), (400, .badBatch), (402, .badBatch), (405, .badBatch), (409, .badBatch),
            (422, .badBatch), (451, .badBatch), (401, .config), (403, .config), (404, .config), (410, .config),
            (413, .config),
            (501, .config), (505, .config), (301, .config), (302, .config), (304, .config), (307, .config),
            (308, .config),
        ])
    func statusCodes(code: Int, group: RetryGroup) {
        let result: HttpResult =
            (200..<300).contains(code) ? .success(code: code) : .httpError(code: code, body: nil, retryAfterMs: nil)
        #expect(RetryGroup.of(result) == group)
    }

    @Test("503 with Retry-After slows down, 429 does either way")
    func retryAfter() {
        #expect(RetryGroup.of(.httpError(code: 503, body: nil, retryAfterMs: 30_000)) == .throttle)
        #expect(RetryGroup.of(.httpError(code: 429, body: nil, retryAfterMs: 30_000)) == .throttle)
    }

    @Test(
        "failure kinds",
        arguments: [
            (FailureKind.timeout, RetryGroup.transient), (.dns, .transient), (.connect, .transient), (.io, .transient),
            (.tls, .config),
            (.blocked, .config), (.unexpected, .config), (.cancelled, .interrupted),
        ])
    func failureKinds(kind: FailureKind, group: RetryGroup) {
        #expect(RetryGroup.of(.networkFailure(kind: kind, cause: URLError(.cancelled))) == group)
    }
}

@Suite("RetryPolicy backoff and Retry-After")
struct RetryBackoffTests {
    let h = RetryHarness()

    @Test("transient failures walk the table with jitter between 0.5 and 1.5")
    func table() {
        let waits = (1...8).map { _ -> Int64 in
            #expect(h.policy.onResult("0000000001", h.http(500)) == .keep)
            return h.policy.waitMillis()
        }
        let table: [Int64] = [2_000, 10_000, 30_000, 120_000, 300_000, 600_000, 600_000, 600_000]
        for (wait, base) in zip(waits, table) {
            #expect(wait >= base / 2 && wait <= base * 3 / 2, "\(wait) for \(base)")
        }
        #expect(h.retry.step == 8)
        #expect(h.retry.pauseKind == .transient)
        #expect(h.retry.lastFailure == "http_500")
    }

    @Test("jitter spreads devices that failed together")
    func jitter() {
        let waits = (1...20).map { seed -> Int64 in
            let policy = h.policy(h.deviceStore(), random: SeededRandom(seed: UInt64(seed)))
            _ = policy.onResult("s", h.network(.timeout))
            return policy.waitMillis()
        }
        #expect(Set(waits).count > 15)
        #expect(waits.allSatisfy { $0 >= 1_000 && $0 <= 3_000 })
    }

    @Test("a success resets the table and clears the wait")
    func reset() {
        for _ in 0..<4 { _ = h.policy.onResult("a", h.http(502)) }
        #expect(h.policy.onResult("a", .success(code: 200)) == .deleteSent)
        #expect(h.policy.waitMillis() == 0)
        #expect(h.retry == .none)
        _ = h.policy.onResult("b", h.http(502))
        #expect(h.policy.waitMillis() <= 3_000)
    }

    @Test("the wait passes on the elapsed clock, not the wall clock")
    func elapsedClock() {
        _ = h.policy.onResult("a", h.http(500))
        let wait = h.policy.waitMillis()
        h.clock.advance(byMillis: -86_400_000)
        #expect(h.policy.waitMillis() == wait)
        h.elapsed.advance(byMillis: wait)
        #expect(h.policy.waitMillis() == 0)
    }

    @Test("Retry-After is never shortened, gets forward jitter of at most 10 percent, is capped at one hour")
    func retryAfter() {
        for _ in 0..<20 {
            _ = h.policy.onResult("a", h.http(429, retryAfterMs: 120_000))
            let wait = h.policy.waitMillis()
            #expect(wait >= 120_000 && wait <= 132_000, "\(wait)")
        }
        #expect(h.retry.pauseKind == .throttle)
        _ = h.policy.onResult("a", h.http(503, retryAfterMs: 7_200_000))
        #expect(h.policy.waitMillis() == 3_600_000)
        _ = h.policy.onResult("a", h.http(429, retryAfterMs: 3_590_000))
        let near = h.policy.waitMillis()
        #expect(near >= 3_590_000 && near <= 3_600_000)
    }

    @Test(
        "zero or less counts as one second; without the header the table is used; the table is not advanced otherwise")
    func retryAfterEdges() {
        _ = h.policy.onResult("a", h.http(429, retryAfterMs: 0))
        #expect(h.policy.waitMillis() >= 1_000 && h.policy.waitMillis() <= 1_100)
        _ = h.policy.onResult("a", h.http(429, retryAfterMs: -60_000))
        #expect(h.policy.waitMillis() >= 1_000 && h.policy.waitMillis() <= 1_100)
        #expect(h.retry.step == 0)
        #expect(h.retry.batches.isEmpty)
        _ = h.policy.onResult("a", h.http(429))
        #expect(h.policy.waitMillis() >= 1_000 && h.policy.waitMillis() <= 3_000)
        #expect(h.retry.step == 1)
    }
}

@Suite("RetryPolicy configuration problems, network and cancellation")
struct RetryDecisionTests {
    let h = RetryHarness()

    @Test("configuration problems pause one hour plus or minus 20 percent and log one error per code")
    func configProblems() {
        for _ in 0..<3 {
            #expect(h.policy.onResult("a", h.http(401)) == .keep)
            let wait = h.policy.waitMillis()
            #expect(wait >= 2_880_000 && wait <= 4_320_000)
        }
        _ = h.policy.onResult("a", h.http(404))
        _ = h.policy.onResult("a", h.http(413))
        _ = h.policy.onResult("a", h.http(505))
        _ = h.policy.onResult("a", h.network(.tls))
        #expect(h.errors(.uploadUnauthorized) == 1)
        #expect(h.errors(.uploadEndpointMissing) == 1)
        #expect(h.errors(.uploadTooLarge) == 1)
        #expect(h.errors(.uploadNotSupported) == 1)
        #expect(h.retry.pauseKind == .config)
        #expect(h.retry.step == 0)
        #expect(h.retry.batches.isEmpty)
    }

    @Test("a bad batch is deleted at once, with a warning")
    func badBatch() {
        #expect(h.policy.onResult("a", h.http(400)) == .deleteRejected)
        #expect(h.policy.onResult("b", h.http(422)) == .deleteRejected)
        #expect(h.policy.waitMillis() == 0)
        #expect(h.warned(.batchRejected))
    }

    @Test(
        "the network's return ends a wait caused by the network, keeps the table position, never ends a server's wait")
    func networkRegained() {
        for _ in 0..<3 { _ = h.policy.onResult("a", h.network(.connect)) }
        h.policy.onNetworkRegained()
        #expect(h.policy.waitMillis() == 0)
        #expect(h.retry.pausedUntil == nil)
        #expect(h.retry.step == 3)
        _ = h.policy.onResult("a", h.network(.dns))
        #expect(h.policy.waitMillis() >= 60_000)

        for result in [
            h.http(500), h.http(429, retryAfterMs: 60_000), h.http(429), h.http(401), h.network(.tls),
            h.network(.blocked),
        ] {
            _ = h.policy.onResult("a", result)
            let wait = h.policy.waitMillis()
            h.policy.onNetworkRegained()
            #expect(h.policy.waitMillis() == wait, "\(result)")
        }
    }

    @Test("a cancelled attempt is a waiting state: no step, no wait, not counted, last_failure cancelled")
    func cancelled() {
        _ = h.policy.onResult("a", h.http(500))
        let stepBefore = h.retry.step
        for _ in 0..<5 {
            #expect(h.policy.onResult("a", h.network(.cancelled)) == .keep)
        }
        #expect(h.policy.waitMillis() == 0)
        #expect(h.retry.step == stepBefore)
        #expect(h.retry.batches["a"] == 1)
        #expect(h.retry.lastFailure == "cancelled")
        #expect(h.retry.pausedUntil == nil)
        #expect(!h.support.test.logger.lines.contains { $0.level == .warn || $0.level == .error })
        #expect(h.policy.onResult("a", .success(code: 200)) == .deleteSent)
    }
}

@Suite("RetryPolicy poison batch")
struct RetryPoisonTests {
    let h = RetryHarness()

    // A scripted uploader: the oldest segment in the policy's order, one attempt at a time.
    private func run(_ segments: inout [String], attempts: Int, answer: (String) -> HttpResult) -> [(
        String, RetryPolicy.Decision
    )] {
        var log: [(String, RetryPolicy.Decision)] = []
        for _ in 0..<attempts {
            if segments.isEmpty { return log }
            h.elapsed.advance(byMillis: h.policy.waitMillis())
            let segment = h.policy.order(segments)[0]
            let decision = h.policy.onResult(segment, answer(segment))
            log.append((segment, decision))
            if decision != .keep { segments.removeAll { $0 == segment } }
        }
        return log
    }

    @Test("a batch that keeps failing while others succeed is deleted after 10 attempts")
    func exhausted() {
        var segments = ["41", "42", "43"]
        let log = run(&segments, attempts: 30) { $0 == "41" ? h.http(500) : .success(code: 200) }
        let expected: [(String, RetryPolicy.Decision)] =
            Array(repeating: ("41", .keep), count: 5) + [("42", .deleteSent), ("43", .deleteSent)]
            + Array(repeating: ("41", .keep), count: 4) + [("41", .deleteExhausted)]
        #expect(log.map(\.0) == expected.map(\.0))
        #expect(log.map(\.1) == expected.map(\.1))
        #expect(h.retry.batches.isEmpty)
        #expect(h.warned(.retryExhausted))
    }

    @Test("newer batches arriving later go before the suspect")
    func newerFirst() {
        var segments = ["41", "42"]
        _ = run(&segments, attempts: 7) { $0 == "41" ? h.http(503) : .success(code: 200) }
        segments.append("44")
        let log = run(&segments, attempts: 1) { _ in .success(code: 200) }
        #expect(log.map(\.0) == ["44"])
        #expect(log.map(\.1) == [.deleteSent])
    }

    @Test("in a general outage nothing is deleted; a lone failing batch is never deleted")
    func outage() {
        var segments = ["41", "42", "43"]
        let log = run(&segments, attempts: 60) { _ in h.network(.timeout) }
        #expect(log.allSatisfy { $0.1 == .keep })
        #expect(segments == ["41", "42", "43"])
        #expect(log[5].0 == "42")

        let other = RetryHarness()
        var lone = ["41"]
        for _ in 0..<25 {
            other.elapsed.advance(byMillis: other.policy.waitMillis())
            _ = other.policy.onResult("41", other.http(500))
        }
        #expect(lone == ["41"])
        #expect(other.retry.batches["41"] == 25)
        lone.removeAll()
    }

    @Test("a segment deleted for another reason is forgotten")
    func forget() {
        _ = h.policy.onResult("41", h.http(500))
        h.policy.forget("41")
        #expect(h.retry.batches.isEmpty)
    }
}

@Suite("RetryPolicy persistence")
struct RetryPersistenceTests {
    let h = RetryHarness()

    private func restart() -> RetryPolicy {
        h.store.persist()
        return h.policy(h.deviceStore())
    }

    @Test("clearing the stored retry state ends the wait in this process too")
    func cleared() {
        _ = h.policy.onResult("41", h.http(401))
        #expect(h.policy.waitMillis() > 0)
        h.store.update { with($0) { $0.retry = .none } }
        #expect(h.policy.waitMillis() == 0)
    }

    @Test("a wait, the attempts per segment and the table position survive a restart; an ended wait is not restored")
    func survives() {
        _ = h.policy.onResult("41", h.http(429, retryAfterMs: 600_000))
        let wait = h.policy.waitMillis()
        h.clock.advance(byMillis: 100_000)
        #expect(restart().waitMillis() == wait - 100_000)

        let other = RetryHarness()
        for _ in 0..<3 { _ = other.policy.onResult("41", other.http(500)) }
        other.store.persist()
        let retry = other.deviceStore().state?.retry
        #expect(retry?.step == 3)
        #expect(retry?.batches == ["41": 3])
        #expect(retry?.lastFailure == "http_500")
        other.clock.advance(byMillis: 60_000)
        other.store.persist()
        #expect(other.policy(other.deviceStore()).waitMillis() == 0)
    }

    @Test("a clock moved back by a day clamps the wait to the longest of its kind")
    func clockBack() {
        _ = h.policy.onResult("41", h.http(401))
        h.clock.advance(byMillis: -86_400_000)
        h.store.persist()
        let restoredStore = h.deviceStore()
        let restored = h.policy(restoredStore)
        #expect(restored.waitMillis() == 3_600_000)
        #expect(restoredStore.state?.retry.pausedUntil == Date(epochMillis: h.clock.now().epochMillis + 3_600_000))

        let other = RetryHarness()
        for _ in 0..<6 { _ = other.policy.onResult("41", other.network(.io)) }
        other.clock.advance(byMillis: -86_400_000)
        other.store.persist()
        #expect(other.policy(other.deviceStore()).waitMillis() == 600_000)
    }
}
