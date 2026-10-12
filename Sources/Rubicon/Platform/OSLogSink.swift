import Foundation
import RubiconCore
import os

/// The iOS default logger (Logging 1, iOS Logging 1): unified logging with the subsystem
/// `com.rubicon.analytics` and the category `Rubicon`, used when the developer sets no
/// `logging.logger`. The only code in the SDK that may call `os.Logger`.
///
/// The level was already checked by the SDK (Logging 3). The message is logged `privacy: .public`:
/// the content rule (no values, ids, keys, headers, bodies or query strings) is what makes that safe,
/// and Apple's default redaction would turn every warning into `<private>`. An error is named by its
/// domain and code only, never by its description, which for a `URLError` carries the URL.
final class OSLogSink: Sendable {
    static let subsystem = "com.rubicon.analytics"
    static let category = "Rubicon"
    static let shared = OSLogSink()

    private let write: @Sendable (OSLogType, String) -> Void

    /// The production sink.
    convenience init() {
        let logger = os.Logger(subsystem: Self.subsystem, category: Self.category)
        self.init { type, text in logger.log(level: type, "\(text, privacy: .public)") }
    }

    /// A sink with its output replaced, for the mapping tests.
    init(write: @escaping @Sendable (OSLogType, String) -> Void) {
        self.write = write
    }

    var rubiconLogger: RubiconLogger {
        { [self] level, message, error in log(level, message, error) }
    }

    func log(_ level: LogLevel, _ message: String, _ error: (any Error)?) {
        guard let type = Self.type(for: level) else { return }
        write(type, Self.text(message, error))
    }

    /// `error` to `.error`, `warn` to `.notice` (both persisted), `info` to `.info`, `debug` to
    /// `.debug`; `.fault` is never used, it means a system failure (iOS Logging 1).
    static func type(for level: LogLevel) -> OSLogType? {
        switch level {
        case .debug: return .debug
        case .info: return .info
        // `OSLogType.default` is the notice level of unified logging.
        case .warn: return .default
        case .error: return .error
        case .off: return nil
        }
    }

    static func text(_ message: String, _ error: (any Error)?) -> String {
        guard let error else { return message }
        let nsError = error as NSError
        return "\(message) [\(nsError.domain) \(nsError.code)]"
    }
}
