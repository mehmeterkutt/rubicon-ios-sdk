import Foundation

/// Supplies the `context` of events (Context 1, 2), implemented in the `Rubicon` target. Nothing is
/// read on the main thread, and a field in `disabled` is never read, not merely left out (Context 6).
/// A value that cannot be read is `nil` and is omitted from the event (Context 3).
package protocol ContextProvider: Sendable {
    /// App, device, OS and screen values; collected once on the worker, on first need (iOS Context 2
    /// moves `screen` into the static group).
    func staticValues(disabled: Set<ContextField>) -> StaticValues

    /// Network, locale and timezone, read on the calling thread at call time (iOS Context 2). Must
    /// be cheap and must not block.
    func callTimeValues(disabled: Set<ContextField>) -> CallTimeValues

    /// Brings the call-time cache up to date; called on the writer at startup, before the first
    /// event, and before each message. Must not throw.
    func refresh(disabled: Set<ContextField>)
}

/// The values that do not change during a process (Context 2, 3; iOS Context 1).
package struct StaticValues: Sendable, Equatable {
    package var appName: String?
    package var appVersion: String?
    package var appBuild: String?
    package var appNamespace: String?
    package var deviceManufacturer: String?
    package var deviceModel: String?
    /// `phone`, `tablet` or `tv`.
    package var deviceType: String?
    package var deviceIsEmulator: Bool?
    package var osName: String?
    package var osVersion: String?
    package var screenWidth: Int?
    package var screenHeight: Int?
    package var screenDensity: Double?

    package init(
        appName: String? = nil, appVersion: String? = nil, appBuild: String? = nil,
        appNamespace: String? = nil, deviceManufacturer: String? = nil, deviceModel: String? = nil,
        deviceType: String? = nil, deviceIsEmulator: Bool? = nil, osName: String? = nil,
        osVersion: String? = nil, screenWidth: Int? = nil, screenHeight: Int? = nil,
        screenDensity: Double? = nil
    ) {
        self.appName = appName
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.appNamespace = appNamespace
        self.deviceManufacturer = deviceManufacturer
        self.deviceModel = deviceModel
        self.deviceType = deviceType
        self.deviceIsEmulator = deviceIsEmulator
        self.osName = osName
        self.osVersion = osVersion
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.screenDensity = screenDensity
    }

    package static let none = StaticValues()
}

/// The values captured when an event is created (Context 2, 3; iOS Context 2).
package struct CallTimeValues: Sendable, Equatable {
    /// `wifi`, `cellular` or `ethernet`; omitted when unknown.
    package var networkType: String?
    /// A BCP 47 tag such as `tr-TR`.
    package var locale: String?
    /// An IANA zone such as `Europe/Istanbul`.
    package var timezone: String?
    /// The cache was not ready at call time (before the writer's first refresh): the writer fills
    /// the values when it processes the event, from the cache then, a few milliseconds later.
    package var pending: Bool

    package init(
        networkType: String? = nil, locale: String? = nil, timezone: String? = nil,
        pending: Bool = false
    ) {
        self.networkType = networkType
        self.locale = locale
        self.timezone = timezone
        self.pending = pending
    }

    package static let none = CallTimeValues()
}
