import Foundation
import RubiconCore

/// A logger that keeps every line it receives, for assertions.
package final class RecordingLogger: @unchecked Sendable {
    package struct Line: Sendable, CustomStringConvertible {
        package var level: LogLevel
        package var message: String
        package var error: (any Error)?

        package var description: String { "\(level) \(message)" }
    }

    // Guarded by `recorded`.
    private let recorded = Locked<[Line]>([])

    package init() {}

    /// The lines received so far, oldest first.
    package var lines: [Line] { recorded.current }

    /// The messages received so far, oldest first.
    package var messages: [String] { lines.map(\.message) }

    /// The closure to hand to the SDK.
    package var asLogger: RubiconLogger {
        { [recorded] level, message, error in
            recorded.withLock { $0.append(Line(level: level, message: message, error: error)) }
        }
    }

    package func clear() {
        recorded.withLock { $0 = [] }
    }
}
