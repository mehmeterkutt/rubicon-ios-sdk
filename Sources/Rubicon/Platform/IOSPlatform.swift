import Foundation
import RubiconCore

/// The iOS `Platform` (Configuration 5, iOS Public API 8). Building it reads nothing from disk, so the
/// factory can run on the main thread (Public API 9): the storage root is computed, not created; the
/// stores create it on their first write and exclude it from backup (iOS Identity 1, iOS Disk 1).
enum IOSPlatform {
    static let rootDirectoryName = "rubicon"

    /// `Application Support/rubicon/`: never purged by the system, deleted with the app, excluded from
    /// backup by the stores (iOS Identity 1). Computed from Foundation's directory list without a
    /// file system call.
    static func storageRoot(fileManager: FileManager = .default) -> URL {
        let support =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return support.appendingPathComponent(rootDirectoryName, isDirectory: true)
    }

    static func make(bundle: Bundle, processFacts: IOSProcessFacts, storageRoot: URL? = nil) -> Platform {
        Platform(
            clock: SystemClock(), elapsedClock: UptimeClock(), random: SystemRandom(), scheduler: GCDScheduler(),
            networkMonitor: PathNetworkMonitor(), transportFactory: URLSessionTransport.factory,
            contextProvider: StaticContextProvider(), processFacts: processFacts,
            lifecycleSource: ApplicationLifecycleSource(), logger: OSLogSink.shared.rubiconLogger,
            storageRoot: storageRoot ?? Self.storageRoot(), fileSystem: PosixFileSystem())
    }
}

/// The wall clock (Event Model 5).
struct SystemClock: Clock {
    func now() -> Date { Date() }
}

/// Random bits for the id generator (iOS Event Model 3).
struct SystemRandom: RandomSource {
    func nextUInt64() -> UInt64 {
        var generator = SystemRandomNumberGenerator()
        return generator.next()
    }
}
