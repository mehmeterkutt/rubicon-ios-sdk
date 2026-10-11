import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("TestScheduler")
struct TestSchedulerTests {
    @Test("runs nothing until asked, then runs due work in submission order")
    func runsInOrder() {
        let scheduler = TestScheduler()
        let seen = Locked<[String]>([])
        scheduler.run(on: .writer) { seen.withLock { $0.append("a") } }
        scheduler.run(on: .uploader) { seen.withLock { $0.append("b") } }
        scheduler.run(on: .writer) { seen.withLock { $0.append("c") } }

        #expect(seen.current.isEmpty)
        #expect(scheduler.pendingCount == 3)
        scheduler.runUntilIdle()

        #expect(seen.current == ["a", "b", "c"])
        #expect(scheduler.pendingCount == 0)
    }

    @Test("delayed work never runs early and runs in due order, with the clock at its due time")
    func delayedWork() {
        let scheduler = TestScheduler()
        let seen = Locked<[(String, Int64)]>([])
        _ = scheduler.schedule(after: 300, on: .uploader) { seen.withLock { $0.append(("late", scheduler.nowMillis)) } }
        _ = scheduler.schedule(after: 100, on: .writer) { seen.withLock { $0.append(("early", scheduler.nowMillis)) } }
        scheduler.run(on: .writer) { seen.withLock { $0.append(("now", scheduler.nowMillis)) } }

        scheduler.advance(byMillis: 99)
        #expect(seen.current.map(\.0) == ["now"])
        scheduler.advance(byMillis: 1)
        #expect(seen.current.map(\.0) == ["now", "early"])
        scheduler.advance(byMillis: 1000)

        #expect(seen.current.map(\.0) == ["now", "early", "late"])
        #expect(seen.current.map(\.1) == [0, 100, 300])
        #expect(scheduler.nowMillis == 1100)
    }

    @Test("cancelled work does not run")
    func cancellation() {
        let scheduler = TestScheduler()
        let ran = AtomicFlag()
        let handle = scheduler.schedule(after: 50, on: .writer) { ran.set() }

        handle.cancel()
        scheduler.advance(byMillis: 100)

        #expect(!ran.isSet)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("work enqueued by running work runs in the same drain when it is due")
    func reentrantWork() {
        let scheduler = TestScheduler()
        let seen = Locked<[String]>([])
        scheduler.run(on: .writer) {
            seen.withLock { $0.append("outer") }
            scheduler.run(on: .uploader) { seen.withLock { $0.append("inner") } }
            _ = scheduler.schedule(after: 10, on: .uploader) { seen.withLock { $0.append("timer") } }
        }

        scheduler.runUntilIdle()
        #expect(seen.current == ["outer", "inner"])
        scheduler.advance(byMillis: 10)
        #expect(seen.current == ["outer", "inner", "timer"])
    }

    @Test("a negative delay runs on the next turn, after work already submitted")
    func negativeDelay() {
        let scheduler = TestScheduler()
        let seen = Locked<[String]>([])
        scheduler.run(on: .writer) { seen.withLock { $0.append("first") } }
        _ = scheduler.schedule(after: -5, on: .writer) { seen.withLock { $0.append("second") } }

        scheduler.runUntilIdle()

        #expect(seen.current == ["first", "second"])
    }

    @Test("reports the worker that is running")
    func assertOnWorker() {
        let scheduler = TestScheduler()
        scheduler.run(on: .uploader) { scheduler.assertOn(.uploader) }
        scheduler.runUntilIdle()
    }
}

@Suite("GCDScheduler")
struct GCDSchedulerTests {
    @Test("each worker runs one task at a time and keeps order")
    func serialWorkers() {
        let scheduler = GCDScheduler()
        let seen = Locked<[Int]>([])
        let done = DispatchSemaphore(value: 0)
        for i in 0..<20 {
            scheduler.run(on: .writer) {
                scheduler.assertOn(.writer)
                seen.withLock { $0.append(i) }
                if i == 19 { done.signal() }
            }
        }
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(seen.current == Array(0..<20))
    }

    @Test("a cancelled delayed item does not run, a kept one does")
    func delayedItems() {
        let scheduler = GCDScheduler()
        let ran = Locked<[String]>([])
        let done = DispatchSemaphore(value: 0)
        let cancelled = scheduler.schedule(after: 20, on: .uploader) { ran.withLock { $0.append("cancelled") } }
        cancelled.cancel()
        _ = scheduler.schedule(after: 20, on: .uploader) {
            ran.withLock { $0.append("kept") }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(ran.current == ["kept"])
    }
}
