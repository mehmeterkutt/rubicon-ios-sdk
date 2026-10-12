import Foundation
import Rubicon
import RubiconCore
import RubiconObjCSupport

/// The instance's log as the boxed hooks see it: `nil` until the factory has created the instance,
/// so a block that raises during `make` (the first automatic events, the first log lines) is
/// remembered and reported as soon as the log is attached.
// Sendable by the lock: every field is read and written inside `state`.
final class RBNHookLog: @unchecked Sendable {
    private struct State {
        var log: Log?
        var hooksThrew: [String] = []
        var loggerFailures: [RBNExceptionError] = []
        var observerFailures: [RBNExceptionError] = []
    }

    private let state = Locked(State())

    func attach(_ log: Log) {
        let pending = state.withLock { state -> State in
            let pending = state
            state = State(log: log)
            return pending
        }
        for name in pending.hooksThrew { hookThrew(name, log: log) }
        for error in pending.loggerFailures { log.callbacks.reportLoggerFailure(error) }
        for error in pending.observerFailures { log.callbacks.reportObserverFailure(error) }
    }

    func hookThrew(_ exception: NSException) {
        let log = state.withLock { state -> Log? in
            if state.log == nil { state.hooksThrew.append(exception.name.rawValue) }
            return state.log
        }
        if let log { hookThrew(exception.name.rawValue, log: log) }
    }

    func loggerThrew(_ exception: NSException) {
        let error = RBNExceptionError(exception)
        let log = state.withLock { state -> Log? in
            if state.log == nil { state.loggerFailures.append(error) }
            return state.log
        }
        log?.callbacks.reportLoggerFailure(error)
    }

    func observerThrew(_ exception: NSException) {
        let error = RBNExceptionError(exception)
        let log = state.withLock { state -> Log? in
            if state.log == nil { state.observerFailures.append(error) }
            return state.log
        }
        log?.callbacks.reportObserverFailure(error)
    }

    private func hookThrew(_ name: String, log: Log) {
        log.error(.hookThrew) { "A beforeSend block raised \(name); the event was dropped" }
    }
}

/// Boxes the Objective-C blocks into the Swift hooks with `NSException` caught (iOS Public API 6,
/// iOS Logging 2): a raising `beforeSend` drops the event with `before_send` and logs `HOOK_THREW`; a
/// raising logger is reported to the instance, which replaces it with the default sink
/// (`LOGGER_THREW`); a raising observer is switched off (`OBSERVER_THREW`). The Swift side cannot
/// catch any of these; this is the one place the Android rule of Logging 4b lives on iOS.
///
/// The catching happens in `RubiconObjCSupport`, which calls the block directly: between its `@try`
/// and the developer's code there is only the bridging thunk, never a lock or a stored-property
/// access, because an exception unwinding through such a Swift frame crashes later. The logger and
/// the observer stop calling their block after the first exception even before the instance's log
/// exists, so a block that raises during `make` is called once.
enum RBNHookBox {
    static func beforeSend(_ block: @escaping RBNBeforeSend, log: RBNHookLog) -> BeforeSend {
        { event in
            let view = RBNEvent.view(of: event)
            var exception: NSException?
            let returned = RBNCallReturningObject(
                { argument in
                    guard let argument = argument as? RBNEvent else { return nil }
                    return block(argument)
                }, view, &exception)
            if let exception {
                log.hookThrew(exception)
                return nil
            }
            // The same view back means "unchanged or changed in place"; another view is another event,
            // which the pipeline's rules then judge (HookRules).
            return (returned as? RBNEvent)?.updated
        }
    }

    static func logger(_ block: @escaping RBNLogger, log: RBNHookLog) -> RubiconLogger {
        let threw = AtomicFlag()
        return { level, message, error in
            if threw.isSet { return }
            var exception: NSException?
            RBNCallLogger(
                { level, message, error in
                    block(RBNLogLevel(rawValue: level) ?? .error, message, error.map { $0 as NSError })
                },
                RBNLogLevel(level).rawValue, message, error.map { $0 as NSError }, &exception)
            if let exception, threw.set() { log.loggerThrew(exception) }
        }
    }

    static func observer(_ block: @escaping RBNEventObserver, log: RBNHookLog) -> EventObserver {
        let threw = AtomicFlag()
        return { update in
            if threw.isSet { return }
            var exception: NSException?
            RBNCallWithObject(
                { argument in
                    if let argument = argument as? RBNEventUpdate { block(argument) }
                }, RBNEventUpdate(update), &exception)
            if let exception, threw.set() { log.observerThrew(exception) }
        }
    }
}

/// An `NSException` as an `Error`, for the log line: the name only, never the reason or the stack.
struct RBNExceptionError: Error, CustomStringConvertible {
    let name: String

    init(_ exception: NSException) {
        name = exception.name.rawValue
    }

    var description: String { "NSException \(name)" }
}
