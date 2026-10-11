import Foundation
import RubiconCore

/// A `Platform` made of fakes, with each fake kept as a property so the test can drive it. Override
/// a part with a named argument:
///
/// ```swift
/// let test = TestPlatform(clock: TestClock(start: Date(epochMillis: 0)))
/// test.transport.enqueue(.httpError(code: 503, body: nil, retryAfterMs: nil))
/// // test.platform goes to the component under test, or to the core factory (step 6.7)
/// ```
///
/// Every SDK worker runs on `scheduler`, so time is virtual. `storageRoot` is a fresh temporary
/// directory per instance, deleted by `cleanUp()`; the file system is a `FakeFileSystem` over real
/// files, for fault injection and the locked state.
package final class TestPlatform: Sendable {
    package let clock: TestClock
    package let elapsedClock: TestElapsedClock
    package let random: any RandomSource
    package let scheduler: TestScheduler
    package let networkMonitor: FakeNetworkMonitor
    package let transport: FakeTransport
    package let contextProvider: FakeContextProvider
    package let processFacts: FakeProcessFacts
    package let lifecycleSource: FakeLifecycleSource
    package let logger: RecordingLogger
    package let storageRoot: URL
    package let fileSystem: FakeFileSystem
    package let platform: Platform

    package init(
        clock: TestClock = TestClock(),
        elapsedClock: TestElapsedClock = TestElapsedClock(),
        random: any RandomSource = SeededRandom(),
        scheduler: TestScheduler = TestScheduler(),
        networkMonitor: FakeNetworkMonitor = FakeNetworkMonitor(),
        transport: FakeTransport = FakeTransport(),
        contextProvider: FakeContextProvider = FakeContextProvider(),
        processFacts: FakeProcessFacts = FakeProcessFacts(),
        lifecycleSource: FakeLifecycleSource = FakeLifecycleSource(),
        logger: RecordingLogger = RecordingLogger(),
        storageRoot: URL? = nil,
        fileSystem: FakeFileSystem = FakeFileSystem()
    ) {
        self.clock = clock
        self.elapsedClock = elapsedClock
        self.random = random
        self.scheduler = scheduler
        self.networkMonitor = networkMonitor
        self.transport = transport
        self.contextProvider = contextProvider
        self.processFacts = processFacts
        self.lifecycleSource = lifecycleSource
        self.logger = logger
        self.storageRoot = storageRoot ?? TestPlatform.temporaryDirectory()
        self.fileSystem = fileSystem
        platform = Platform(
            clock: clock, elapsedClock: elapsedClock, random: random, scheduler: scheduler,
            networkMonitor: networkMonitor, transportFactory: { _, _ in transport },
            contextProvider: contextProvider, processFacts: processFacts, lifecycleSource: lifecycleSource,
            logger: logger.asLogger, storageRoot: self.storageRoot, fileSystem: fileSystem)
    }

    /// Developer errors reported through logs made by `log(level:logger:)`, in order, instead of
    /// trapping (iOS Configuration 2).
    package let developerErrors = Locked<[String]>([])

    /// A `Log` at `level` that writes to this platform's recording logger and records developer
    /// errors, for components that take one directly.
    package func log(level: LogLevel = .debug, logger: RubiconLogger? = nil) -> Log {
        Log(
            level: level, logger: logger, platformLogger: self.logger.asLogger,
            developerError: { [developerErrors] message in developerErrors.withLock { $0.append(message) } })
    }

    /// A fresh, empty directory under the system temporary directory.
    package static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubicon-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Deletes the storage root.
    package func cleanUp() {
        try? FileManager.default.removeItem(at: storageRoot)
    }
}
