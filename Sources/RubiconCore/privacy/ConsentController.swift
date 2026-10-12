import Foundation

/// Where collection stands (Privacy 1, 4).
package enum ConsentState: Sendable, Equatable {
    /// Collected and sent.
    case granted
    /// Collected and written, not sent until the user decides.
    case pending
    /// Opted out: nothing new; what was queued with consent is still sent.
    case denied
}

/// The user's consent (Privacy 1, 2, 4).
///
/// - The state starts from `privacy.defaultConsent`; with `privacy.persistConsent` a stored choice in
///   `DeviceStore` wins. Without it the stored value is neither read nor written.
/// - `optOut()` and `optIn()` apply in memory at once, from any thread, and tell the writer through
///   `onChange`, which ends the session, deletes waiting events or flushes (step 6.3b). No event is
///   produced; the change is logged at INFO.
/// - Before the stored choice is known, calls are kept in call order and applied when it is: by the
///   writer's `load()`, or by `isOptedOut`, which may read `device.json` once on the calling thread
///   (Public API 9, Privacy 2). While the device is locked before the first unlock the file cannot be
///   read: `isOptedOut` then answers from `defaultConsent` and the calls keep waiting for the writer
///   (iOS Disk 1).
// `loaded` and `pending` are guarded by `lock`; `current` is a `Locked` value read without it.
package final class ConsentController: @unchecked Sendable {
    private let defaultConsent: Consent
    private let persistConsent: Bool
    private let deviceStore: DeviceStore
    private let log: Log
    private let onChange: @Sendable (_ from: ConsentState, _ to: ConsentState) -> Void

    // Reentrant, as `synchronized` is on Android: `onChange` runs inside it and may read `state`.
    private let lock = NSRecursiveLock()
    // Guarded by `lock`.
    private var loaded = false
    private var pending: [ConsentState] = []

    private let current = Locked(ConsentState.granted)

    package init(
        defaultConsent: Consent, persistConsent: Bool, deviceStore: DeviceStore, log: Log,
        onChange: @escaping @Sendable (_ from: ConsentState, _ to: ConsentState) -> Void
    ) {
        self.defaultConsent = defaultConsent
        self.persistConsent = persistConsent
        self.deviceStore = deviceStore
        self.log = log
        self.onChange = onChange
    }

    /// The state now; read by the writer and the uploader after load.
    package var state: ConsentState { current.current }

    /// The uploader's consent gate (step 6.4): closed only while pending. After an opt-out, events
    /// collected with consent are still sent (Privacy 1); those of a pending state were deleted.
    package var allowsUploads: Bool { state != .pending }

    /// On the writer, after `DeviceStore.load` succeeded; a no-op when already loaded.
    package func load() {
        lock.lock()
        defer { lock.unlock() }
        if loaded { return }
        current.withLock { $0 = initial() }
        loaded = true
        let changes = pending
        pending = []
        for change in changes { apply(change) }
    }

    /// `true` while opted out or pending: nothing is being sent now (Privacy 4). Before the writer
    /// loaded the store it reads `device.json` once on this thread; while the device is locked it
    /// answers from `defaultConsent` (iOS Disk 1).
    package var isOptedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            deviceStore.readEarly()
            if deviceStore.isLoaded {
                load()
            } else {
                return defaultConsent == .pending
            }
        }
        return state != .granted
    }

    package func optOut() {
        change(.denied)
    }

    package func optIn() {
        change(.granted)
    }

    private func change(_ to: ConsentState) {
        lock.lock()
        defer { lock.unlock() }
        if loaded { apply(to) } else { pending.append(to) }
    }

    private func apply(_ to: ConsentState) {
        let from = state
        if persistConsent {
            let stored: StoredConsent = to == .granted ? .granted : .denied
            deviceStore.update { with($0) { $0.consent = stored } }
        }
        if from == to { return }
        current.withLock { $0 = to }
        log.info {
            to == .denied ? "The user opted out; nothing new is collected" : "The user opted in; collection resumes"
        }
        onChange(from, to)
    }

    private func initial() -> ConsentState {
        let stored = persistConsent ? deviceStore.state?.consent : nil
        switch stored {
        case .granted: return .granted
        case .denied: return .denied
        case nil: return defaultConsent == .pending ? .pending : .granted
        }
    }
}
