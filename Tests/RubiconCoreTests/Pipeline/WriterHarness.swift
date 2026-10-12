import Foundation
import RubiconTesting

@testable import RubiconCore

/// The writer wired as the SDK will wire it (step 6.7), on the virtual scheduler, with an in-memory
/// event store and file stores in a temporary directory: identity and consent tell the writer through
/// its messages. The port of the Android `WriterHarness`.
final class WriterHarness: @unchecked Sendable {
    let test: TestPlatform
    let eventStore: InMemoryEventStore
    let updates = Locked<[EventUpdate]>([])
    let code: ConfigSnapshot
    let log: Log
    let keyValueStore: FileKeyValueStore
    let ids: UuidV7Generator
    let deviceStore: DeviceStore
    let personStore: PersonStore
    let flags = RuntimeFlags()
    let remote: RemoteConfigClient
    lazy var consent: ConsentController = ConsentController(
        defaultConsent: code.defaultConsent, persistConsent: code.persistConsent, deviceStore: deviceStore, log: log,
        onChange: { [unowned self] from, to in writer.consentChanged(from: from, to: to) })
    lazy var identity: Identity = Identity(
        personStore: personStore, deviceStore: deviceStore, log: log, debug: false,
        eventsAllowed: { [unowned self] in consent.state != .denied },
        requestPersist: { [unowned self] in writer.requestPersist() },
        onPersonCleared: { [unowned self] previous in writer.personCleared(previous) })
    lazy var writer: Writer = Writer(
        code: code, platform: test.platform, log: log, deviceStore: deviceStore, personStore: personStore,
        identity: identity, consent: consent, remote: remote, flags: flags, eventStore: eventStore, newId: ids.next)

    /// `storageRoot` shared between two harnesses is what a restart looks like.
    init(
        configure: (inout AnalyticsConfiguration) -> Void = { _ in },
        eventStore: InMemoryEventStore = InMemoryEventStore(),
        storageRoot: URL? = nil, lifecycleSource: FakeLifecycleSource = FakeLifecycleSource(),
        fileSystem: FakeFileSystem = FakeFileSystem()
    ) {
        var config = AnalyticsConfiguration(apiKey: "rk_test")
        config.flush.at = 5
        config.flush.intervalMs = 60_000
        let updates = self.updates
        config.logging.eventObserver = { update in updates.withLock { $0.append(update) } }
        configure(&config)
        guard let snapshot = ConfigValidator.validate(config).snapshot else {
            fatalError("the harness configuration is invalid")
        }
        code = snapshot
        self.eventStore = eventStore
        test = TestPlatform(lifecycleSource: lifecycleSource, storageRoot: storageRoot, fileSystem: fileSystem)
        log = test.log()
        keyValueStore = FileKeyValueStore(root: test.storageRoot, fileSystem: test.fileSystem)
        ids = UuidV7Generator(clock: test.clock, random: test.random)
        deviceStore = DeviceStore(keyValueStore: keyValueStore, log: log, clock: test.clock, newDeviceId: ids.next)
        personStore = PersonStore(keyValueStore: keyValueStore, log: log)
        remote = RemoteConfigClient(
            code: code, deviceStore: deviceStore, transport: test.transport, flags: flags, log: log)
    }

    private var seq = 0

    @discardableResult
    func track(_ name: String = "Tapped", values: [String: PropertyValue] = [:], callTime: CallTimeValues = .none)
        -> Bool
    {
        seq += 1
        return writer.enqueue(
            CapturedEvent(
                kind: .track, name: name, values: values, source: .app, messageId: "m-\(seq)",
                timestamp: test.clock.now(), identity: identity.snapshot(), callTime: callTime))
    }

    /// Runs everything due now on the virtual scheduler, the Android `runCurrent()`.
    func runCurrent() { test.scheduler.runUntilIdle() }

    /// Moves the virtual scheduler forward, the Android `advanceTimeBy`.
    func advance(_ millis: Int64) { test.scheduler.advance(byMillis: millis) }

    /// Time passes on the wall clock and the elapsed clock, as on a device.
    func pass(_ millis: Int64) {
        test.clock.advance(byMillis: millis)
        test.elapsedClock.advance(byMillis: millis)
    }

    func lines() -> [String] { eventStore.allLines }

    func names() -> [String] { lines().map { field($0, "event") ?? "?" } }

    func sources() -> [String] { lines().map { field($0, "source") ?? "?" } }

    /// A top-level field as text; JSON null reads as no value, not as the text "null".
    func field(_ line: String, _ key: String) -> String? {
        guard case .object(let object)? = try? JSONValue.parse(line) else { return nil }
        switch object[key] {
        case .string(let text)?: return text
        case .number(let number)?:
            return number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .bool(let flag)?: return String(flag)
        default: return nil
        }
    }

    /// The conflated upload signal: 1 when it was raised since the last call, else 0.
    func signals() -> Int { writer.takeUploadSignal() ? 1 : 0 }

    var queued: [String] {
        updates.current.compactMap {
            if case .queued(let event) = $0 { return event.messageId }
            return nil
        }
    }

    var dropped: [(ids: [String], reason: DropReason)] {
        updates.current.compactMap {
            if case .dropped(let ids, let reason) = $0 { return (ids, reason) }
            return nil
        }
    }

    func logged(_ level: LogLevel, containing text: String) -> Bool {
        test.logger.lines.contains { $0.level == level && $0.message.contains(text) }
    }

    func cleanUp() { test.cleanUp() }
}
