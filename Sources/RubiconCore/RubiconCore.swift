import Foundation

/// The core factory, `(configuration, platform)`; `Rubicon`'s `RubiconAnalytics.make(configuration:)`
/// calls it with the iOS platform, and tests with a test platform (Configuration 3, 5; iOS Public
/// API 4).
///
/// - The configuration is validated: with `debug` on a mistake is a developer error; a blank key or
///   an invalid host gives `NoOpAnalytics` with an ERROR, and other mistakes are fixed with a WARN. The
///   configuration is a value, so nothing needs freezing (iOS Configuration 1). The effective host is
///   logged once at INFO.
/// - One instance per process: a second call is a developer error with `debug` on and returns the
///   first instance, whose configuration stays in force (Public API 1, Configuration 3).
/// - Nothing is read on the calling thread; the writer loads the stores first (Privacy 2).
package enum RubiconCore {
    private static let instance = Locked<DefaultAnalytics?>(nil)

    /// Creates the instance; `onCreated` runs once, for a newly created instance only (not for the
    /// no-op or a second call), so `Rubicon` can attach its automatic capture.
    package static func create(
        configuration: AnalyticsConfiguration, platform: Platform,
        onCreated: (any AutomaticCapture) -> Void = { _ in }
    ) -> any Analytics {
        let debug = configuration.debug
        // Counted into DeviceStore once it exists; the log is needed to build it.
        let deviceSlot = Locked<DeviceStore?>(nil)
        let log = Log(
            level: configuration.logging.level, logger: configuration.logging.logger, platformLogger: platform.logger,
            issues: { code in deviceSlot.current?.issueCounter(code) }, developerError: platform.developerError)
        if let existing = instance.current { return second(existing, debug: debug, log: log) }
        let result = ConfigValidator.validate(configuration)
        result.report(debug: debug, log: log)
        guard let code = result.snapshot else { return NoOpAnalytics() }
        log.info { "Sending to \(code.host)" }

        let ids = UuidV7Generator(clock: platform.clock, random: platform.random)
        let keyValueStore = FileKeyValueStore(root: platform.storageRoot, fileSystem: platform.fileSystem)
        let device = DeviceStore(keyValueStore: keyValueStore, log: log, clock: platform.clock, newDeviceId: ids.next)
        deviceSlot.withLock { $0 = device }
        let person = PersonStore(keyValueStore: keyValueStore, log: log)
        let flags = RuntimeFlags()
        let eventStore = FileEventStore(root: platform.storageRoot, fileSystem: platform.fileSystem)
        let writerSlot = Locked<Writer?>(nil)
        let consent = ConsentController(
            defaultConsent: code.defaultConsent, persistConsent: code.persistConsent, deviceStore: device, log: log,
            onChange: { from, to in writerSlot.current?.consentChanged(from: from, to: to) })
        let identity = Identity(
            personStore: person, deviceStore: device, log: log, debug: debug,
            eventsAllowed: { consent.state != .denied },
            requestPersist: { writerSlot.current?.requestPersist() },
            onPersonCleared: { previous in writerSlot.current?.personCleared(previous) })
        let transport = platform.transportFactory(
            TransportSettings(apiKey: code.apiKey, headers: code.headers, log: log), platform)
        let remote = RemoteConfigClient(code: code, deviceStore: device, transport: transport, flags: flags, log: log)
        let writer = Writer(
            code: code, platform: platform, log: log, deviceStore: device, personStore: person, identity: identity,
            consent: consent, remote: remote, flags: flags, eventStore: eventStore, newId: ids.next)
        writerSlot.withLock { $0 = writer }
        let uploader = Uploader(
            eventStore: eventStore, transport: transport, batchURL: code.batchURL,
            policy: RetryPolicy(
                deviceStore: device, clock: platform.clock, elapsedClock: platform.elapsedClock,
                random: platform.random,
                log: log),
            remote: remote, networkMonitor: platform.networkMonitor, scheduler: platform.scheduler, flags: flags,
            deviceStore: device, clock: platform.clock, log: log, observer: code.eventObserver,
            writerReady: { writer.isReady }, requestPersist: { writer.requestPersist() },
            uploadsAllowed: { consent.allowsUploads })
        writer.onUploadSignal.withLock { $0 = { uploader.signal() } }
        writer.onReady.withLock { $0 = { uploader.start() } }
        let analytics = DefaultAnalytics(
            code: code, platform: platform, log: log, identity: identity, consent: consent, flags: flags,
            writer: writer,
            uploader: uploader, eventStore: eventStore, transport: transport, newId: ids.next)
        let claimed: DefaultAnalytics? = instance.withLock { slot in
            if let existing = slot { return existing }
            slot = analytics
            return nil
        }
        if let claimed { return second(claimed, debug: debug, log: log) }
        writer.start()
        uploader.start()
        onCreated(analytics)
        return analytics
    }

    private static func second(_ existing: DefaultAnalytics, debug: Bool, log: Log) -> any Analytics {
        let message = "Analytics was created a second time in this process; the first instance is returned"
        if debug { log.developerError(message) }
        log.error(.secondInstance) { message }
        return existing
    }

    /// Asks `analytics` to flush and waits until nothing is pending, at most `timeoutMs`; `true` when
    /// everything was sent, `false` for the no-op instance. For tests and shutdown only (Public API 9).
    package static func flushBlocking(_ analytics: any Analytics, timeoutMs: Int64) -> Bool {
        (analytics as? DefaultAnalytics)?.flushBlocking(timeoutMs: timeoutMs) ?? false
    }

    /// Stops and forgets the instance; for tests that create one per test, in every target.
    package static func resetForTests() {
        let current: DefaultAnalytics? = instance.withLock { slot in
            defer { slot = nil }
            return slot
        }
        current?.shutdown()
    }
}
