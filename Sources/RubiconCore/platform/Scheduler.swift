import Foundation

/// The two single-consumer workers of the SDK (iOS Queue 1): the writer owns every disk write, the
/// uploader has one request in flight.
package enum Worker: Sendable, CaseIterable {
    case writer
    case uploader
}

/// A piece of scheduled work that can be cancelled before it runs.
package protocol Cancellable: Sendable {
    func cancel()
}

/// Runs work on the two workers, now or after a delay. Production is two serial dispatch queues
/// (`GCDScheduler`); tests use the virtual-time `TestScheduler`, the counterpart of the Android
/// `TestDispatcher`, so no unit test waits in real time.
package protocol Scheduler: Sendable {
    /// Runs `work` on `worker` as soon as the worker is free, in the order of submission.
    func run(on worker: Worker, _ work: @escaping @Sendable () -> Void)

    /// Runs `work` on `worker` once `delayMillis` have passed, unless cancelled first. A delay of
    /// zero or less runs on the next turn of the worker, after work submitted with `run` before it.
    func schedule(after delayMillis: Int64, on worker: Worker, _ work: @escaping @Sendable () -> Void)
        -> any Cancellable

    /// Traps in debug builds when the caller is not running on `worker`; a no-op in release and in
    /// the test scheduler (iOS Queue 1: each worker's state is touched only on its own queue).
    func assertOn(_ worker: Worker)
}

/// The production scheduler: one serial `DispatchQueue` per worker, `qos: .utility`, never the main
/// queue (iOS Queue 1).
package final class GCDScheduler: Scheduler {
    private let queues: [Worker: DispatchQueue]

    package init() {
        var queues: [Worker: DispatchQueue] = [:]
        for worker in Worker.allCases {
            queues[worker] = DispatchQueue(label: "com.rubicon.analytics.\(worker)", qos: .utility)
        }
        self.queues = queues
    }

    package func run(on worker: Worker, _ work: @escaping @Sendable () -> Void) {
        queue(worker).async(execute: work)
    }

    package func schedule(
        after delayMillis: Int64, on worker: Worker, _ work: @escaping @Sendable () -> Void
    ) -> any Cancellable {
        let item = DispatchWorkItem(block: work)
        let delay = DispatchTimeInterval.milliseconds(Int(clamping: max(0, delayMillis)))
        queue(worker).asyncAfter(deadline: .now() + delay, execute: item)
        return WorkItemHandle(item: item)
    }

    package func assertOn(_ worker: Worker) {
        dispatchPrecondition(condition: .onQueue(queue(worker)))
    }

    private func queue(_ worker: Worker) -> DispatchQueue {
        // Every case is filled in `init`; the dictionary is only a way to iterate `allCases`.
        queues[worker] ?? DispatchQueue(label: "com.rubicon.analytics.\(worker)", qos: .utility)
    }

    private struct WorkItemHandle: Cancellable {
        // DispatchWorkItem is thread-safe for cancel; the struct only forwards to it.
        nonisolated(unsafe) let item: DispatchWorkItem

        func cancel() {
            item.cancel()
        }
    }
}
