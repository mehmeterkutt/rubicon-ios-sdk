import Foundation

/// Everything the SDK takes from its environment, in one place (Configuration 5). The `Rubicon`
/// target builds the production value; tests build one from `TestPlatform` and reach the SDK through
/// the `package` factory overload. Nothing here is replaceable by developers.
package struct Platform: Sendable {
    package var clock: any Clock
    package var elapsedClock: any ElapsedClock
    package var random: any RandomSource
    package var scheduler: any Scheduler
    package var networkMonitor: any NetworkMonitor
    /// Builds the transport once the configuration is validated (HTTP 1).
    package var transportFactory: HttpTransportFactory
    package var contextProvider: any ContextProvider
    package var processFacts: any ProcessFacts
    package var lifecycleSource: any LifecycleSource
    /// `Application Support/rubicon/` on iOS (iOS Identity 1), a temporary directory in tests.
    package var storageRoot: URL
    /// The file operations of the file-based stores, a seam for fault injection and the locked state.
    package var fileSystem: any FileSystem

    package init(
        clock: any Clock,
        elapsedClock: any ElapsedClock,
        random: any RandomSource,
        scheduler: any Scheduler,
        networkMonitor: any NetworkMonitor,
        transportFactory: @escaping HttpTransportFactory,
        contextProvider: any ContextProvider,
        processFacts: any ProcessFacts,
        lifecycleSource: any LifecycleSource,
        storageRoot: URL,
        fileSystem: any FileSystem
    ) {
        self.clock = clock
        self.elapsedClock = elapsedClock
        self.random = random
        self.scheduler = scheduler
        self.networkMonitor = networkMonitor
        self.transportFactory = transportFactory
        self.contextProvider = contextProvider
        self.processFacts = processFacts
        self.lifecycleSource = lifecycleSource
        self.storageRoot = storageRoot
        self.fileSystem = fileSystem
    }
}
