import Foundation

/// Formats a `Date` as `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` in UTC, the one date format of the wire
/// (Event Model 5, Serialization 4), by the calendar arithmetic of the Android `IsoDates`.
///
/// iOS Serialization 3 chose Foundation's `ISO8601DateFormatter` with the Android range rule and
/// named this port as the fallback "should a Foundation version ever diverge, which the copied
/// vectors would catch". They did, on the first run: Foundation switches to the Julian calendar
/// before 1582-10-15 and writes `0001-01-03` for `0000-01-01`, while the contract is proleptic
/// Gregorian over the years 0000 to 9999. The port is locale-free, thread-safe and forty lines.
package enum IsoDates {
    /// 0000-01-01T00:00:00.000Z
    package static let minMillis: Int64 = -62_167_219_200_000
    /// 9999-12-31T23:59:59.999Z
    package static let maxMillis: Int64 = 253_402_300_799_999

    private static let millisPerDay: Int64 = 86_400_000

    /// `nil` outside the years 0000 to 9999 (Serialization 4).
    package static func format(_ date: Date) -> String? {
        format(epochMillis: date.epochMillis)
    }

    /// `nil` outside the years 0000 to 9999 (Serialization 4).
    package static func format(epochMillis: Int64) -> String? {
        guard epochMillis >= minMillis && epochMillis <= maxMillis else { return nil }
        let days = floorDiv(epochMillis, millisPerDay)
        let millisOfDay = epochMillis - days * millisPerDay
        let (year, month, day) = civilFromDays(days)
        var out = ""
        out.reserveCapacity(24)
        pad(&out, year, 4)
        out.append("-")
        pad(&out, month, 2)
        out.append("-")
        pad(&out, day, 2)
        out.append("T")
        pad(&out, Int(millisOfDay / 3_600_000), 2)
        out.append(":")
        pad(&out, Int(millisOfDay / 60_000 % 60), 2)
        out.append(":")
        pad(&out, Int(millisOfDay / 1_000 % 60), 2)
        out.append(".")
        pad(&out, Int(millisOfDay % 1_000), 3)
        out.append("Z")
        return out
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date; `month` is 1 to 12 (Howard Hinnant's
    /// algorithm, with years starting in March so the leap day comes last).
    package static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        let y = Int64(month <= 2 ? year - 1 : year)
        let era = floorDiv(y, 400)
        let yearOfEra = y - era * 400
        let monthFromMarch = Int64((month + 9) % 12)
        let dayOfYear = (153 * monthFromMarch + 2) / 5 + Int64(day) - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The year, month (1 to 12) and day of `days` since 1970-01-01.
    package static func civilFromDays(_ days: Int64) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthFromMarch = (5 * dayOfYear + 2) / 153
        let day = Int(dayOfYear - (153 * monthFromMarch + 2) / 5 + 1)
        let month = Int(monthFromMarch < 10 ? monthFromMarch + 3 : monthFromMarch - 9)
        let year = Int(yearOfEra + era * 400) + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    private static func pad(_ out: inout String, _ value: Int, _ width: Int) {
        let text = String(value)
        if text.count < width { out.append(String(repeating: "0", count: width - text.count)) }
        out.append(text)
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}
