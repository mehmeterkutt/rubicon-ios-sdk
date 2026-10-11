import Foundation

/// Wall-clock time. Event timestamps and persisted times (Event Model 5) come from here, never from
/// `Date()` directly, so tests control them (iOS Event Model 2: `Date` in memory).
package protocol Clock: Sendable {
    func now() -> Date
}

/// Monotonic milliseconds, unaffected by changes to the wall clock. Measures waits and time in the
/// background within one process (Session 4, Retry 2). The production value is
/// `ProcessInfo.systemUptime`, implemented in the `Rubicon` target under reason `35F9.1` (iOS
/// Session 2); the core never reads it.
package protocol ElapsedClock: Sendable {
    func elapsedMillis() -> Int64
}

/// Random bits for the id generator (iOS Event Model 3). Tests inject a seeded source.
package protocol RandomSource: Sendable {
    func nextUInt64() -> UInt64
}

extension Date {
    /// Epoch milliseconds, rounded, the wire form of top-level times (iOS Event Model 2).
    package var epochMillis: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    /// The inverse of `epochMillis`.
    package init(epochMillis: Int64) {
        self.init(timeIntervalSince1970: Double(epochMillis) / 1000)
    }
}

extension RandomSource {
    /// A uniform value in `[lower, upper)` from the next 53 random bits.
    package func nextDouble(in range: Range<Double>) -> Double {
        let unit = Double(nextUInt64() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
