import Foundation
import RubiconCore

/// A `Scheduler` with virtual time, the counterpart of the Android `TestDispatcher`: nothing runs
/// until the test advances the clock or asks for the pending work to run, and due work runs in
/// order of its due time, then of its submission, never early. Both workers share one virtual
/// timeline, so a test sees one deterministic interleaving.
///
/// ```swift
/// let scheduler = TestScheduler()
/// scheduler.run(on: .writer) { ... }
/// scheduler.runUntilIdle()            // runs everything due now
/// scheduler.advance(byMillis: 60_000) // runs timers due within the next minute, in order
/// ```
package final class TestScheduler: Scheduler, @unchecked Sendable {
    private struct Item {
        let sequence: Int
        let due: Int64
        let worker: Worker
        let work: @Sendable () -> Void
        let cancelled: AtomicFlag
    }

    private struct State {
        var now: Int64 = 0
        var sequence = 0
        var items: [Item] = []
        var running: Worker?
    }

    // Guarded by `state`; `work` closures run outside the lock.
    private let state = Locked(State())

    package init() {}

    /// The virtual time in milliseconds since the scheduler was created.
    package var nowMillis: Int64 {
        state.current.now
    }

    /// Work that has not run yet, cancelled items excluded.
    package var pendingCount: Int {
        state.current.items.filter { !$0.cancelled.isSet }.count
    }

    package func run(on worker: Worker, _ work: @escaping @Sendable () -> Void) {
        _ = enqueue(delay: 0, worker: worker, work: work)
    }

    package func schedule(
        after delayMillis: Int64, on worker: Worker, _ work: @escaping @Sendable () -> Void
    ) -> any Cancellable {
        enqueue(delay: max(0, delayMillis), worker: worker, work: work)
    }

    package func assertOn(_ worker: Worker) {
        precondition(state.current.running == worker, "Expected to run on \(worker)")
    }

    /// Runs every item due at the current virtual time, including items they enqueue with no delay.
    package func runUntilIdle() {
        drain(until: nowMillis)
    }

    /// Moves the virtual clock forward by `millis`, running every item that becomes due on the way,
    /// in due order, with the clock set to each item's due time while it runs.
    package func advance(byMillis millis: Int64) {
        precondition(millis >= 0, "Virtual time never moves back")
        drain(until: nowMillis + millis)
    }

    private func enqueue(delay: Int64, worker: Worker, work: @escaping @Sendable () -> Void) -> Handle {
        let flag = AtomicFlag()
        state.withLock { s in
            s.sequence += 1
            s.items.append(Item(sequence: s.sequence, due: s.now + delay, worker: worker, work: work, cancelled: flag))
        }
        return Handle(flag: flag)
    }

    private func drain(until target: Int64) {
        while true {
            let next: Item? = state.withLock { s in
                s.items.removeAll { $0.cancelled.isSet }
                guard
                    let index = s.items.indices.min(by: {
                        (s.items[$0].due, s.items[$0].sequence) < (s.items[$1].due, s.items[$1].sequence)
                    }),
                    s.items[index].due <= target
                else { return nil }
                let item = s.items.remove(at: index)
                s.now = max(s.now, item.due)
                s.running = item.worker
                return item
            }
            guard let item = next else { break }
            item.work()
            state.withLock { $0.running = nil }
        }
        state.withLock { $0.now = max($0.now, target) }
    }

    private struct Handle: Cancellable {
        let flag: AtomicFlag

        func cancel() {
            flag.set()
        }
    }
}
