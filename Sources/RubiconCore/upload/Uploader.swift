import Foundation

/// The single consumer that sends (Queue 1, 4; Retry 1 to 5; iOS Queue 1, 2): one request in flight,
/// batches oldest first, each closed segment one batch, deleted only after the server acknowledged
/// it.
///
/// - It wakes on the writer's flushes (`signal()`), on the network coming back, and when a wait ends
///   it tries again by itself (Retry 2). Wakes conflate: a drain sends until nothing is left, a gate
///   closes or a failure starts a wait; wakes arriving meanwhile run one more drain at most.
/// - Gates (Queue 2): no attempt while offline, while a wait is running, while collection is
///   stopped (kill switch or outside `sample_rate`), or while `uploadsAllowed` says no (opted out or
///   consent pending). Released gates resume at the next wake.
/// - Each attempt writes the body with a fresh `sent_at` (Event Model 5), sends it once, and lets
///   `policy` decide; it stops at the first failure and waits. A wait is a cancellable item on the
///   uploader queue; any wake re-checks the rules, so the network's return ends a network wait at once
///   while other waits go on (Android log 6.4).
/// - The remote configuration is fetched once per launch, the first time the network is there, also
///   while uploads are gated (Configuration 1, Privacy 4).
/// - Nothing runs before the writer is ready (stores loaded, event store open); `startUp` restores
///   the retry state and fetches the remote configuration, and sends nothing (Queue 2).
/// - The background flush (iOS Queue 2): `beginBackgroundFlush(onDone:)` is told when the drain
///   that follows ends, for whatever reason, so the platform can end its background task;
///   `expireBackgroundFlush()` cancels the request in flight, which the policy records as waiting.
/// - Retry state lives in `DeviceStore`; `requestPersist` asks the writer to write it (Queue 1).
// Every field below `startedFlag` is touched only on the uploader queue; the flags and the
// background-flush slot have their own locks.
package final class Uploader: @unchecked Sendable {
    private let eventStore: any EventStore
    private let transport: any HttpTransport
    private let batchURL: URL
    private let policy: RetryPolicy
    private let remote: RemoteConfigClient
    private let networkMonitor: any NetworkMonitor
    private let scheduler: any Scheduler
    private let flags: RuntimeFlags
    private let deviceStore: DeviceStore
    private let clock: any Clock
    private let log: Log
    private let observer: EventObserver?
    private let writerReady: @Sendable () -> Bool
    private let requestPersist: @Sendable () -> Void
    private let uploadsAllowed: @Sendable () -> Bool

    private let pending = AtomicFlag()
    private let networkReturned = AtomicFlag()
    private let startedFlag = AtomicFlag()
    private let busy = AtomicFlag()
    private let stoppedFlag = AtomicFlag()
    private let backgroundFlush = Locked<(@Sendable () -> Void)?>(nil)

    // Uploader queue only.
    private var remoteFetched = false
    private var wait: (any Cancellable)?
    private var networkToken: (any ListenerToken)?

    package init(
        eventStore: any EventStore, transport: any HttpTransport, batchURL: URL, policy: RetryPolicy,
        remote: RemoteConfigClient, networkMonitor: any NetworkMonitor, scheduler: any Scheduler, flags: RuntimeFlags,
        deviceStore: DeviceStore, clock: any Clock, log: Log, observer: EventObserver?,
        writerReady: @escaping @Sendable () -> Bool, requestPersist: @escaping @Sendable () -> Void,
        uploadsAllowed: @escaping @Sendable () -> Bool = { true }
    ) {
        self.eventStore = eventStore
        self.transport = transport
        self.batchURL = batchURL
        self.policy = policy
        self.remote = remote
        self.networkMonitor = networkMonitor
        self.scheduler = scheduler
        self.flags = flags
        self.deviceStore = deviceStore
        self.clock = clock
        self.log = log
        self.observer = observer
        self.writerReady = writerReady
        self.requestPersist = requestPersist
        self.uploadsAllowed = uploadsAllowed
    }

    /// `true` once the startup work ran, after the writer became ready.
    package var isStarted: Bool { startedFlag.isSet }

    /// No drain running and no wake waiting; a running wait does not count (for `flushBlocking`).
    package var isIdle: Bool { !busy.isSet && !pending.isSet }

    /// Runs the startup work as soon as the writer is ready; call once, and again from the writer's
    /// `onReady` when the stores load later (a process started before the first unlock).
    package func start() {
        scheduler.run(on: .uploader) { [self] in
            if startUpIfReady() && pending.isSet { drain() }
        }
    }

    /// A flush: wakes the uploader, which drains at its next turn. From any thread.
    package func signal() {
        pending.set()
        scheduler.run(on: .uploader) { [self] in drain() }
    }

    /// Stops the uploader for a test that starts another instance on the same files: a running wait
    /// and the network listener are cancelled and later wakes are ignored. A request in flight
    /// finishes first (at most the resource timeout of HTTP 3).
    package func shutdown() {
        stoppedFlag.set()
        scheduler.run(on: .uploader) { [self] in
            wait?.cancel()
            wait = nil
            networkToken?.cancel()
        }
    }

    /// The platform's background task began around the background flush (iOS Queue 2): `onDone`
    /// runs on the uploader queue when the drain that follows ends, whatever ended it, or at once
    /// when the uploader cannot run. A later call replaces an earlier one.
    package func beginBackgroundFlush(onDone: @escaping @Sendable () -> Void) {
        backgroundFlush.withLock { $0 = onDone }
        scheduler.run(on: .uploader) { [self] in
            if !startUpIfReady() { finishBackgroundFlush() }
        }
    }

    /// The background task is about to expire (iOS Queue 2): the request in flight is cancelled, the
    /// batch stays on disk, and the platform ends its task itself; `onDone` is not called.
    package func expireBackgroundFlush() {
        backgroundFlush.withLock { $0 = nil }
        transport.cancelCurrent()
    }

    // MARK: - The uploader queue

    @discardableResult
    private func startUpIfReady() -> Bool {
        scheduler.assertOn(.uploader)
        if stoppedFlag.isSet { return false }
        if startedFlag.isSet { return true }
        guard writerReady() else { return false }
        policy.restore()
        networkToken = networkMonitor.addListener { [weak self] connected in
            guard let self, connected else { return }
            networkReturned.set()
            signal()
        }
        startedFlag.set()
        // No upload at startup (Queue 2): leftovers wait for a flush trigger, such as the interval
        // the writer starts for them. Only the remote configuration is fetched now.
        if networkMonitor.isConnected { fetchRemoteOnce() }
        return true
    }

    /// Sends batches until none is left, a gate closes, or a failure starts a wait.
    private func drain() {
        scheduler.assertOn(.uploader)
        if stoppedFlag.isSet { return }
        guard pending.clear() else { return }
        guard startUpIfReady() else {
            // Not ready yet: the wake is kept for the writer's `onReady`.
            pending.set()
            finishBackgroundFlush()
            return
        }
        busy.set()
        defer {
            busy.clear()
            finishBackgroundFlush()
        }
        wait?.cancel()
        wait = nil
        var unreadable: Set<Int64> = []
        while true {
            // Checked before every batch, not only at the start: a `shutdown` that lands mid-drain
            // must not be followed by another request (the transport's session is gone by then).
            if stoppedFlag.isSet { return }
            if networkReturned.clear() { policy.onNetworkRegained() }
            guard networkMonitor.isConnected else { return }
            fetchRemoteOnce()
            guard flags.isCollecting, uploadsAllowed() else { return }
            let waitMillis = policy.waitMillis()
            if waitMillis > 0 {
                // The wait ends on the uploader queue and checks the rules again; a wake before that
                // cancels and re-checks too, so a network wait ends when the network returns (Retry 2).
                wait = scheduler.schedule(after: waitMillis, on: .uploader) { [weak self] in self?.signal() }
                return
            }
            eventStore.expire()
            let candidates = eventStore.closedSegments().filter { !unreadable.contains($0) }
            guard let next = policy.order(candidates.map(Self.name(of:))).first, let index = Int64(next) else { return }
            let outcome = attempt(index: index, name: next)
            requestPersist()
            switch outcome {
            case .unreadable: unreadable.insert(index)
            case .interrupted: return
            case .done: break
            }
        }
    }

    private enum Outcome {
        /// Sent, dropped, or kept with a wait: the loop decides what is next.
        case done
        /// The segment could not be read and is skipped for the rest of this drain.
        case unreadable
        /// The request was cancelled by the background expiration (iOS Queue 2): the process is being
        /// suspended, so the drain ends; the next trigger tries again at once.
        case interrupted
    }

    /// One batch.
    private func attempt(index: Int64, name: String) -> Outcome {
        let batch: [String]
        let body: Data
        switch eventStore.writeBatch(index: index, sentAt: clock.now()) {
        case .unreadable(let deleted, _):
            if deleted { policy.forget(name) }
            return deleted ? .done : .unreadable
        case .locked:
            return .unreadable
        case .written(let messageIds, let data):
            batch = messageIds
            body = data
        }
        if batch.isEmpty {
            // Every line was corrupt or expired: nothing to send (Disk 5, Queue 5).
            delete(index: index, name: name)
            return .done
        }
        let response = transport.execute(HttpRequest(method: .post, url: batchURL, body: body))
        switch policy.onResult(name, response) {
        case .deleteSent:
            delete(index: index, name: name)
            log.debug { "Uploaded \(batch.count) events from segment \(name)" }
            observe(.sent(messageIds: batch))
        case .deleteRejected:
            drop(index: index, name: name, batch: batch, reason: .rejected)
        case .deleteExhausted:
            drop(index: index, name: name, batch: batch, reason: .retryExhausted)
        case .keep:
            if RetryGroup.of(response) == .interrupted { return .interrupted }
        }
        return .done
    }

    private func drop(index: Int64, name: String, batch: [String], reason: DropReason) {
        delete(index: index, name: name)
        deviceStore.countDropped(reason, count: batch.count)
        observe(.dropped(messageIds: batch, reason: reason))
    }

    private func delete(index: Int64, name: String) {
        eventStore.deleteSegment(index)
        policy.forget(name)
    }

    private func fetchRemoteOnce() {
        if remoteFetched { return }
        remoteFetched = true
        remote.fetch()
    }

    private func finishBackgroundFlush() {
        let done: (@Sendable () -> Void)? = backgroundFlush.withLock { slot in
            defer { slot = nil }
            return slot
        }
        done?()
    }

    private func observe(_ update: EventUpdate) {
        guard let observer else { return }
        log.callbacks.notifyObserver { observer(update) }
    }

    /// The segment name the retry state keys on, such as `0000000041` (Retry 5).
    private static func name(of index: Int64) -> String {
        let digits = String(index)
        return String(repeating: "0", count: max(0, 10 - digits.count)) + digits
    }
}
