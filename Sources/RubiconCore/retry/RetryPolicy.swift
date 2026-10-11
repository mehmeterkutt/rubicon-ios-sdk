import Foundation

/// Decides what becomes of a batch after each upload attempt and when the next attempt may start
/// (Retry 1 to 5, iOS Retry 2). One wait for the whole pipeline, since one batch is attempted at a
/// time; failed attempts per segment for the poison batch rule. The uploader owns the loop and the
/// network check; this class owns the rules.
///
/// - Waits within a process run on the elapsed clock (`systemUptime` on iOS); the wall-clock end
///   of a wait is kept in `DeviceStore` so a restart cannot bypass it, clamped when the clock was
///   set back (Retry 5).
/// - Group B backs off along `backoffMillis` with jitter x0.5..1.5 and resets on success (Retry 2).
/// - Group C honours `Retry-After`: at least 1 s, at most 1 h, jitter forward only x1.0..1.1,
///   never past the hour; without the header it uses the table (Retry 3).
/// - Group E pauses one hour, jitter x0.8..1.2, and logs an ERROR once per code (Retry 1, 2).
/// - The network ending a wait only ends a group B wait caused by the network (Retry 2, 6).
/// - A cancelled attempt is a waiting state: no step, no wait, not counted against the batch,
///   `last_failure = "cancelled"` (iOS Retry 2).
///
/// Called from the uploader only; not thread-safe.
package final class RetryPolicy: @unchecked Sendable {
    /// Waits of group B, by consecutive failure (Retry 2).
    package static let backoffMillis: [Int64] = [2_000, 10_000, 30_000, 120_000, 300_000, 600_000]
    /// The longest wait of groups C and E, and the cap of `Retry-After` (Retry 2, 3).
    package static let maxWaitMillis: Int64 = 3_600_000
    package static let minRetryAfterMillis: Int64 = 1_000
    /// Consecutive group B failures before the next batch is tried first (Retry 3).
    package static let suspectAfter = 5
    /// Failures after which a batch others overtook is deleted (Retry 3).
    package static let exhaustedAfter = 10

    private static let networkFailures: Set<String> = ["timeout", "connect", "io", "dns"]

    /// What the uploader does with the batch it just attempted.
    package enum Decision: Sendable, Equatable {
        /// Accepted: delete it.
        case deleteSent
        /// Group D: delete it, counting its events as `rejected`.
        case deleteRejected
        /// A poison batch: delete it, counting its events as `retry_exhausted`.
        case deleteExhausted
        /// Keep it and wait for `waitMillis()`.
        case keep
    }

    private let deviceStore: DeviceStore
    private let clock: any Clock
    private let elapsedClock: any ElapsedClock
    private let random: any RandomSource
    private let log: Log
    // The end of the current wait on the elapsed clock; 0 when there is none. Uploader only.
    private var deadline: Int64 = 0
    // Suspect segments that another batch overtook successfully in this process (Retry 3, step 3).
    private var proven: Set<String> = []

    package init(
        deviceStore: DeviceStore, clock: any Clock, elapsedClock: any ElapsedClock, random: any RandomSource, log: Log
    ) {
        self.deviceStore = deviceStore
        self.clock = clock
        self.elapsedClock = elapsedClock
        self.random = random
        self.log = log
    }

    private var state: RetryState { deviceStore.state?.retry ?? .none }

    /// Restores the stored wait at startup, after `DeviceStore.load` (Retry 5).
    package func restore() {
        let stored = state
        guard let until = stored.pausedUntil else { return }
        let now = clock.now().epochMillis
        let longest = Self.longestWait(stored.pauseKind)
        let remaining = min(until.epochMillis - now, longest)
        if until.epochMillis - now > longest {
            // The clock was set back: the wait is cut to the longest of its kind, from now.
            update { $0.pausedUntil = Date(epochMillis: now + longest) }
            log.debug { "A stored wait lay beyond the longest of its kind; it now ends in \(longest) ms" }
        }
        deadline = remaining > 0 ? elapsedClock.elapsedMillis() + remaining : 0
    }

    /// Milliseconds until the next attempt may start; 0 when it may start now. A wait whose stored
    /// state is gone, as after `clearLocalData()` (Privacy 3), has ended.
    package func waitMillis() -> Int64 {
        if deadline > 0 && state.pausedUntil == nil { deadline = 0 }
        return max(0, deadline - elapsedClock.elapsedMillis())
    }

    /// The order in which to try `segments` (oldest first): a segment that failed `suspectAfter`
    /// times in a row goes after the others, so the next batch is tried (Retry 3, step 1).
    package func order(_ segments: [String]) -> [String] {
        let failures = state.batches
        let suspects = segments.filter { (failures[$0] ?? 0) >= Self.suspectAfter }
        let healthy = segments.filter { (failures[$0] ?? 0) < Self.suspectAfter }
        return healthy + suspects
    }

    /// Records the result of uploading `segment` and returns what to do with it.
    package func onResult(_ segment: String, _ result: HttpResult) -> Decision {
        switch RetryGroup.of(result) {
        case .success:
            // Every suspect that this batch overtook is now known to be the problem.
            let overtaken = state.batches.filter { $0.value >= Self.suspectAfter }.keys.filter { $0 != segment }
            proven.formUnion(overtaken)
            deadline = 0
            update { current in
                var batches = current.batches
                batches[segment] = nil
                current = RetryState(batches: batches)
            }
            return .deleteSent
        case .badBatch:
            if case .httpError(let code, _, _) = result {
                log.warn(.batchRejected) { "The server rejected a batch with \(code); it was deleted" }
            }
            forget(segment)
            return .deleteRejected
        case .transient:
            return transient(segment, result)
        case .throttle:
            if case .httpError(_, _, let retryAfterMs) = result { return throttle(result, retryAfterMs: retryAfterMs) }
            return .keep
        case .config:
            return config(result)
        case .interrupted:
            deadline = 0
            update { current in
                current.pausedUntil = nil
                current.lastFailure = Self.failureName(result)
            }
            log.debug { "Upload cancelled before it could finish; the next trigger tries again" }
            return .keep
        }
    }

    /// Ends a wait caused by the network when the network returns; the table position is kept (Retry 2).
    package func onNetworkRegained() {
        let current = state
        if current.pauseKind == .transient, let failure = current.lastFailure, Self.networkFailures.contains(failure),
            waitMillis() > 0
        {
            deadline = 0
            update { $0.pausedUntil = nil }
            log.debug { "The network returned; the wait after a network failure ends" }
        }
    }

    /// Forgets a segment deleted for any reason, so its attempt count does not outlive it.
    package func forget(_ segment: String) {
        proven.remove(segment)
        if state.batches[segment] != nil { update { $0.batches[segment] = nil } }
    }

    private func transient(_ segment: String, _ result: HttpResult) -> Decision {
        let failures = (state.batches[segment] ?? 0) + 1
        if failures >= Self.exhaustedAfter && proven.contains(segment) {
            log.warn(.retryExhausted) { "A batch failed \(failures) times while others were accepted; it was deleted" }
            forget(segment)
            // The server works, as other batches show: no wait before the next one.
            return .deleteExhausted
        }
        let step = state.step + 1
        let wait = Int64(
            Double(Self.backoffMillis[min(step - 1, Self.backoffMillis.count - 1)]) * random.nextDouble(in: 0.5..<1.5))
        pause(wait, kind: .transient, failure: Self.failureName(result)) { current in
            current.step = step
            current.batches[segment] = failures
        }
        return .keep
    }

    private func throttle(_ result: HttpResult, retryAfterMs: Int64?) -> Decision {
        if let retryAfterMs {
            let asked = min(max(retryAfterMs, Self.minRetryAfterMillis), Self.maxWaitMillis)
            // Never earlier than asked, never past the hour.
            let wait = min(max(Int64(Double(asked) * random.nextDouble(in: 1.0..<1.1)), asked), Self.maxWaitMillis)
            pause(wait, kind: .throttle, failure: Self.failureName(result)) { _ in }
        } else {
            let step = state.step + 1
            let wait = Int64(
                Double(Self.backoffMillis[min(step - 1, Self.backoffMillis.count - 1)])
                    * random.nextDouble(in: 0.5..<1.5))
            pause(wait, kind: .throttle, failure: Self.failureName(result)) { $0.step = step }
        }
        return .keep
    }

    private func config(_ result: HttpResult) -> Decision {
        logConfigError(result)
        let wait = Int64(Double(Self.maxWaitMillis) * random.nextDouble(in: 0.8..<1.2))
        pause(wait, kind: .config, failure: Self.failureName(result)) { _ in }
        return .keep
    }

    private func pause(_ waitMillis: Int64, kind: PauseKind, failure: String, _ change: (inout RetryState) -> Void) {
        deadline = elapsedClock.elapsedMillis() + waitMillis
        let until = Date(epochMillis: clock.now().epochMillis + waitMillis)
        update { current in
            change(&current)
            current.pausedUntil = until
            current.pauseKind = kind
            current.lastFailure = failure
        }
        log.debug { "Upload failed (\(failure)); waiting \(waitMillis) ms" }
    }

    // The transport already logged redirects (HTTP_REDIRECT), blocked hosts, TLS and unexpected errors.
    private func logConfigError(_ result: HttpResult) {
        guard case .httpError(let code, _, _) = result else { return }
        switch code {
        case 401, 403:
            log.error(.uploadUnauthorized) { "The server rejected the API key (\(code)); uploads pause for an hour" }
        case 404, 410:
            log.error(.uploadEndpointMissing) { "The upload endpoint does not exist (\(code)); check host" }
        case 413:
            log.error(.uploadTooLarge) { "A gateway rejected the request size (413); uploads pause for an hour" }
        case 501, 505:
            log.error(.uploadNotSupported) { "The server does not support the request (\(code))" }
        default:
            break
        }
    }

    private func update(_ change: (inout RetryState) -> Void) {
        deviceStore.update { state in
            var copy = state
            change(&copy.retry)
            return copy
        }
    }

    /// The stored `last_failure`: a failure kind such as `timeout` or `cancelled`, or `http_503`.
    package static func failureName(_ result: HttpResult) -> String {
        switch result {
        case .networkFailure(let kind, _): return kind.rawValue
        case .httpError(let code, _, _): return "http_\(code)"
        case .success: return "none"
        }
    }

    /// The longest wait of a kind, for the clock check at restore (Retry 5).
    package static func longestWait(_ kind: PauseKind?) -> Int64 {
        switch kind {
        case .throttle, .config: return maxWaitMillis
        case .transient, nil: return backoffMillis[backoffMillis.count - 1]
        }
    }
}
