import Foundation

/// What belongs to the device and survives `reset()` (Identity 5). `clearLocalData()` renews
/// `deviceId` and clears `retry` and `diagnostics`, keeping the rest (Privacy 3).
package struct DeviceState: Sendable, Equatable {
    package var deviceId: String
    /// The user's stored choice; `nil` while there is none (Privacy 2).
    package var consent: StoredConsent?
    /// The app version and build last seen, for install and update events (Lifecycle 4).
    package var lastVersion: String?
    package var lastBuild: String?
    package var retry: RetryState
    package var diagnostics: DiagnosticsState

    package init(
        deviceId: String, consent: StoredConsent? = nil, lastVersion: String? = nil, lastBuild: String? = nil,
        retry: RetryState = .none, diagnostics: DiagnosticsState = .empty
    ) {
        self.deviceId = deviceId
        self.consent = consent
        self.lastVersion = lastVersion
        self.lastBuild = lastBuild
        self.retry = retry
        self.diagnostics = diagnostics
    }

    package static func initial(deviceId: String) -> DeviceState { DeviceState(deviceId: deviceId) }
}

/// The stored consent choice: `granted` or `denied` (Privacy 2).
package enum StoredConsent: String, Sendable, CaseIterable {
    case granted
    case denied
}

/// The upload pipeline's wait, restored at startup (Retry 5).
package struct RetryState: Sendable, Equatable {
    /// Wall-clock instant before which no upload starts.
    package var pausedUntil: Date?
    package var pauseKind: PauseKind?
    /// Position in the backoff table (Retry 2).
    package var step: Int
    /// The kind of the last failure, such as `timeout` or the iOS-only `cancelled` (iOS Retry 2).
    package var lastFailure: String?
    /// Failed attempts per segment name, for the poison batch rule (Retry 3).
    package var batches: [String: Int]

    package init(
        pausedUntil: Date? = nil, pauseKind: PauseKind? = nil, step: Int = 0, lastFailure: String? = nil,
        batches: [String: Int] = [:]
    ) {
        self.pausedUntil = pausedUntil
        self.pauseKind = pauseKind
        self.step = step
        self.lastFailure = lastFailure
        self.batches = batches
    }

    package static let none = RetryState()
}

/// Groups B, C and E of Retry 1: whether the network may end the wait and how long it may be.
package enum PauseKind: String, Sendable, CaseIterable {
    case transient
    case throttle
    case config
}

/// The counters of `SDK Diagnostics`, kept across restarts (Logging 5).
package struct DiagnosticsState: Sendable, Equatable {
    /// When counting began; `nil` while nothing is counted.
    package var periodStart: Date?
    /// When the last `SDK Diagnostics` event was written.
    package var lastSentAt: Date?
    /// Drop counts by reason wire name, such as `queue_full`.
    package var dropped: [String: Int]
    /// Counts by issue code, such as `HOST_BLOCKED`.
    package var issues: [String: Int]

    package init(
        periodStart: Date? = nil, lastSentAt: Date? = nil, dropped: [String: Int] = [:], issues: [String: Int] = [:]
    ) {
        self.periodStart = periodStart
        self.lastSentAt = lastSentAt
        self.dropped = dropped
        self.issues = issues
    }

    package static let empty = DiagnosticsState()

    /// Whether nothing is counted.
    package var isEmpty: Bool { dropped.isEmpty && issues.isEmpty }

    /// These counters without `reported`'s, keeping only what is left above zero.
    package func subtracting(_ reported: DiagnosticsState) -> DiagnosticsState {
        func less(_ a: [String: Int], _ b: [String: Int]) -> [String: Int] {
            a.mapValues { $0 }.reduce(into: [:]) { out, entry in
                let left = entry.value - (b[entry.key] ?? 0)
                if left > 0 { out[entry.key] = left }
            }
        }
        var copy = self
        copy.dropped = less(dropped, reported.dropped)
        copy.issues = less(issues, reported.issues)
        return copy
    }
}

/// Counts to add to a `DiagnosticsState`.
package struct DiagnosticsCount: Sendable, Equatable {
    package var dropped: [String: Int]
    package var issues: [String: Int]

    package init(dropped: [String: Int] = [:], issues: [String: Int] = [:]) {
        self.dropped = dropped
        self.issues = issues
    }

    package var isEmpty: Bool { dropped.isEmpty && issues.isEmpty }

    package static func + (lhs: DiagnosticsCount, rhs: DiagnosticsCount) -> DiagnosticsCount {
        DiagnosticsCount(dropped: sum(lhs.dropped, rhs.dropped), issues: sum(lhs.issues, rhs.issues))
    }

    /// `state` with these counts added; counting begins at `now` if it had not begun.
    package func adding(to state: DiagnosticsState, now: Date) -> DiagnosticsState {
        var copy = state
        copy.periodStart = state.periodStart ?? now
        copy.dropped = Self.sum(state.dropped, dropped)
        copy.issues = Self.sum(state.issues, issues)
        return copy
    }

    // Saturates instead of wrapping around on a device that counts for years.
    private static func sum(_ a: [String: Int], _ b: [String: Int]) -> [String: Int] {
        if b.isEmpty { return a }
        var result = a
        for (key, n) in b {
            result[key] = Int(clamping: Int64(result[key] ?? 0) + Int64(n)).clamped(to: Int32.max)
        }
        return result
    }
}

extension Int {
    fileprivate func clamped(to max: Int32) -> Int { Swift.min(self, Int(max)) }
}

/// The last valid remote configuration and its ETag (Configuration 1); its values are read in 5.3.
package struct RemoteConfigCache: Sendable, Equatable {
    package var etag: String?
    package var values: [String: PropertyValue]

    package init(etag: String?, values: [String: PropertyValue]) {
        self.etag = etag
        self.values = values
    }
}

/// `device.json` and `remote-config.json` (Disk 7).
///
/// - `device.json` missing: a new `deviceId` from `newDeviceId`, written at once. Unreadable: a
///   temporary id in memory for this process, the file left untouched (Identity 1). Locked: not
///   loaded; `load` runs again once protected data is available (iOS Disk 1).
/// - `remote-config.json` missing or unreadable: no cache; an unreadable one is never overwritten.
///
/// The drop and issue counters of `SDK Diagnostics` live here (Logging 5). Counts that arrive before
/// `load`, such as the warning about an unreadable `device.json` itself, are kept and added once it
/// is loaded. `DeviceStoreTests` pins the exact keys of both files.
package final class DeviceStore: @unchecked Sendable {
    package static let fileName = "device.json"
    package static let remoteConfigFileName = "remote-config.json"

    private let device: StoreFile<DeviceCodec>
    private let remote: StoreFile<RemoteConfigCodec>
    private let clock: any Clock
    private let newDeviceId: @Sendable () -> String
    // Counts made before load; guarded by `early`.
    private let early = Locked(DiagnosticsCount())
    private let loadLock = NSLock()

    package init(
        keyValueStore: any KeyValueStore, log: Log, clock: any Clock, newDeviceId: @escaping @Sendable () -> String
    ) {
        device = StoreFile(name: Self.fileName, keyValueStore: keyValueStore, log: log, codec: DeviceCodec())
        remote = StoreFile(
            name: Self.remoteConfigFileName, keyValueStore: keyValueStore, log: log, codec: RemoteConfigCodec())
        self.clock = clock
        self.newDeviceId = newDeviceId
    }

    /// Counts every WARN and ERROR by code; the `Log` of the instance is built with it.
    package var issueCounter: IssueCounter {
        { [weak self] code in self?.count(DiagnosticsCount(issues: [code.rawValue: 1])) }
    }

    /// Reads both files and writes a new `device.json` if it was missing; the writer's first task
    /// (Privacy 2). When `readEarly` already read them, only that write is left. Returns `false`
    /// while the device is locked; call again after `protectedDataDidBecomeAvailable`.
    @discardableResult
    package func load() -> Bool {
        guard read(writeMissing: true) else { return false }
        persist()
        return true
    }

    /// Reads the files on the calling thread if the writer has not yet, for the two getters that
    /// must answer at once, `deviceId` and `isOptedOut` (Public API 9). Never writes: a new id is
    /// written by the writer's `load`. The files are read once, whoever comes first.
    package func readEarly() {
        if !device.isLoaded { _ = read(writeMissing: false) }
    }

    private func read(writeMissing: Bool) -> Bool {
        loadLock.lock()
        defer { loadLock.unlock() }
        if !device.isLoaded {
            let loaded = device.load(
                onMissing: { DeviceState.initial(deviceId: newDeviceId()) },
                onUnreadable: { DeviceState.initial(deviceId: newDeviceId()) }, writeMissing: writeMissing)
            guard loaded else { return false }
            remote.load(onMissing: { nil }, onUnreadable: { nil })
        }
        let pending: DiagnosticsCount = early.withLock { e in
            defer { e = DiagnosticsCount() }
            return e
        }
        if !pending.isEmpty {
            let now = clock.now()
            device.update {
                $0.map { state in with(state) { $0.diagnostics = pending.adding(to: state.diagnostics, now: now) } }
            }
        }
        return true
    }

    /// `SDK Diagnostics` with `reported` was written at `at` (Logging 5): its counts are taken off
    /// and `at` becomes the last time. Counts that arrived meanwhile stay, and start the next period.
    package func diagnosticsReported(_ reported: DiagnosticsState, at: Date) {
        device.update {
            $0.map { state in
                var left = state.diagnostics.subtracting(reported)
                left.periodStart = left.isEmpty ? nil : at
                left.lastSentAt = at
                return with(state) { $0.diagnostics = left }
            }
        }
    }

    /// Counts `count` events dropped for `reason` (Queue 5, Logging 5).
    package func countDropped(_ reason: DropReason, count: Int = 1) {
        if count > 0 { self.count(DiagnosticsCount(dropped: [reason.rawValue: count])) }
    }

    private func count(_ delta: DiagnosticsCount) {
        if device.isLoaded {
            let now = clock.now()
            device.update {
                $0.map { state in with(state) { $0.diagnostics = delta.adding(to: state.diagnostics, now: now) } }
            }
        } else {
            early.withLock { $0 = $0 + delta }
        }
    }

    package var isLoaded: Bool { device.isLoaded }

    /// `true` after a read or write met the locked device (iOS Disk 1).
    package var isLocked: Bool { device.isLocked || remote.isLocked }

    /// The state; `nil` until loaded (a locked device before the first unlock).
    package var state: DeviceState? { device.value }

    /// `false` when `device.json` exists but could not be read; its id is temporary.
    package var isDeviceFileWritable: Bool { device.isWritable }

    package func update(_ transform: (DeviceState) -> DeviceState) {
        device.update { $0.map(transform) }
    }

    package var remoteConfig: RemoteConfigCache? { remote.value }

    /// Replaces the cache; `nil` deletes it.
    package func updateRemoteConfig(_ cache: RemoteConfigCache?) {
        remote.update { _ in cache }
    }

    /// Writes whatever changed; on the writer only. Returns `false` when a write failed.
    @discardableResult
    package func persist() -> Bool {
        let a = device.persist()
        let b = remote.persist()
        return a && b
    }

    package static let deviceId = "device_id"
    package static let consent = "consent"
    package static let lastVersion = "last_version"
    package static let lastBuild = "last_build"
    package static let retry = "retry"
    package static let pausedUntil = "paused_until"
    package static let pauseKind = "pause_kind"
    package static let step = "step"
    package static let lastFailure = "last_failure"
    package static let batches = "batches"
    package static let diagnostics = "diagnostics"
    package static let periodStart = "period_start"
    package static let lastSentAt = "last_sent_at"
    package static let dropped = "dropped"
    package static let issues = "issues"
    package static let etag = "etag"
    package static let values = "values"

    struct DeviceCodec: StoreCodec {
        func encode(_ value: DeviceState) -> [String: PropertyValue] {
            [
                DeviceStore.deviceId: .string(value.deviceId),
                DeviceStore.consent: value.consent.map { .string($0.rawValue) } ?? .null,
                DeviceStore.lastVersion: value.lastVersion.map(PropertyValue.string) ?? .null,
                DeviceStore.lastBuild: value.lastBuild.map(PropertyValue.string) ?? .null,
                DeviceStore.retry: .object([
                    DeviceStore.pausedUntil: value.retry.pausedUntil.map { .int($0.epochMillis) } ?? .null,
                    DeviceStore.pauseKind: value.retry.pauseKind.map { .string($0.rawValue) } ?? .null,
                    DeviceStore.step: .int(Int64(value.retry.step)),
                    DeviceStore.lastFailure: value.retry.lastFailure.map(PropertyValue.string) ?? .null,
                    DeviceStore.batches: value.retry.batches.propertyValue,
                ]),
                DeviceStore.diagnostics: .object([
                    DeviceStore.periodStart: value.diagnostics.periodStart.map { .int($0.epochMillis) } ?? .null,
                    DeviceStore.lastSentAt: value.diagnostics.lastSentAt.map { .int($0.epochMillis) } ?? .null,
                    DeviceStore.dropped: value.diagnostics.dropped.propertyValue,
                    DeviceStore.issues: value.diagnostics.issues.propertyValue,
                ]),
            ]
        }

        func decode(_ fields: JsonFields) -> DeviceState? {
            let f = StoreFields(fields)
            do {
                let deviceId = try f.requiredString(DeviceStore.deviceId)
                guard !deviceId.allSatisfy({ $0.isWhitespace }) else { return nil }
                var consent: StoredConsent?
                if let name = try f.optionalString(DeviceStore.consent) {
                    guard let known = StoredConsent(rawValue: name) else { return nil }
                    consent = known
                }
                var retry = RetryState.none
                if let r = try f.optionalFields(DeviceStore.retry) {
                    var kind: PauseKind?
                    if let name = try r.optionalString(DeviceStore.pauseKind) {
                        guard let known = PauseKind(rawValue: name) else { return nil }
                        kind = known
                    }
                    retry = RetryState(
                        pausedUntil: try r.optionalDate(DeviceStore.pausedUntil), pauseKind: kind,
                        step: try r.optionalInt(DeviceStore.step) ?? 0,
                        lastFailure: try r.optionalString(DeviceStore.lastFailure),
                        batches: try r.intMap(DeviceStore.batches))
                }
                var diagnostics = DiagnosticsState.empty
                if let d = try f.optionalFields(DeviceStore.diagnostics) {
                    diagnostics = DiagnosticsState(
                        periodStart: try d.optionalDate(DeviceStore.periodStart),
                        lastSentAt: try d.optionalDate(DeviceStore.lastSentAt),
                        dropped: try d.intMap(DeviceStore.dropped), issues: try d.intMap(DeviceStore.issues))
                }
                return DeviceState(
                    deviceId: deviceId, consent: consent, lastVersion: try f.optionalString(DeviceStore.lastVersion),
                    lastBuild: try f.optionalString(DeviceStore.lastBuild), retry: retry, diagnostics: diagnostics)
            } catch {
                return nil
            }
        }
    }

    struct RemoteConfigCodec: StoreCodec {
        func encode(_ value: RemoteConfigCache) -> [String: PropertyValue] {
            [
                DeviceStore.etag: value.etag.map(PropertyValue.string) ?? .null,
                DeviceStore.values: .object(value.values),
            ]
        }

        func decode(_ fields: JsonFields) -> RemoteConfigCache? {
            let f = StoreFields(fields)
            do {
                return RemoteConfigCache(
                    etag: try f.optionalString(DeviceStore.etag),
                    values: try f.optionalObject(DeviceStore.values) ?? [:])
            } catch {
                return nil
            }
        }
    }
}

/// A copy of `value` changed by `change`, for value types without builders.
package func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
    var copy = value
    change(&copy)
    return copy
}
