import Foundation

/// The `SDK Diagnostics` event (Logging 5): the SDK's health as counters, at most once an hour and
/// only when there is something to report. No text, values or stack traces.
///
/// ```
/// { "period_start": "2026-10-13T08:00:00.000Z",
///   "dropped": { "total": 1240, "queue_full": 1200, "expired": 37, "before_send": 3 },
///   "issues":  { "HOST_BLOCKED": 12 } }
/// ```
package enum Diagnostics {
    package static let eventName = "SDK Diagnostics"

    /// At most one event per hour (Logging 5).
    package static let intervalMs: Int64 = 60 * 60 * 1000

    /// Whether the event is due at `now`: something was counted and an hour has passed since the
    /// last one. A last time in the future, after the clock was set back, counts as now.
    package static func isDue(_ state: DiagnosticsState, now: Date) -> Bool {
        if state.isEmpty { return false }
        guard let last = state.lastSentAt else { return true }
        return now.epochMillis - min(last.epochMillis, now.epochMillis) >= intervalMs
    }

    /// The event's properties for `state`, counted since `DiagnosticsState.periodStart`.
    package static func properties(_ state: DiagnosticsState, now: Date) -> [String: PropertyValue] {
        var dropped: [String: PropertyValue] = ["total": .int(state.dropped.values.reduce(0) { $0 + Int64($1) })]
        for (reason, count) in state.dropped { dropped[reason] = .int(Int64(count)) }
        let periodStart = state.periodStart ?? now
        return [
            "period_start": .string(IsoDates.format(periodStart) ?? IsoDates.format(now) ?? ""),
            "dropped": .object(dropped),
            "issues": .object(state.issues.mapValues { .int(Int64($0)) }),
        ]
    }
}
