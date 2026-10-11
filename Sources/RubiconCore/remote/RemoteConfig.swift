import Foundation

/// The remote configuration after validation against the code's own values (Configuration 1): it
/// can only restrict. `nil` and empty mean "no remote value". The contract is `docs/remote-config.md`.
package struct RemoteConfig: Sendable, Equatable {
    package static let enabledKey = "enabled"
    package static let autocaptureOffKey = "autocapture_off"
    package static let flushAtKey = "flush_at"
    package static let flushIntervalMsKey = "flush_interval_ms"
    package static let sampleRateKey = "sample_rate"
    package static let diagnosticsSampleRateKey = "diagnostics_sample_rate"

    /// `false` is the kill switch; `true` changes nothing.
    package var enabled = true
    package var autocaptureOff: Set<Autocapture> = []
    package var flushAt: Int?
    package var flushIntervalMs: Int64?
    /// Share of devices that collect at all, by `device_id`.
    package var sampleRate: Double?
    /// Share of devices that send `SDK Diagnostics`, by `device_id` (Logging 5).
    package var diagnosticsSampleRate: Double?

    package static let none = RemoteConfig()

    package init() {}

    /// `code` restricted by these values; the snapshot the SDK runs with until the next launch.
    package func restrict(_ code: ConfigSnapshot) -> ConfigSnapshot {
        with(code) { snapshot in
            snapshot.autocapture = code.autocapture.subtracting(autocaptureOff)
            snapshot.flushAt = flushAt ?? code.flushAt
            snapshot.flushIntervalMs = flushIntervalMs ?? code.flushIntervalMs
        }
    }

    /// The response body as values, or `nil` when it is not one JSON object.
    package static func parseBody(_ body: String) -> [String: PropertyValue]? {
        Json.readObject(body)?.toPropertyValues()
    }

    /// Validates `values`, a stored or fetched response, against `code`. A known key with an
    /// invalid value, or one that would widen what code allows, is ignored with a WARN; an unknown
    /// key or autocapture type, perhaps for a newer SDK, is ignored at DEBUG.
    package static func from(_ values: [String: PropertyValue], code: ConfigSnapshot, log: Log) -> RemoteConfig {
        var config = RemoteConfig.none
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            var valid = true
            switch key {
            case enabledKey:
                if case .bool(let flag) = value { config.enabled = flag } else { valid = false }
            case autocaptureOffKey:
                if let off = autocaptureOff(value, log: log) { config.autocaptureOff = off } else { valid = false }
            case flushAtKey:
                if case .int(let n) = value, ConfigValidator.flushAtBounds.contains(n), n >= Int64(code.flushAt) {
                    config.flushAt = Int(n)
                } else {
                    valid = false
                }
            case flushIntervalMsKey:
                if case .int(let n) = value, ConfigValidator.flushIntervalMsBounds.contains(n),
                    n >= code.flushIntervalMs
                {
                    config.flushIntervalMs = n
                } else {
                    valid = false
                }
            case sampleRateKey:
                if let rate = rate(value) { config.sampleRate = rate } else { valid = false }
            case diagnosticsSampleRateKey:
                // With sendDiagnostics off in code, any rate above 0 would widen it.
                if let rate = rate(value), code.sendDiagnostics || rate == 0 {
                    config.diagnosticsSampleRate = rate
                } else {
                    valid = false
                }
            default:
                log.debug { "Remote configuration: ignored the unknown key \"\(key)\"" }
            }
            if !valid {
                log.warn(.remoteConfigInvalidValue, repeatKey: key) {
                    "Remote configuration: \"\(key)\" is invalid or would widen what the app's code allows; it is ignored"
                }
            }
        }
        return config
    }

    private static func autocaptureOff(_ value: PropertyValue, log: Log) -> Set<Autocapture>? {
        guard case .array(let names) = value else { return nil }
        var off: Set<Autocapture> = []
        for name in names {
            guard case .string(let text) = name else { return nil }
            if let type = Autocapture(rawValue: text) {
                off.insert(type)
            } else {
                log.debug { "Remote configuration: ignored the unknown autocapture type \"\(text)\"" }
            }
        }
        return off
    }

    private static func rate(_ value: PropertyValue) -> Double? {
        let rate: Double
        switch value {
        case .int(let n): rate = Double(n)
        case .double(let d): rate = d
        default: return nil
        }
        return (0.0...1.0).contains(rate) ? rate : nil
    }
}
