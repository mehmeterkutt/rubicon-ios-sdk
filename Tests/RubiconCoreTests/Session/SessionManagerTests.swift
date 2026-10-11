import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The port of the Android `SessionManagerTest`; the Android test names are kept.
@Suite("SessionManager")
struct SessionManagerTests {
    static let t0 = Date(epochMillis: 1_759_147_200_000)
    static let timeout: Int64 = 300_000

    final class Fixture: @unchecked Sendable {
        let support = StoreTestSupport()
        let clock = TestClock(start: SessionManagerTests.t0)
        let elapsed = TestElapsedClock()
        var ids = 0
        var persists = 0
        lazy var person = personStore()
        lazy var sessions = manager()

        func personStore() -> PersonStore {
            let store = PersonStore(keyValueStore: support.files, log: support.log)
            store.load()
            return store
        }

        func manager(store: PersonStore? = nil, emitEvents: Bool = true) -> SessionManager {
            SessionManager(
                personStore: store ?? person, clock: clock, elapsedClock: elapsed,
                backgroundTimeoutMs: SessionManagerTests.timeout, emitEvents: emitEvents,
                newSessionId: { [unowned self] in
                    ids += 1
                    return "s\(ids)"
                }, log: support.log, requestPersist: { [unowned self] in persists += 1 })
        }

        /// Time passes on both clocks, as it does on a device.
        func pass(_ ms: Int64) {
            clock.advance(byMillis: ms)
            elapsed.advance(byMillis: ms)
        }

        func event() -> SessionOutcome { sessions.onEvent(timestamp: clock.now()) }

        /// A new process with the same files: what a restart looks like.
        func restart() -> [SessionEvent] {
            person.persist()
            person = personStore()
            sessions = manager()
            return sessions.start()
        }

        var now: Date { clock.now() }
    }

    let f = Fixture()
    var t0: Date { Self.t0 }
    var timeout: Int64 { Self.timeout }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func ended(_ events: [SessionEvent]) throws -> (
        session: SessionState, identity: IdentitySnapshot?, durationMs: Int64
    ) {
        guard events.count == 1, case .ended(let session, let identity) = events[0] else {
            throw Failure("expected one Session Ended, got \(events)")
        }
        return (session, identity, events[0].durationMs)
    }

    private func started(_ events: [SessionEvent]) throws -> SessionState {
        guard events.count == 1, case .started(let session) = events[0] else {
            throw Failure("expected one Session Started, got \(events)")
        }
        return session
    }

    // MARK: starting a session

    @Test("the first event in the foreground starts it, with Session Started right before")
    func firstEventStarts() throws {
        _ = f.sessions.onForeground()

        let outcome = f.event()

        let started = try started(outcome.before)
        #expect(outcome.session?.id == "s1")
        #expect(outcome.session?.startedAt == t0)
        #expect(started.startedAt == t0)
        #expect(started.id == "s1")
        #expect(f.person.state?.session == SessionState(id: "s1", startedAt: t0, lastActivity: t0))
    }

    @Test("later events in the foreground continue it without session events")
    func laterEventsContinue() {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.pass(60_000)

        let outcome = f.event()

        #expect(outcome.session?.id == "s1")
        #expect(outcome.before.isEmpty)
    }

    @Test("the foreground alone keeps it alive, with or without events")
    func foregroundKeepsAlive() {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.pass(3 * 60 * 60 * 1000)

        #expect(f.event().session?.id == "s1")
    }

    @Test("a process started in the background has no session until the foreground")
    func backgroundStart() {
        let background = f.event()

        #expect(background.session == nil)
        #expect(background.before.isEmpty)
        _ = f.sessions.onForeground()
        #expect(f.event().session?.id == "s1")
    }

    @Test("ids are kept even with session events switched off")
    func idsWithoutEvents() {
        f.sessions = f.manager(emitEvents: false)
        _ = f.sessions.onForeground()

        let outcome = f.event()

        #expect(outcome.session?.id == "s1")
        #expect(outcome.before.isEmpty)
    }

    // MARK: the background countdown

    @Test("returning before the timeout continues the same session")
    func returnBeforeTimeout() {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.sessions.onBackground()
        f.pass(timeout - 1)

        #expect(f.sessions.onForeground().isEmpty)
        #expect(f.event().session?.id == "s1")
    }

    @Test("returning after the timeout ends it, backdated to the backgrounding")
    func returnAfterTimeout() throws {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.pass(90_000)
        f.sessions.onBackground()
        let backgroundedAt = f.now
        f.pass(timeout)

        let ended = try ended(f.sessions.onForeground())

        #expect(ended.session.id == "s1")
        #expect(ended.session.lastActivity == backgroundedAt)
        #expect(ended.durationMs == 90_000)
        #expect(ended.identity == nil)
        let next = f.event()
        #expect(next.session?.id == "s2")
        _ = try started(next.before)
    }

    @Test("a background event uses a valid session but never extends it")
    func backgroundEventNeverExtends() throws {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.sessions.onBackground()
        let backgroundedAt = f.now
        f.pass(timeout / 2)

        #expect(f.event().session?.id == "s1")
        f.pass(timeout / 2)

        let ended = try ended(f.sessions.onForeground())
        #expect(ended.session.lastActivity == backgroundedAt)
    }

    @Test("the first background event after the timeout ends it and carries no session")
    func firstBackgroundEventAfterTimeout() throws {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.sessions.onBackground()
        f.pass(timeout)

        let outcome = f.event()

        #expect(outcome.session == nil)
        #expect(try ended(outcome.before).session.id == "s1")
        #expect(f.event().session == nil)
        #expect(f.ids == 1)
    }

    @Test("a clock change while backgrounded does not count")
    func clockChangeInBackground() {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.sessions.onBackground()
        f.clock.advance(byMillis: 10 * timeout)
        f.elapsed.advance(byMillis: timeout - 1)

        #expect(f.sessions.onForeground().isEmpty)
        #expect(f.event().session?.id == "s1")
    }

    // MARK: maximum duration

    @Test("a session ends after 12 hours and a new one starts in the foreground")
    func maximumDuration() throws {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.pass(SessionManager.maxDurationMs - 1)
        _ = f.event()
        f.pass(1)

        let outcome = f.event()

        try #require(outcome.before.count == 2)
        let ended = try ended([outcome.before[0]])
        #expect(ended.session.id == "s1")
        #expect(ended.durationMs == SessionManager.maxDurationMs - 1)
        _ = try started([outcome.before[1]])
        #expect(outcome.session?.id == "s2")
    }

    @Test("it is also found on returning to the foreground")
    func maximumOnForeground() throws {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.pass(SessionManager.maxDurationMs - 60_000)
        f.sessions.onBackground()
        f.pass(60_000)

        #expect(try ended(f.sessions.onForeground()).session.id == "s1")
    }

    // MARK: across restarts

    @Test("a restart within the timeout continues the session")
    func restartWithinTimeout() {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.sessions.onBackground()
        f.pass(timeout - 1_000)

        #expect(f.restart().isEmpty)
        _ = f.sessions.onForeground()
        #expect(f.event().session?.id == "s1")
    }

    @Test("a restart after the timeout ends it, backdated, and clears it")
    func restartAfterTimeout() throws {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.pass(40_000)
        f.sessions.onBackground()
        f.pass(timeout)

        let ended = try ended(f.restart())

        #expect(ended.session.id == "s1")
        #expect(ended.session.lastActivity == t0.addingTimeInterval(40))
        #expect(ended.durationMs == 40_000)
        #expect(f.person.state?.session == nil)
    }

    @Test("a process started in the background keeps counting from the last activity")
    func backgroundRestartKeepsCounting() {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.sessions.onBackground()
        f.pass(timeout - 10_000)
        _ = f.restart()

        #expect(f.event().session?.id == "s1")
        f.pass(10_000)
        #expect(f.event().session == nil)
    }

    @Test("a restart past the maximum ends it")
    func restartPastMaximum() throws {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.pass(SessionManager.maxDurationMs - 1_000)
        _ = f.event()
        f.sessions.onBackground()
        f.pass(2_000)

        #expect(try ended(f.restart()).session.id == "s1")
    }

    @Test("a clock moved back ends the saved session")
    func clockMovedBack() throws {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.pass(60_000)
        f.sessions.onBackground()
        f.clock.advance(byMillis: -86_400_000)

        let ended = try ended(f.restart())

        #expect(ended.session.id == "s1")
        #expect(f.person.state?.session == nil)
    }

    @Test("a restart with no saved session does nothing")
    func restartWithoutSession() {
        #expect(f.restart().isEmpty)
    }

    @Test("a session continued after a restart writes its heartbeat again in the foreground")
    func heartbeatAfterRestart() {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.sessions.onBackground()
        f.pass(10_000)
        _ = f.restart()
        _ = f.sessions.onForeground()
        f.pass(5_000)

        _ = f.event()

        #expect(f.person.state?.session?.lastActivity == t0.addingTimeInterval(15))
    }

    // MARK: last activity

    @Test("is written when the app goes to the background")
    func writtenOnBackground() {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.pass(5_000)

        f.sessions.onBackground()

        #expect(f.person.state?.session?.lastActivity == t0.addingTimeInterval(5))
    }

    @Test("is written at most every 30 seconds in the foreground")
    func heartbeat() {
        _ = f.sessions.onForeground()
        _ = f.event()
        var written: [Date] = []
        for _ in 0..<12 {
            f.pass(10_000)
            _ = f.event()
            if let last = f.person.state?.session?.lastActivity { written.append(last) }
        }

        var distinct: [Date] = []
        for date in written where distinct.last != date { distinct.append(date) }
        #expect(Array(distinct.dropFirst()) == [30, 60, 90, 120].map { t0.addingTimeInterval($0) })
        #expect(written.first == t0)
    }

    @Test("a crash in the foreground leaves an end at most 30 seconds early")
    func crashInForeground() throws {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.pass(25_000)
        _ = f.event()
        f.pass(25_000)
        _ = f.event()

        // The process dies here without didEnterBackground.
        f.pass(timeout + 60_000)
        let ended = try ended(f.restart())

        #expect(t0.addingTimeInterval(50).timeIntervalSince(ended.session.lastActivity) <= 30)
    }

    // MARK: reset and a change of user

    let previous = IdentitySnapshot(userId: "user-42", deviceId: "device-1", superProperties: ["plan": .string("pro")])

    @Test("ends the session first as the previous user, and the next event starts a new one")
    func personCleared() throws {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.pass(20_000)
        f.person.update { _ in .anonymous }

        let ended = try ended(f.sessions.onPersonCleared(previous))

        #expect(ended.session.id == "s1")
        #expect(ended.identity == previous)
        #expect(ended.session.lastActivity == t0.addingTimeInterval(20))
        let next = f.event()
        _ = try started(next.before)
        #expect(next.session?.id == "s2")
    }

    @Test("a cleared person never gets the old session written back")
    func clearedPersonKeepsCleared() {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.person.update { _ in .anonymous }

        f.sessions.onBackground()

        #expect(f.person.state?.session == nil)
    }

    @Test("without an open session nothing is produced")
    func nothingWithoutSession() {
        #expect(f.sessions.onPersonCleared(previous).isEmpty)
    }

    @Test("in the background the next event carries no session")
    func backgroundAfterPersonCleared() {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.sessions.onBackground()
        _ = f.sessions.onPersonCleared(previous)

        #expect(f.event().session == nil)
    }

    @Test("opting out ends the session silently")
    func endSilently() {
        _ = f.sessions.onForeground()
        _ = f.event()

        f.sessions.endSilently()

        #expect(f.person.state?.session == nil)
        #expect(f.event().session?.id != "s1")
    }

    @Test("every change asks the writer to persist")
    func persists() {
        _ = f.sessions.onForeground()
        _ = f.event()
        f.sessions.onBackground()

        #expect(f.persists >= 2)
    }
}
