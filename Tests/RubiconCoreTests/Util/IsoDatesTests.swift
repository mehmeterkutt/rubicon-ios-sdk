import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("IsoDates")
struct IsoDatesTests {
    // The Android IsoDatesTest table, verbatim.
    static let vectors: [(Int64, String)] = [
        (0, "1970-01-01T00:00:00.000Z"),
        (999, "1970-01-01T00:00:00.999Z"),
        (-1, "1969-12-31T23:59:59.999Z"),
        (-2_208_988_800_000, "1900-01-01T00:00:00.000Z"),
        (946_684_799_999, "1999-12-31T23:59:59.999Z"),
        (946_684_800_000, "2000-01-01T00:00:00.000Z"),
        (951_782_400_000, "2000-02-29T00:00:00.000Z"),
        (1_709_210_096_789, "2024-02-29T12:34:56.789Z"),
        (4_107_542_400_000, "2100-03-01T00:00:00.000Z"),
        (1_759_147_200_123, "2025-09-29T12:00:00.123Z"),
        (-62_167_219_200_000, "0000-01-01T00:00:00.000Z"),
        (253_402_300_799_999, "9999-12-31T23:59:59.999Z"),
    ]

    // An independent rendering through Calendar, for the random instants.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    static func reference(_ millis: Int64) -> String {
        let c = utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: Date(epochMillis: millis))
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        let ms = Int(((Double(c.nanosecond ?? 0) / 1_000_000)).rounded())
        return
            "\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2))T\(pad(c.hour, 2)):\(pad(c.minute, 2)):\(pad(c.second, 2)).\(pad(ms, 3))Z"
    }

    @Test("formats the Android vectors", arguments: vectors)
    func knownInstants(millis: Int64, expected: String) {
        #expect(IsoDates.format(epochMillis: millis) == expected)
        #expect(IsoDates.format(Date(epochMillis: millis)) == expected)
    }

    @Test("instants outside the years 0000 to 9999 are unsupported")
    func outOfRange() {
        #expect(IsoDates.format(epochMillis: IsoDates.minMillis - 1) == nil)
        #expect(IsoDates.format(epochMillis: IsoDates.maxMillis + 1) == nil)
        #expect(IsoDates.format(epochMillis: Int64.min) == nil)
        #expect(IsoDates.format(epochMillis: Int64.max) == nil)
        #expect(IsoDates.format(Date(epochMillis: IsoDates.maxMillis + 1)) == nil)
    }

    // Foundation's Gregorian calendar is Julian before 1582-10-15, so the independent reference is
    // only valid from 1583 on; the day arithmetic below covers the earlier years.
    static let gregorianStart: Int64 = IsoDates.daysFromCivil(year: 1583, month: 1, day: 1) * 86_400_000

    @Test("agrees with Calendar on 100 000 seeded random instants from 1583 on")
    func randomInstants() {
        let random = SeededRandom(seed: 2024)
        let span = UInt64(IsoDates.maxMillis - Self.gregorianStart) + 1
        var mismatches: [Int64] = []
        for _ in 0..<100_000 {
            let millis = Self.gregorianStart + Int64(random.nextUInt64() % span)
            if IsoDates.format(epochMillis: millis) != Self.reference(millis) { mismatches.append(millis) }
        }
        #expect(mismatches.isEmpty, "first mismatches: \(mismatches.prefix(5))")
    }

    @Test("day arithmetic round-trips over the whole supported range")
    func dayRoundTrip() {
        let first = IsoDates.minMillis / 86_400_000
        let last = IsoDates.maxMillis / 86_400_000
        var failures = 0
        for day in first...last {
            let (year, month, dayOfMonth) = IsoDates.civilFromDays(day)
            if IsoDates.daysFromCivil(year: year, month: month, day: dayOfMonth) != day { failures += 1 }
        }
        #expect(failures == 0)
        let epoch = IsoDates.civilFromDays(0)
        #expect(epoch.year == 1970 && epoch.month == 1 && epoch.day == 1)
    }

    @Test("day arithmetic matches known days")
    func daysFromCivil() {
        #expect(IsoDates.daysFromCivil(year: 1970, month: 1, day: 1) == 0)
        #expect(IsoDates.daysFromCivil(year: 2000, month: 3, day: 1) == 11_017)
        #expect(IsoDates.daysFromCivil(year: 1969, month: 12, day: 31) == -1)
        #expect(IsoDates.daysFromCivil(year: 0, month: 1, day: 1) * 86_400_000 == IsoDates.minMillis)
        #expect(IsoDates.daysFromCivil(year: 9999, month: 12, day: 31) * 86_400_000 + 86_399_999 == IsoDates.maxMillis)
    }
}
