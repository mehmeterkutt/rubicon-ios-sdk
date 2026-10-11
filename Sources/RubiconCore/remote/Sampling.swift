import Foundation

/// Deterministic sampling by `device_id` (Configuration 1, Logging 5): a device is always in or
/// always out for a rate, so it does not flicker between launches. Each purpose has its own salt,
/// so a device out of one sample is not more likely to be out of another. A new `device_id`, after
/// `clearLocalData()`, draws again.
package enum Sampling {
    package enum Purpose: String, Sendable {
        /// `sample_rate`: whether the device collects at all.
        case events
        /// `diagnostics_sample_rate`: whether the device sends `SDK Diagnostics`.
        case diagnostics
    }

    /// Whether `deviceId` is inside a sample of `rate`, 0 to 1.
    package static func isIn(_ deviceId: String, rate: Double, purpose: Purpose) -> Bool {
        if rate >= 1.0 { return true }
        if rate <= 0.0 { return false }
        return bucket(deviceId, purpose: purpose) < rate
    }

    /// A uniform position in `[0, 1)` from the first 52 bits of SHA-256 of the salted id.
    package static func bucket(_ deviceId: String, purpose: Purpose) -> Double {
        let hex = Hashing.sha256Hex("\(purpose.rawValue):\(deviceId)").prefix(13)
        let bits = UInt64(hex, radix: 16) ?? 0
        return Double(bits) / Double(UInt64(1) << 52)
    }
}
