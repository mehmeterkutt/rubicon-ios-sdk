import Foundation

/// Calls the developer's logger and event observer so that neither can break the SDK (Logging 4b,
/// iOS Logging 2):
///
/// - a log line or observer update caused on the same thread by one of these callbacks, for
///   example by the logger calling the SDK, is ignored, which prevents endless loops;
/// - a logger reported as failed is replaced by `fallback` for the rest of the process and
///   `onLoggerFailed` is told once; an observer reported as failed is switched off and
///   `onObserverFailed` is told once. Swift closures cannot throw into the SDK, so the reports come
///   from the Objective-C wrapper, which catches `NSException` around its blocks.
package final class CallbackGuard: @unchecked Sendable {
    /// The key of the per-thread flag that marks "inside a callback".
    package static let threadKey = "com.rubicon.analytics.inCallback"

    private let fallback: RubiconLogger
    // Guarded by `logger`'s lock; the flags are atomic.
    private let logger: Locked<RubiconLogger>
    private let loggerReplaced = AtomicFlag()
    private let observerFailed = AtomicFlag()
    private let loggerFailedHandler = Locked<(@Sendable (any Error) -> Void)?>(nil)
    private let observerFailedHandler = Locked<(@Sendable (any Error) -> Void)?>(nil)

    package init(logger: RubiconLogger?, fallback: @escaping RubiconLogger) {
        self.fallback = fallback
        self.logger = Locked(logger ?? fallback)
    }

    /// Called once, after the logger was reported as failed and replaced; its log lines go to the
    /// fallback.
    package var onLoggerFailed: (@Sendable (any Error) -> Void)? {
        get { loggerFailedHandler.current }
        set { loggerFailedHandler.withLock { $0 = newValue } }
    }

    /// Called once, after the observer was reported as failed and switched off.
    package var onObserverFailed: (@Sendable (any Error) -> Void)? {
        get { observerFailedHandler.current }
        set { observerFailedHandler.withLock { $0 = newValue } }
    }

    /// Whether the current thread is inside the logger or the observer.
    package static var isInCallback: Bool {
        Thread.current.threadDictionary[threadKey] as? Bool == true
    }

    package var isObserverEnabled: Bool { !observerFailed.isSet }

    package func log(_ level: LogLevel, _ message: String, _ error: (any Error)?) {
        let current = logger.current
        runCallback { current(level, message, error) }
    }

    /// Runs `update`, which calls the observer, unless the observer was switched off.
    package func notifyObserver(_ update: () -> Void) {
        if observerFailed.isSet { return }
        runCallback(update)
    }

    /// The developer's logger failed (an `NSException` caught by the wrapper): switch to the
    /// fallback once and say so once. A failing fallback has nowhere left to write.
    package func reportLoggerFailure(_ error: any Error) {
        if loggerReplaced.set() {
            logger.withLock { $0 = fallback }
            outsideCallback { onLoggerFailed?(error) }
        }
    }

    /// The observer failed: switch it off once and say so once.
    package func reportObserverFailure(_ error: any Error) {
        if observerFailed.set() {
            outsideCallback { onObserverFailed?(error) }
        }
    }

    // The failure report is the SDK's own line, not the callback's: it is written even when the
    // wrapper reports from inside the callback that failed.
    private func outsideCallback(_ body: () -> Void) {
        let dictionary = Thread.current.threadDictionary
        let wasInside = dictionary[Self.threadKey] as? Bool == true
        if wasInside { dictionary.removeObject(forKey: Self.threadKey) }
        defer { if wasInside { dictionary[Self.threadKey] = true } }
        body()
    }

    // Re-entrant calls on the same thread are skipped.
    private func runCallback(_ callback: () -> Void) {
        if Self.isInCallback { return }
        let dictionary = Thread.current.threadDictionary
        dictionary[Self.threadKey] = true
        defer { dictionary.removeObject(forKey: Self.threadKey) }
        callback()
    }
}
