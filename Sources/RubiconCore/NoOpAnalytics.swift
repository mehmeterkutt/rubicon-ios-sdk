import Foundation

/// The instance the factory returns when the SDK must not run: an unusable configuration in release
/// (Configuration 3) or an app extension (iOS Queue 2). It accepts every call, touches no disk or
/// network and never traps. `isOptedOut` is `true`, since nothing is sent, and `deviceId` is empty,
/// since there is no installation id to report (Android log 3.3).
package struct NoOpAnalytics: Analytics, CustomStringConvertible {
    package init() {}

    package func track(_ name: String, properties: [String: Any]) {}
    package func screen(_ name: String, properties: [String: Any]) {}
    package func identify(_ userId: String, traits: [String: Any]) {}
    package func reset() {}
    package func register(_ key: String, value: Any) {}
    package func unregister(_ key: String) {}
    package func flush() {}
    package func optOut() {}
    package func optIn() {}
    package var isOptedOut: Bool { true }
    package func clearLocalData() {}
    package var deviceId: String { "" }
    package func trackDeepLink(_ url: URL, referrer: String?) {}
    package func trackDeepLink(_ activity: NSUserActivity) {}

    package var description: String { "NoOpAnalytics" }
}
