import Foundation
import RubiconCore

/// The monotonic clock (Session 4, Retry 2; iOS Session 2, iOS Retry 2): `ProcessInfo.systemUptime`,
/// which keeps counting while the device sleeps. It is a required-reason API in the system boot time
/// category, declared in `PrivacyInfo.xcprivacy` with reason `35F9.1`: elapsed time between events
/// within the app. The uptime itself never leaves the device; the one derived value that does is
/// `duration_ms`, which the reason's exception allows. This is the only place in the SDK that reads it.
struct UptimeClock: ElapsedClock {
    func elapsedMillis() -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }
}
