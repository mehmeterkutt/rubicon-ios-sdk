import Foundation
// Apps `import Rubicon` and see the core's public types through this re-export (D2).
@_exported import RubiconCore

/// Creates the SDK's instance (Public API 1, 2; iOS Public API 4). Call it once, in your app
/// delegate's `didFinishLaunching` or at the start of your SwiftUI `App`, on the main thread, and
/// hold the result; a second call returns the first instance and is a developer error when `debug`
/// is on.
///
/// ```swift
/// let analytics = RubiconAnalytics.make(configuration: AnalyticsConfiguration(apiKey: "api-key"))
/// analytics.track("Purchase Completed", properties: ["amount": 49.90])
/// ```
///
/// - It reads nothing from disk, so it is safe on the main thread; the SDK loads its files on its
///   own queue (Privacy 2).
/// - Inside an app extension it returns an instance that does nothing (iOS Queue 2).
/// - With an unusable configuration (a blank key, an invalid host) it returns an instance that does
///   nothing and logs an ERROR, or reports a developer error when `debug` is on (Configuration 3).
public enum RubiconAnalytics {
    /// The SDK's version, as sent in `context.library.version` and the User-Agent.
    public static var version: String { SDKVersion.current }

    /// Creates the instance for this process; see the type's documentation.
    public static func make(configuration: AnalyticsConfiguration) -> any Analytics {
        make(configuration: configuration, bundle: .main)
    }

    /// The factory with its inputs exposed, for tests: an `.appex` bundle, a temporary storage root.
    package static func make(configuration: AnalyticsConfiguration, bundle: Bundle, storageRoot: URL? = nil)
        -> any Analytics
    {
        let processFacts = IOSProcessFacts(bundle: bundle)
        if processFacts.isAppExtension {
            factoryLog(configuration).info { "Running inside an app extension; analytics does nothing in this process" }
            return NoOpAnalytics()
        }
        let platform = IOSPlatform.make(bundle: bundle, processFacts: processFacts, storageRoot: storageRoot)
        return RubiconCore.create(configuration: configuration, platform: platform) { _ in
            // On the main thread when called from launch (iOS Session 1); otherwise posted there.
            (platform.lifecycleSource as? ApplicationLifecycleSource)?.attach()
            (platform.contextProvider as? IOSContextProvider)?.attach()
        }
    }

    /// Stops and forgets the instance; for tests that create one per test.
    package static func resetForTests() {
        RubiconCore.resetForTests()
    }

    // The core builds the instance's log; this one only reports what the factory decides before that.
    private static func factoryLog(_ configuration: AnalyticsConfiguration) -> Log {
        Log(
            level: configuration.logging.level, logger: configuration.logging.logger,
            platformLogger: OSLogSink.shared.rubiconLogger)
    }
}
