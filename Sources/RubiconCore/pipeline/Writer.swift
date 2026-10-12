import Foundation

/// What the calling threads and the platform ask of the writer, in order (Queue 1).
package enum WriteMessage: Sendable {
    case enqueue(CapturedEvent)
    /// Every flush, whatever triggered it, so it includes every event accepted before it.
    case flush
    /// Write the stores now; any message does it too, this one only wakes the writer.
    case persist
    case foreground
    case background
    case networkRegained
    /// A reset or a user switch cleared the person; the session ends as theirs (Session 6).
    case personCleared(IdentitySnapshot)
    /// `optOut()` or `optIn()` changed the state (Privacy 1, 4).
    case consentChanged(from: ConsentState, to: ConsentState)
    /// `clearLocalData()`: every event tracked before it is deleted (Privacy 3).
    case clearLocalData
    /// Protected data is going away (iOS Disk 1): sync, close the handles, hold the events.
    case protectedDataWillBecomeUnavailable
    /// Protected data is back (iOS Disk 1): load the stores if not yet, drain, resume.
    case protectedDataDidBecomeAvailable
    /// The app is about to be killed (iOS Queue 2): write the stores, no upload.
    case willTerminate

    package var name: String {
        switch self {
        case .enqueue: return "Enqueue"
        case .flush: return "Flush"
        case .persist: return "Persist"
        case .foreground: return "Foreground"
        case .background: return "Background"
        case .networkRegained: return "NetworkRegained"
        case .personCleared: return "PersonCleared"
        case .consentChanged: return "ConsentChanged"
        case .clearLocalData: return "ClearLocalData"
        case .protectedDataWillBecomeUnavailable: return "ProtectedDataWillBecomeUnavailable"
        case .protectedDataDidBecomeAvailable: return "ProtectedDataDidBecomeAvailable"
        case .willTerminate: return "WillTerminate"
        }
    }

    /// The two protected-data messages are never skipped by a full channel: the unlock must reach a
    /// writer holding a thousand events, and the lock must reach it before the files close.
    fileprivate var bypassesCapacity: Bool {
        switch self {
        case .protectedDataWillBecomeUnavailable, .protectedDataDidBecomeAvailable: return true
        default: return false
        }
    }
}

/// The single consumer that writes (Queue 1, iOS Queue 1): events through the `EventPipeline` into
/// the event store, and the person and device stores. It is the only code that writes to disk.
///
/// - Its first task is loading the stores, then the identity calls made before that, the effective
///   configuration, the event store and the saved session (Privacy 2, Android log 6.1).
/// - Calling threads use `enqueue`, which never blocks: a full channel drops the event as
///   `backpressure`.
/// - Flush triggers (Queue 2, 3, 7), all as one `.flush`: the count of events appended since the last
///   flush, the interval from the first pending event, backgrounding, the network coming back while
///   events are pending, `flush()` and immediate events. No startup flush and no periodic timer. A
///   flush closes the open segment and raises the conflated upload signal.
/// - The stores are written when no message is waiting, at least every `persistEvery` messages, and
///   only when something changed, so changes coalesce (Disk 7).
/// - Locked device (iOS Disk 1): on `protectedDataWillBecomeUnavailable` the writer syncs, suspends
///   the event store, writes the stores and stops draining; events wait in the channel. On
///   `protectedDataDidBecomeAvailable` it loads the stores if the process started locked, then drains.
///
/// The channel is a lock-guarded array drained on the writer queue of the `Scheduler` (iOS Queue 1).
// Every field below `startedFlag` is touched only on the writer queue; the channel, the counters
// and the signal are guarded by their own locks.
package final class Writer: @unchecked Sendable {
    /// Queue 1: the write channel holds at most this many messages.
    package static let channelCapacity = 1000

    /// Under a steady load the stores are still written at least this often.
    package static let persistEvery = 100

    private let code: ConfigSnapshot
    private let platform: Platform
    private let log: Log
    private let deviceStore: DeviceStore
    private let personStore: PersonStore
    private let identity: Identity
    private let consent: ConsentController
    private let remote: RemoteConfigClient
    private let flags: RuntimeFlags
    private let eventStore: any EventStore
    private let newId: @Sendable () -> String

    private struct Channel {
        var messages: [WriteMessage] = []
        var sent: Int64 = 0
        var handled: Int64 = 0
        var started = false
        var draining = false
    }

    private let channel = Locked(Channel())

    /// Raised by every flush; the uploader conflates wakes into one drain (Queue 1). Tests read it.
    private let uploadSignal = AtomicFlag()
    /// What a flush wakes: the uploader's `signal()`, wired by the factory (step 6.4, 6.7).
    package let onUploadSignal = Locked<(@Sendable () -> Void)?>(nil)
    /// What the writer runs once the stores are loaded and the event store is open: the uploader's
    /// startup, wired by the factory (step 6.4, 6.7).
    package let onReady = Locked<(@Sendable () -> Void)?>(nil)

    private let startedFlag = AtomicFlag()
    private let readyFlag = AtomicFlag()
    private let lockedFlag = AtomicFlag()
    private let stoppedFlag = AtomicFlag()

    // Set up on the writer, at start or at the first unlock.
    private var snapshot: ConfigSnapshot
    private var sessions: SessionManager?
    private var pipeline: EventPipeline?
    private var appLifecycle: AppLifecycle?
    private var sendsDiagnostics = true
    private var storesLoaded = false
    private var listenersAdded = false
    private var lifecycleToken: (any ListenerToken)?
    private var networkToken: (any ListenerToken)?

    // Writer only.
    private var messagesSincePersist = 0
    private var appendedSinceFlush = 0
    private var interval: (any Cancellable)?
    private var reportingDiagnostics = false

    package init(
        code: ConfigSnapshot, platform: Platform, log: Log, deviceStore: DeviceStore, personStore: PersonStore,
        identity: Identity, consent: ConsentController, remote: RemoteConfigClient, flags: RuntimeFlags,
        eventStore: any EventStore, newId: @escaping @Sendable () -> String
    ) {
        self.code = code
        self.platform = platform
        self.log = log
        self.deviceStore = deviceStore
        self.personStore = personStore
        self.identity = identity
        self.consent = consent
        self.remote = remote
        self.flags = flags
        self.eventStore = eventStore
        self.newId = newId
        snapshot = code
    }

    /// `true` once the startup work ran; the uploader waits for it (step 6.4).
    package var isStarted: Bool { startedFlag.isSet }

    /// `true` once the stores are loaded and the event store is open: the uploader may read batches.
    package var isReady: Bool { readyFlag.isSet }

    /// `true` while protected data is unavailable (iOS Disk 1).
    package var isLocked: Bool { lockedFlag.isSet }

    /// No message waiting or being handled; for `flushBlocking` (tests and shutdown).
    package var isIdle: Bool {
        isStarted && channel.withLock { $0.handled == $0.sent && !$0.draining }
    }

    /// Whether `SDK Diagnostics` is sent, as the effective configuration says; known after start.
    package var diagnosticsEnabled: Bool { sendsDiagnostics }

    /// Takes the upload signal: `true` when it was raised since the last take.
    package func takeUploadSignal() -> Bool {
        uploadSignal.clear()
    }

    /// Stops the writer for a test that starts another instance on the same files: the stores are
    /// written, the interval timer and the listeners are cancelled, and later messages are ignored.
    package func shutdown() {
        stoppedFlag.set()
        platform.scheduler.run(on: .writer) { [self] in
            interval?.cancel()
            interval = nil
            lifecycleToken?.cancel()
            networkToken?.cancel()
            persistStores()
        }
    }

    /// Starts the writer: its startup work first, then the messages in order.
    package func start() {
        channel.withLock { $0.started = true }
        platform.scheduler.run(on: .writer) { [self] in
            startUp()
            startedFlag.set()
            drain()
        }
    }

    /// From any thread; never blocks. Returns `false` when the event was dropped as `backpressure`.
    package func enqueue(_ event: CapturedEvent) -> Bool {
        if offer(.enqueue(event)) { return true }
        deviceStore.countDropped(.backpressure)
        log.warn(.backpressure) { "Events arrive faster than they can be stored; one was dropped" }
        observe(.dropped(messageIds: [event.messageId], reason: .backpressure))
        return false
    }

    package func flush() { send(.flush) }
    package func requestPersist() { send(.persist) }
    package func personCleared(_ previous: IdentitySnapshot) { send(.personCleared(previous)) }
    package func consentChanged(from: ConsentState, to: ConsentState) { send(.consentChanged(from: from, to: to)) }
    package func clearLocalData() { send(.clearLocalData) }

    private func send(_ message: WriteMessage) {
        if !offer(message) { log.debug { "The write channel is full; \(message.name) was skipped" } }
    }

    private func offer(_ message: WriteMessage) -> Bool {
        let (accepted, started): (Bool, Bool) = channel.withLock { c in
            if c.messages.count >= Self.channelCapacity && !message.bypassesCapacity { return (false, c.started) }
            // Counted first, so the message is never handled before it is counted.
            c.sent += 1
            c.messages.append(message)
            return (true, c.started)
        }
        if accepted && started { platform.scheduler.run(on: .writer) { [self] in drain() } }
        return accepted
    }

    // MARK: - The writer queue

    private func drain() {
        platform.scheduler.assertOn(.writer)
        if stoppedFlag.isSet { return }
        guard
            channel.withLock({ c in
                if c.draining { return false }
                c.draining = true
                return true
            })
        else { return }
        defer { channel.withLock { $0.draining = false } }
        while let message = takeNext() {
            platform.contextProvider.refresh(disabled: snapshot.disabledFields)
            handle(message)
            // Changes coalesce (Disk 7): the stores are written when no message is waiting, and at
            // least every persistEvery messages under a steady load.
            messagesSincePersist += 1
            let quiet: Bool = channel.withLock { c in
                c.handled += 1
                return c.handled >= c.sent
            }
            if quiet || messagesSincePersist >= Self.persistEvery {
                messagesSincePersist = 0
                persistStores()
            }
        }
    }

    // The next message in order; while locked only the unlock message, wherever it waits.
    private func takeNext() -> WriteMessage? {
        channel.withLock { c in
            if c.messages.isEmpty { return nil }
            if lockedFlag.isSet {
                guard
                    let index = c.messages.firstIndex(where: {
                        if case .protectedDataDidBecomeAvailable = $0 { return true }
                        return false
                    })
                else { return nil }
                return c.messages.remove(at: index)
            }
            return c.messages.removeFirst()
        }
    }

    private func startUp() {
        // The platform's startup flag is advisory: the stores try to load, and a permission error is
        // what makes the writer wait (iOS Disk 1). The simulator's test host reports the flag false
        // and never posts the notification, so a flag-based lock would never open there.
        if !platform.lifecycleSource.isProtectedDataAvailable {
            log.debug { "Protected data is reported unavailable at startup; the stores decide" }
        }
        loadAndOpen()
        if !listenersAdded {
            listenersAdded = true
            // The network first: the context cache takes the network type from it.
            platform.networkMonitor.start()
            platform.contextProvider.refresh(disabled: snapshot.disabledFields)
            platform.lifecycleSource.start()
            lifecycleToken = platform.lifecycleSource.addListener { [weak self] event in
                guard let self else { return }
                switch event {
                case .foreground: send(.foreground)
                case .background: send(.background)
                case .willTerminate: send(.willTerminate)
                case .protectedDataWillBecomeUnavailable: send(.protectedDataWillBecomeUnavailable)
                case .protectedDataDidBecomeAvailable: send(.protectedDataDidBecomeAvailable)
                }
            }
            networkToken = platform.networkMonitor.addListener { [weak self] connected in
                if connected { self?.send(.networkRegained) }
            }
        }
        if storesLoaded {
            // A foreground signal that also arrives as a message is ignored then (AppLifecycle).
            if platform.lifecycleSource.isForeground { onForeground() }
            persistStores()
            log.debug { "Writer started with \(eventStore.pendingCount) pending events" }
        } else {
            log.debug { "Writer started before the first unlock; waiting for protected data" }
        }
    }

    /// Loads the stores and opens the event store; `false` while the device is locked, in which case
    /// nothing is set up and the call is repeated at the unlock (iOS Disk 1).
    @discardableResult
    private func loadAndOpen() -> Bool {
        if storesLoaded { return true }
        guard deviceStore.load(), personStore.load() else {
            lockedFlag.set()
            return false
        }
        consent.load()
        identity.load()
        let effective = remote.startup()
        snapshot = effective.snapshot
        sendsDiagnostics = effective.sendsDiagnostics
        guard
            eventStore.open(
                apiKey: snapshot.apiKey, clock: platform.clock, log: log,
                drops: { [deviceStore] reason, count in deviceStore.countDropped(reason, count: count) })
        else {
            lockedFlag.set()
            return false
        }
        let sessions = SessionManager(
            personStore: personStore, clock: platform.clock, elapsedClock: platform.elapsedClock,
            backgroundTimeoutMs: snapshot.sessionBackgroundTimeoutMs,
            emitEvents: snapshot.autocapture.contains(.sessions), newSessionId: newId, log: log,
            requestPersist: { [weak self] in self?.requestPersist() })
        self.sessions = sessions
        pipeline = EventPipeline(
            hooks: snapshot.beforeSend, disabledFields: snapshot.disabledFields, debug: snapshot.debug,
            contextProvider: platform.contextProvider, sessions: sessions, newMessageId: newId, log: log)
        appLifecycle = AppLifecycle(
            deviceStore: deviceStore, processFacts: platform.processFacts, clock: platform.clock,
            autocapture: snapshot.autocapture)
        storesLoaded = true
        readyFlag.set()
        onReady.current?()
        appendSessionEvents(sessions.start())
        appendedSinceFlush = eventStore.pendingCount
        if appendedSinceFlush > 0 { startInterval() }
        return true
    }

    private func handle(_ message: WriteMessage) {
        switch message {
        // Nothing new while opted out; events that waited for the stored choice are discarded
        // unwritten and uncounted (Privacy 1, 2).
        case .enqueue(let event):
            guard collecting, isEffective(event), let pipeline, let resolved = resolve(event) else { return }
            _ = append(pipeline.process(resolved), diagnostics: resolved.skipsHooks)
        case .flush:
            flushNow("requested")
        case .persist:
            break
        case .foreground:
            onForeground()
        case .background:
            // Backgrounded goes into the session and into the background flush.
            if let events = appLifecycle?.onBackground() { appendAutomatic(events) }
            sessions?.onBackground()
            eventStore.sync()
            flushNow("background")
        case .networkRegained:
            if eventStore.pendingCount > 0 { flushNow("network regained") }
        case .personCleared(let previous):
            if let sessions { appendSessionEvents(sessions.onPersonCleared(previous)) }
        case .consentChanged(let from, let to):
            onConsentChanged(from: from, to: to)
        case .clearLocalData:
            clearEvents()
        case .protectedDataWillBecomeUnavailable:
            lockedFlag.set()
            eventStore.suspend()
            persistStores()
            log.debug { "Protected data is going away; events wait until the unlock" }
        case .protectedDataDidBecomeAvailable:
            lockedFlag.clear()
            if !storesLoaded {
                if loadAndOpen() {
                    if platform.lifecycleSource.isForeground { onForeground() }
                    log.debug { "Protected data is available; the stores are loaded" }
                }
            } else {
                log.debug { "Protected data is available; resuming" }
            }
        case .willTerminate:
            eventStore.sync()
            persistStores()
        }
    }

    // A type switched off by remote configuration produces nothing; not a loss, so not counted.
    private func isEffective(_ event: CapturedEvent) -> Bool {
        event.gate.map { snapshot.autocapture.contains($0) } ?? true
    }

    private func onForeground() {
        guard let sessions else { return }
        appendSessionEvents(sessions.onForeground())
        if let events = appLifecycle?.onForeground() { appendAutomatic(events) }
    }

    // Timestamped now, inside the session the pipeline opens for them (Lifecycle 4).
    private func appendAutomatic(_ events: [AppLifecycle.AutoEvent]) {
        guard collecting, let pipeline else { return }
        for event in events {
            let captured = CapturedEvent(
                kind: .track, name: event.name, values: event.properties, source: .auto, messageId: newId(),
                timestamp: platform.clock.now(), identity: identity.snapshot(),
                callTime: platform.contextProvider.callTimeValues(disabled: snapshot.disabledFields))
            _ = append(pipeline.process(captured), diagnostics: false)
        }
    }

    // An identify is sent only if its ticket says so, with the traits and identity of that moment.
    private func resolve(_ event: CapturedEvent) -> CapturedEvent? {
        guard let ticket = event.ticket else { return event }
        guard case .sendEvent(let traits, let identity)? = ticket.decision else { return nil }
        let ref = IdentityRef()
        ref.fill(identity)
        return CapturedEvent(
            kind: event.kind, name: event.name, values: traits, source: event.source, messageId: event.messageId,
            timestamp: event.timestamp, identity: ref, callTime: event.callTime)
    }

    private var collecting: Bool {
        flags.isCollecting && consent.state != .denied
    }

    private func onConsentChanged(from: ConsentState, to: ConsentState) {
        if to == .denied {
            // The open session ends without an event (Privacy 1). Events written while consent
            // was pending were collected without it and go, uncounted (Privacy 4).
            sessions?.endSilently()
            if from == .pending { clearEvents() }
        } else if from == .pending {
            flushNow("consent granted")
        }
    }

    // Deleted on purpose: not a loss, so not counted (Privacy 3, 4).
    private func clearEvents() {
        sessions?.endSilently()
        interval?.cancel()
        interval = nil
        appendedSinceFlush = 0
        eventStore.clear()
    }

    private func appendSessionEvents(_ events: [SessionEvent]) {
        guard !events.isEmpty, collecting, let pipeline, let current = identity.snapshot().value else { return }
        _ = append(
            pipeline.processSessionEvents(
                events, current: current,
                callTime: platform.contextProvider.callTimeValues(disabled: snapshot.disabledFields)),
            diagnostics: false)
    }

    /// Appends the accepted results; returns the message ids that reached the store.
    private func append(_ results: [PipelineResult], diagnostics: Bool) -> Set<String> {
        var stored: Set<String> = []
        var immediate: String?
        for result in results {
            switch result {
            case .accepted(let event, let line):
                // A failed append is counted and logged by the store (Disk 4); a locked store keeps
                // nothing, and the event is lost with the process (iOS Disk 1).
                guard eventStore.append(line) == .appended else { continue }
                stored.insert(event.messageId)
                observe(.queued(event))
                appendedSinceFlush += 1
                if interval == nil { startInterval() }
                if let name = Self.name(of: event), snapshot.immediateEvents.contains(name) { immediate = name }
            case .dropped(let messageId, let reason):
                // The drop of SDK Diagnostics itself is not counted, which avoids a loop (Logging 5).
                if !diagnostics { deviceStore.countDropped(reason) }
                observe(.dropped(messageIds: [messageId], reason: reason))
            }
        }
        if let immediate {
            log.debug { "Immediate event \"\(immediate)\" persisted; flushing" }
            flushNow("immediate event")
        } else if appendedSinceFlush >= snapshot.flushAt {
            flushNow("count")
        }
        return stored
    }

    private func flushNow(_ reason: String) {
        appendDiagnosticsIfDue()
        interval?.cancel()
        interval = nil
        appendedSinceFlush = 0
        eventStore.closeOpenSegment()
        uploadSignal.set()
        onUploadSignal.current?()
        log.debug { "Flush (\(reason)), \(eventStore.pendingCount) events pending" }
    }

    /// `SDK Diagnostics` right before a flush, when due (Logging 5): never while opted out, pending or
    /// switched off, never through the hooks, and its own drop is not counted. The counters it
    /// reports are taken off only once it is stored.
    private func appendDiagnosticsIfDue() {
        guard !reportingDiagnostics, sendsDiagnostics, collecting, consent.state == .granted, let pipeline,
            let state = deviceStore.state?.diagnostics
        else { return }
        let now = platform.clock.now()
        guard Diagnostics.isDue(state, now: now) else { return }
        reportingDiagnostics = true
        defer { reportingDiagnostics = false }
        let event = CapturedEvent(
            kind: .track, name: Diagnostics.eventName, values: Diagnostics.properties(state, now: now), source: .auto,
            messageId: newId(), timestamp: now, identity: identity.snapshot(),
            callTime: platform.contextProvider.callTimeValues(disabled: snapshot.disabledFields), skipsHooks: true)
        if append(pipeline.process(event), diagnostics: true).contains(event.messageId) {
            deviceStore.diagnosticsReported(state, at: now)
            log.debug { "SDK Diagnostics written" }
        }
    }

    private func startInterval() {
        interval = platform.scheduler.schedule(after: snapshot.flushIntervalMs, on: .writer) { [weak self] in
            self?.send(.flush)
        }
    }

    private func persistStores() {
        personStore.persist()
        deviceStore.persist()
    }

    private func observe(_ update: EventUpdate) {
        guard let observer = code.eventObserver else { return }
        log.callbacks.notifyObserver { observer(update) }
    }

    private static func name(of event: any Event) -> String? {
        switch event {
        case let track as TrackEvent: return track.name
        case let screen as ScreenEvent: return screen.name
        default: return nil
        }
    }
}
