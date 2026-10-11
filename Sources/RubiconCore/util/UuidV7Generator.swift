import Foundation

/// Makes UUIDv7 strings that sort in creation order within the process (Event Model 4, iOS Event
/// Model 3), for `message_id`, `device_id` and the session id. One generator per `Analytics`
/// instance; a port of the Android `UuidV7Generator` with the same layout and rules (Android log 2.3).
///
/// Layout (RFC 9562, section 5.7): 48 bits of Unix time in milliseconds, the version `7`, then 74
/// bits that hold a 42-bit counter (the 12 bits of `rand_a` and the top 30 bits of `rand_b`, RFC
/// 9562 section 6.2, method 1) followed by 32 random bits, with the variant `10` in between.
///
/// - The counter starts at a random value with its top bit clear in each new millisecond and grows
///   by one per id, so ids of the same millisecond are ordered and about 2^41 of them fit.
/// - If the clock moves back, the last timestamp is kept and the counter keeps growing, so order holds.
/// - If the counter runs out, the timestamp moves one millisecond ahead (RFC 9562, section 6.2).
///
/// Thread-safe; `next()` takes a lock for a few arithmetic operations and random draws. The text is
/// 36 lowercase characters from the generator's own hexadecimal table; Foundation's `UUID` is never
/// involved, since it writes uppercase.
package final class UuidV7Generator: Sendable {
    private struct State {
        var lastMillis = Int64.min
        var counter: UInt64 = 0
    }

    private static let timestampMask: UInt64 = 0xFFFF_FFFF_FFFF
    private static let counterMax: UInt64 = (1 << 42) - 1
    private static let hex = Array("0123456789abcdef".utf8)

    private let clock: any Clock
    private let random: any RandomSource
    private let counterMax: UInt64
    // A fresh counter uses the lower half of the range, leaving at least half for increments.
    private let seedMask: UInt64
    private let state = Locked(State())

    package convenience init(clock: any Clock, random: any RandomSource) {
        self.init(clock: clock, random: random, counterMax: Self.counterMax)
    }

    /// Tests lower `counterMax` to reach the overflow path; ids then keep the 42-bit layout.
    package init(clock: any Clock, random: any RandomSource, counterMax: UInt64) {
        self.clock = clock
        self.random = random
        self.counterMax = counterMax
        seedMask = counterMax >> 1
    }

    package func next() -> String {
        let (millis, count, tail): (Int64, UInt64, UInt64) = state.withLock { s in
            // The random source is shared, so every draw happens under the lock.
            let now = clock.now().epochMillis
            if now > s.lastMillis {
                s.lastMillis = now
                s.counter = random.nextUInt64() & seedMask
            } else if s.counter == counterMax {
                s.lastMillis += 1
                s.counter = random.nextUInt64() & seedMask
            } else {
                s.counter += 1
            }
            return (s.lastMillis, s.counter, random.nextUInt64() & 0xFFFF_FFFF)
        }
        // unix_ts_ms (48) | ver (4) | counter high 12 bits
        let msb = ((UInt64(bitPattern: millis) & Self.timestampMask) << 16) | (0x7 << 12) | (count >> 30)
        // var (2) | counter low 30 bits | 32 random bits
        let lsb = (0b10 << 62) | ((count & 0x3FFF_FFFF) << 32) | tail
        return Self.format(msb, lsb)
    }

    private static func format(_ msb: UInt64, _ lsb: UInt64) -> String {
        var out = [UInt8](repeating: 0, count: 36)
        var pos = 0
        for i in 0..<32 {
            if i == 8 || i == 12 || i == 16 || i == 20 {
                out[pos] = UInt8(ascii: "-")
                pos += 1
            }
            let word = i < 16 ? msb : lsb
            let shift = UInt64((15 - i % 16) * 4)
            out[pos] = hex[Int((word >> shift) & 0xF)]
            pos += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}
