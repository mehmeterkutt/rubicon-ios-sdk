import Foundation

/// The real `Analytics` (Public API 2, iOS Public API 4): the calling thread only validates, copies
/// and snapshots, and hands the rest to the writer (Public API 9).
///
/// With `debug` on, the developer mistakes the decisions name are developer errors (`assertionFailure`
/// in a debug build): an invalid name, user id or property. Swift has no exceptions to catch at the
/// entry points; nothing the SDK does on the calling thread can trap, and a trap in a hook is the
/// hook's own (iOS Public API 6).
// Every stored property is a constant; the components keep their own state behind locks or on a
// worker queue.
package final class DefaultAnalytics: Analytics, AutomaticCapture, BackgroundFlushControl, @unchecked Sendable {
    private let code: ConfigSnapshot
    private let platform: Platform
    package let log: Log
    private let identity: Identity
    private let consent: ConsentController
    private let flags: RuntimeFlags
    private let writer: Writer
    private let uploader: Uploader
    private let eventStore: any EventStore
    private let transport: any HttpTransport
    private let newId: @Sendable () -> String

    package init(
        code: ConfigSnapshot, platform: Platform, log: Log, identity: Identity, consent: ConsentController,
        flags: RuntimeFlags, writer: Writer, uploader: Uploader, eventStore: any EventStore,
        transport: any HttpTransport, newId: @escaping @Sendable () -> String
    ) {
        self.code = code
        self.platform = platform
        self.log = log
        self.identity = identity
        self.consent = consent
        self.flags = flags
        self.writer = writer
        self.uploader = uploader
        self.eventStore = eventStore
        self.transport = transport
        self.newId = newId
    }

    // MARK: - Analytics

    package func track(_ name: String, properties: [String: Any]) {
        capture(.track, name, properties)
    }

    package func screen(_ name: String, properties: [String: Any]) {
        capture(.screen, name, properties)
    }

    package func identify(_ userId: String, traits: [String: Any]) {
        guard let ticket = identity.identify(userId, traits: traits), creating else { return }
        _ = writer.enqueue(
            CapturedEvent(
                kind: .identify, name: nil, values: [:], source: .app, messageId: newId(),
                timestamp: platform.clock.now(),
                identity: identity.snapshot(),
                callTime: platform.contextProvider.callTimeValues(disabled: code.disabledFields),
                ticket: ticket))
    }

    package func reset() {
        identity.reset()
    }

    package func register(_ key: String, value: Any) {
        identity.register(key, value: value)
    }

    package func unregister(_ key: String) {
        identity.unregister(key)
    }

    package func flush() {
        writer.flush()
    }

    package func optOut() {
        consent.optOut()
    }

    package func optIn() {
        consent.optIn()
    }

    package var isOptedOut: Bool { consent.isOptedOut }

    package func clearLocalData() {
        identity.clearLocalData(newDeviceId: newId())
        writer.clearLocalData()
    }

    package var deviceId: String { identity.deviceId }

    package func trackDeepLink(_ url: URL, referrer: String?) {
        track(gate: .deepLinks, name: DeepLink.eventName, properties: DeepLink.properties(url: url, referrer: referrer))
    }

    package func trackDeepLink(_ activity: NSUserActivity) {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL else {
            log.debug { "trackDeepLink ignored an activity that is not a universal link" }
            return
        }
        trackDeepLink(url, referrer: DeepLink.referrer(of: activity.referrerURL))
    }

    // MARK: - AutomaticCapture

    package func track(gate: Autocapture, name: String, properties: [String: Any]) {
        capture(.track, name, properties, source: .auto, gate: gate, strict: false)
    }

    package func screen(gate: Autocapture, name: String, properties: [String: Any]) {
        capture(.screen, name, properties, source: .auto, gate: gate, strict: false)
    }

    package var capturesNetworkRequests: Bool {
        flags.isCapturingNetworkRequests && code.autocapture.contains(.networkRequests) && creating
    }

    package var sdkHost: String { code.hostURL.host ?? "" }

    package var debug: Bool { code.debug }

    // MARK: - BackgroundFlushControl

    package func beginBackgroundFlush(onDone: @escaping @Sendable () -> Void) {
        uploader.beginBackgroundFlush(onDone: onDone)
    }

    package func expireBackgroundFlush() {
        uploader.expireBackgroundFlush()
    }

    // MARK: - Tests and shutdown

    /// Asks for a flush and waits until nothing is pending or `timeoutMs` passed; `true` when
    /// everything was sent. For tests and shutdown only, never public (Public API 9).
    package func flushBlocking(timeoutMs: Int64) -> Bool {
        writer.flush()
        var polls = max(1, timeoutMs / Self.pollMillis)
        while polls > 0 {
            if eventStore.pendingCount == 0 && writer.isIdle && uploader.isIdle { return true }
            Thread.sleep(forTimeInterval: Double(Self.pollMillis) / 1000)
            polls -= 1
        }
        return false
    }

    /// Stops the writer, the uploader and the transport; for tests, to start another instance on the
    /// same files. A request in flight finishes first (at most the 45 s watchdog, HTTP 3).
    package func shutdown() {
        writer.shutdown()
        uploader.shutdown()
        transport.shutdown()
        var polls = Self.shutdownTimeoutMillis / Self.pollMillis
        while polls > 0 && !(writer.isIdle && uploader.isIdle) {
            Thread.sleep(forTimeInterval: Double(Self.pollMillis) / 1000)
            polls -= 1
        }
    }

    // MARK: - Private

    // Whether new events may be created now: not while opted out or switched off (Privacy 1,
    // Configuration 1). Before the stored choice is known the writer decides.
    private var creating: Bool {
        flags.isCollecting && consent.state != .denied
    }

    private func capture(
        _ kind: CapturedEvent.Kind, _ name: String, _ properties: [String: Any], source: EventSource = .app,
        gate: Autocapture? = nil, strict: Bool? = nil
    ) {
        let strict = strict ?? code.debug
        if let problem = PropertyNormalizer.checkName(name) {
            if strict { log.developerError(problem.message) }
            log.warn(.invalidEventName) { problem.message }
            return
        }
        guard creating else { return }
        let normalized = PropertyNormalizer.normalize(properties)
        PropertyProblem.report(normalized.problems, debug: strict, log: log)
        _ = writer.enqueue(
            CapturedEvent(
                kind: kind, name: name, values: normalized.values, source: source, messageId: newId(),
                timestamp: platform.clock.now(), identity: identity.snapshot(),
                callTime: platform.contextProvider.callTimeValues(disabled: code.disabledFields), gate: gate))
    }

    private static let pollMillis: Int64 = 10
    private static let shutdownTimeoutMillis: Int64 = 5_000
}
