import Foundation

/// Counts every WARN and ERROR by code for `SDK Diagnostics` (Logging 5); stored from step 4.1.
package typealias IssueCounter = @Sendable (Code) -> Void

/// The core's default logger: logs nothing, so macOS tests never touch unified logging (iOS
/// Logging 1). The `Rubicon` target installs the `os.Logger` sink instead.
package let noOpLogger: RubiconLogger = { _, _, _ in }

/// The only way SDK code logs (Logging 1 to 4). One per `Analytics` instance.
///
/// - The level is checked before the message closure runs, so a disabled line costs one
///   comparison (Logging 3).
/// - Every WARN and ERROR has a `Code`. Each occurrence increments the code's counter, whatever
///   the level; only the first occurrence in the process is logged at its own level, later ones at
///   DEBUG (Logging 2). A `repeatKey` narrows that to the first occurrence per key, for the lines a
///   decision logs "once per key" (Serialization 3).
/// - Lines go to the developer's logger, or to the platform logger when there is none, through a
///   `CallbackGuard` (Logging 4b).
///
/// Messages name keys, types, counts and codes, never values or ids (Logging 4a):
///
/// ```swift
/// log.warn(.propertyDropped) { "Dropped property \"\(key)\": unsupported type \(typeName)" }
/// ```
package final class Log: Sendable {
    package let level: LogLevel
    package let callbacks: CallbackGuard
    private let issues: IssueCounter
    private let developerErrorHandler: @Sendable (String) -> Void
    private let reported = Locked<Set<Code>>([])
    private let reportedKeys = Locked<Set<String>>([])

    /// Creates the instance's log; `platformLogger` is the `os.Logger` sink on iOS and nothing in
    /// the core, and also the fallback for a logger that failed. `developerError` is what a
    /// developer mistake does when `configuration.debug` is on: `assertionFailure` in production,
    /// a recording closure in tests (iOS Configuration 2).
    package init(
        level: LogLevel, logger: RubiconLogger?, platformLogger: @escaping RubiconLogger,
        issues: @escaping IssueCounter = { _ in },
        developerError: @escaping @Sendable (String) -> Void = { assertionFailure($0) }
    ) {
        self.level = level
        self.issues = issues
        developerErrorHandler = developerError
        callbacks = CallbackGuard(logger: logger, fallback: platformLogger)
        callbacks.onLoggerFailed = { [weak self] error in
            self?.warn(.loggerThrew, error) { "Custom logger threw; falling back to the default logger" }
        }
        callbacks.onObserverFailed = { [weak self] error in
            self?.error(.observerThrew, error) { "Event observer threw; it is switched off" }
        }
    }

    /// Reports a developer mistake loudly: traps in a debug build through `assertionFailure`. In a
    /// release build the call returns, so the caller logs the problem afterwards as it would with
    /// `debug` off; nothing is ever silent (iOS Configuration 2).
    package func developerError(_ message: String) {
        developerErrorHandler(message)
    }

    package func isEnabled(_ level: LogLevel) -> Bool {
        level != .off && level >= self.level
    }

    package func debug(_ message: () -> String) {
        if isEnabled(.debug) { write(.debug, message(), nil) }
    }

    package func info(_ message: () -> String) {
        if isEnabled(.info) { write(.info, message(), nil) }
    }

    package func warn(_ code: Code, _ error: (any Error)? = nil, repeatKey: String? = nil, _ message: () -> String) {
        if let effective = report(code, .warn, repeatKey: repeatKey) {
            write(effective, "\(code.rawValue): \(message())", error)
        }
    }

    package func error(_ code: Code, _ error: (any Error)? = nil, repeatKey: String? = nil, _ message: () -> String) {
        if let effective = report(code, .error, repeatKey: repeatKey) {
            write(effective, "\(code.rawValue): \(message())", error)
        }
    }

    /// Counts `code` and returns the level to log it at: `level` the first time in this process
    /// (per `repeatKey`, when given), `.debug` afterwards; `nil` when that level is disabled.
    package func report(_ code: Code, _ level: LogLevel, repeatKey: String? = nil) -> LogLevel? {
        issues(code)
        let first: Bool
        if let repeatKey {
            first = reportedKeys.withLock { $0.insert("\(code.rawValue):\(repeatKey)").inserted }
        } else {
            first = reported.withLock { $0.insert(code).inserted }
        }
        let effective: LogLevel = first ? level : .debug
        return isEnabled(effective) ? effective : nil
    }

    package func write(_ level: LogLevel, _ message: String, _ error: (any Error)?) {
        callbacks.log(level, message, error)
    }
}
