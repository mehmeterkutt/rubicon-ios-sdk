/// How much the SDK logs, set with `logging.level` (default `.warn`). A level includes every level
/// after it: `.warn` also logs `.error`. The meaning of each level is a contract (Logging 2).
///
/// ```swift
/// var config = AnalyticsConfiguration(apiKey: key)
/// config.logging.level = .debug
/// ```
public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    /// Every step: an event queued, a flush started, a segment closed, a wait after a failure.
    case debug
    /// A few lifecycle lines, such as the host in use or a consent change.
    case info
    /// A misconfiguration, or data that was dropped or changed, such as a dropped property or a
    /// full queue. A healthy app logs nothing at this level.
    case warn
    /// Data is lost or the SDK cannot work, such as a failed write or an invalid API key.
    case error
    /// Nothing is logged.
    case off

    /// Orders the levels from `.debug` to `.off`, so `level >= .warn` reads as "warn or more severe".
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
