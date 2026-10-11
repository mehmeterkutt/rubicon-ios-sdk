/// Receives the SDK's log lines, set with `logging.logger`. When no logger is set, iOS writes to
/// unified logging with subsystem `com.rubicon.analytics`; a logger you set is never replaced
/// (iOS Logging 1).
///
/// Only lines that pass `logging.level` reach the logger, so it needs no level logic. It is called
/// from the SDK's queues and sometimes from the thread that called the SDK: keep it fast and
/// thread-safe, and do not call the SDK from it (such calls log nothing). A trap inside it stops
/// the app, as in any Swift closure.
///
/// Messages never contain property or trait values, user or device ids, the API key, headers,
/// bodies or query strings.
///
/// ```swift
/// config.logging.logger = { level, message, error in
///     if level == .error { crashReporter.log("Rubicon: \(message)") }
/// }
/// ```
public typealias RubiconLogger = @Sendable (_ level: LogLevel, _ message: String, _ error: (any Error)?) -> Void
