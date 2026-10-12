import Foundation

/// An automatic session event for the pipeline to create (Session 5).
package enum SessionEvent: Sendable, Equatable {
    /// `Session Started`: timestamp the session's `startedAt`, no properties.
    case started(SessionState)
    /// `Session Ended`: backdated to the session's `lastActivity`, with `duration_ms`, in the ended
    /// session. `identity` is the person it belonged to when a reset or a user switch ended it, so
    /// it carries the previous `user_id` (Session 6); otherwise the current identity applies.
    case ended(SessionState, identity: IdentitySnapshot?)

    package var session: SessionState {
        switch self {
        case .started(let session), .ended(let session, _): return session
        }
    }

    /// `duration_ms` of an ended session; never negative.
    package var durationMs: Int64 {
        max(0, session.lastActivity.epochMillis - session.startedAt.epochMillis)
    }
}

/// The session of an event and the session events to create right before it.
package struct SessionOutcome: Sendable, Equatable {
    /// `nil` for an event in the background with no valid session (Session 3).
    package let session: SessionContext?
    package let before: [SessionEvent]

    package init(session: SessionContext?, before: [SessionEvent]) {
        self.session = session
        self.before = before
    }
}

/// Sessions (Session 1 to 6): the foreground keeps a session alive, the background starts a
/// countdown of `backgroundTimeoutMs`, and a session lasts at most `maxDurationMs`.
///
/// - No timers: a session's end is found when the app returns to the foreground, an event arrives,
///   or the process starts (Session 4).
/// - A session starts with the first event in the foreground, and `Session Started` comes right
///   before that event. Background events use a valid session but never extend it; after it ended
///   they carry none and never start one.
/// - Time in the background is measured on the elapsed clock; across a restart only the wall clock
///   is available, and a clock set back ends the session (Session 4, 6).
/// - The session lives in `PersonStore`: its id and start when it starts, its last activity on
///   backgrounding and at most every `heartbeatMs` in the foreground, with each event (Session 6).
///
/// Runs on the writer only: lifecycle changes and person changes reach it as writer messages, in
/// order with the events (Queue 1), so it needs no lock. On iOS the foreground and background
/// signals come from the application notifications (iOS Session 1) and the elapsed clock from
/// `systemUptime` (iOS Session 2); both are injected, the manager sees neither.
///
/// `emitEvents` is whether `Autocapture.sessions` is on; session ids are kept either way.
/// `requestPersist` asks the writer to write `PersonStore`.
package final class SessionManager {
    /// Session 4: internal, not configurable.
    package static let maxDurationMs: Int64 = 12 * 60 * 60 * 1000

    /// Session 6: the last activity is written at most this often in the foreground.
    package static let heartbeatMs: Int64 = 30_000

    private let personStore: PersonStore
    private let clock: any Clock
    private let elapsedClock: any ElapsedClock
    private let backgroundTimeoutMs: Int64
    private let emitEvents: Bool
    private let newSessionId: () -> String
    private let log: Log
    private let requestPersist: () -> Void

    private var active: SessionState?

    // On the elapsed clock: when the active session started, when the app went to the background
    // (nil in the foreground), and when the last activity was last written in this process (nil
    // until the first write, so a session continued from a previous process writes at its first
    // foreground event; see plan section 15, step 6.2).
    private var startedElapsed: Int64 = 0
    private var backgroundSince: Int64? = 0
    private var lastWrittenElapsed: Int64?

    package init(
        personStore: PersonStore, clock: any Clock, elapsedClock: any ElapsedClock, backgroundTimeoutMs: Int64,
        emitEvents: Bool, newSessionId: @escaping () -> String, log: Log, requestPersist: @escaping () -> Void
    ) {
        self.personStore = personStore
        self.clock = clock
        self.elapsedClock = elapsedClock
        self.backgroundTimeoutMs = backgroundTimeoutMs
        self.emitEvents = emitEvents
        self.newSessionId = newSessionId
        self.log = log
        self.requestPersist = requestPersist
    }

    /// The process starts in the background until the lifecycle says otherwise (Session 3).
    private var foreground: Bool { backgroundSince == nil }

    /// Evaluates the saved session at process start, after `PersonStore.load` (Session 6).
    package func start() -> [SessionEvent] {
        guard let saved = personStore.state?.session else { return [] }
        let now = clock.now()
        let nowMillis = now.epochMillis
        let nowElapsed = elapsedClock.elapsedMillis()
        let reason: String?
        if now < saved.lastActivity {
            reason = "the clock was set back"
        } else if nowMillis - saved.lastActivity.epochMillis >= backgroundTimeoutMs {
            reason = "the background timeout passed"
        } else if nowMillis - saved.startedAt.epochMillis >= Self.maxDurationMs {
            reason = "the maximum duration passed"
        } else {
            reason = nil
        }
        guard let reason else {
            active = saved
            startedElapsed = nowElapsed - (nowMillis - saved.startedAt.epochMillis)
            backgroundSince = nowElapsed - (nowMillis - saved.lastActivity.epochMillis)
            log.debug { "Continuing the session of the previous process" }
            return []
        }
        log.debug { "The session of the previous process ended: \(reason)" }
        clearStored(saved)
        return ended(saved)
    }

    package func onForeground() -> [SessionEvent] {
        let nowElapsed = elapsedClock.elapsedMillis()
        let events = endIfExpired(nowElapsed)
        backgroundSince = nil
        return events
    }

    /// `didEnterBackground`: the countdown starts and the last activity is written (Session 6).
    package func onBackground() {
        guard foreground else { return }
        backgroundSince = elapsedClock.elapsedMillis()
        guard let session = active else { return }
        touch(session, now: clock.now(), force: true)
    }

    /// The session for an event created at `timestamp`, ending or starting one first if needed.
    package func onEvent(timestamp: Date) -> SessionOutcome {
        let nowElapsed = elapsedClock.elapsedMillis()
        var before = endIfExpired(nowElapsed)
        if let session = active {
            if foreground { touch(session, now: timestamp, force: false) }
        } else if foreground {
            let session = SessionState(id: newSessionId(), startedAt: timestamp, lastActivity: timestamp)
            active = session
            startedElapsed = nowElapsed
            lastWrittenElapsed = nowElapsed
            personStore.update { with($0) { $0.session = session } }
            requestPersist()
            log.debug { "A new session started" }
            if emitEvents { before.append(.started(session)) }
        }
        let context = active.map { SessionContext(id: $0.id, startedAt: $0.startedAt) }
        return SessionOutcome(session: context, before: before)
    }

    /// `reset()` or a different user: the open session ends first, as the previous person's
    /// (Session 6). The next event in the foreground starts a new one.
    package func onPersonCleared(_ previous: IdentitySnapshot) -> [SessionEvent] {
        guard let session = active else { return [] }
        let last = foreground ? max(session.lastActivity, clock.now()) : session.lastActivity
        active = nil
        clearStored(session)
        guard emitEvents else { return [] }
        return [.ended(with(session) { $0.lastActivity = last }, identity: previous)]
    }

    /// Ends the open session without an event, for `optOut()` (Privacy 1).
    package func endSilently() {
        guard let session = active else { return }
        active = nil
        clearStored(session)
    }

    private func endIfExpired(_ nowElapsed: Int64) -> [SessionEvent] {
        guard let session = active else { return [] }
        let timedOut = backgroundSince.map { nowElapsed - $0 >= backgroundTimeoutMs } ?? false
        let tooLong = nowElapsed - startedElapsed >= Self.maxDurationMs
        guard timedOut || tooLong else { return [] }
        active = nil
        clearStored(session)
        return ended(session)
    }

    private func ended(_ session: SessionState) -> [SessionEvent] {
        emitEvents ? [.ended(session, identity: nil)] : []
    }

    // Moves the last activity forward; written at once on backgrounding, else at most every 30 s.
    private func touch(_ session: SessionState, now: Date, force: Bool) {
        let touched = with(session) { $0.lastActivity = max(session.lastActivity, now) }
        active = touched
        let nowElapsed = elapsedClock.elapsedMillis()
        let due = lastWrittenElapsed.map { nowElapsed - $0 >= Self.heartbeatMs } ?? true
        if force || due {
            lastWrittenElapsed = nowElapsed
            // Only the session this manager owns; a person cleared meanwhile keeps theirs cleared.
            personStore.update { state in
                state.session?.id == touched.id ? with(state) { $0.session = touched } : state
            }
            requestPersist()
        }
    }

    private func clearStored(_ session: SessionState) {
        personStore.update { state in
            state.session?.id == session.id ? with(state) { $0.session = nil } : state
        }
        requestPersist()
    }
}
