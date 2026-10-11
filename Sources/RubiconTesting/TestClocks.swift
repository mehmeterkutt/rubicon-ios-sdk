import Foundation
import RubiconCore

/// A wall clock that only moves when the test moves it, forwards or backwards.
package final class TestClock: Clock, @unchecked Sendable {
    /// 2025-09-29T12:00:00.000Z, the instant of the Android `FakeClock`.
    package static let defaultStart = Date(epochMillis: 1_759_147_200_000)

    // Guarded by `state`.
    private let state: Locked<Date>

    package init(start: Date = TestClock.defaultStart) {
        state = Locked(start)
    }

    package func now() -> Date {
        state.current
    }

    package func set(_ date: Date) {
        state.withLock { $0 = date }
    }

    /// A negative value moves the clock back, as a user changing the device time does.
    package func advance(byMillis millis: Int64) {
        state.withLock { $0 = Date(epochMillis: $0.epochMillis + millis) }
    }
}

/// A monotonic clock that only moves forwards, when the test moves it.
package final class TestElapsedClock: ElapsedClock, @unchecked Sendable {
    /// An arbitrary uptime; a real device's is rarely zero.
    package static let defaultStart: Int64 = 1_000_000

    // Guarded by `state`.
    private let state: Locked<Int64>

    package init(start: Int64 = TestElapsedClock.defaultStart) {
        state = Locked(start)
    }

    package func elapsedMillis() -> Int64 {
        state.current
    }

    /// Traps on a negative value: an elapsed clock never moves back.
    package func advance(byMillis millis: Int64) {
        precondition(millis >= 0, "An elapsed clock never moves back")
        state.withLock { $0 += millis }
    }
}

/// A `RandomSource` that produces the same sequence for the same seed (SplitMix64).
package final class SeededRandom: RandomSource, @unchecked Sendable {
    package let seed: UInt64
    // Guarded by `state`.
    private let state: Locked<UInt64>

    package init(seed: UInt64 = 42) {
        self.seed = seed
        state = Locked(seed)
    }

    package func nextUInt64() -> UInt64 {
        state.withLock { s in
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

/// A `RandomSource` that returns scripted values in order, for the id generator's vectors; once the
/// script is used up it returns zero.
package final class ScriptedRandom: RandomSource, @unchecked Sendable {
    // Guarded by `state`.
    private let state: Locked<[UInt64]>

    package init(_ values: [UInt64]) {
        state = Locked(values)
    }

    package func nextUInt64() -> UInt64 {
        state.withLock { $0.isEmpty ? 0 : $0.removeFirst() }
    }
}
