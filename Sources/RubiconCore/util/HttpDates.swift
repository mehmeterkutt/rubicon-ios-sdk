import Foundation

/// Parses the HTTP date form of `Retry-After` (Retry 3, HTTP 4): the IMF-fixdate of RFC 9110,
/// section 5.6.7, such as `Sun, 06 Nov 1994 08:49:37 GMT`.
///
/// The two obsolete forms that RFC 9110 asks recipients to accept (RFC 850 and asctime) are not
/// parsed: they give `nil`, and the header then counts as absent (Android log 2.3). The day name is
/// not checked against the date, since RFC 9110 makes it redundant.
package enum HttpDates {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    // The pattern is a constant; a failure to compile it would be a programming error caught by the tests.
    private static let imfFixdate = try? NSRegularExpression(
        pattern:
            #"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), (\d{2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$"#
    )

    /// Epoch milliseconds, or `nil` when `value` is not an IMF-fixdate or not a real date.
    package static func parse(_ value: String) -> Int64? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard let regex = imfFixdate,
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        func group(_ index: Int) -> String {
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
        guard let day = Int(group(2)), let year = Int(group(4)), let hour = Int(group(5)),
            let minute = Int(group(6)), let second = Int(group(7)),
            let monthIndex = months.firstIndex(of: group(3))
        else { return nil }
        let month = monthIndex + 1
        // 60 is a leap second (RFC 9110 allows it); it counts as the first second of the next minute.
        guard day >= 1, day <= daysInMonth(year: year, month: month), hour <= 23, minute <= 59, second <= 60
        else { return nil }
        let days = IsoDates.daysFromCivil(year: year, month: month, day: day)
        return ((days * 24 + Int64(hour)) * 60 + Int64(minute)) * 60_000 + Int64(second) * 1_000
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}
