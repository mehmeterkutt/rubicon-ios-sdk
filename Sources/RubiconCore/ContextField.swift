/// A field of the event `context` that `context.disabledFields` can switch off (Context 6). A
/// disabled field is never read, not merely left out. The `library` fields cannot be disabled.
///
/// iOS has sixteen fields: `os.api_level` does not exist on iOS and `network.carrier` is not
/// collected, so neither has a case (iOS Context 1).
///
/// ```swift
/// config.context.disabledFields = [.locale, .timezone]
/// ```
public enum ContextField: String, Sendable, CaseIterable {
    /// `context.app.name`.
    case appName = "app.name"
    /// `context.app.version`.
    case appVersion = "app.version"
    /// `context.app.build`.
    case appBuild = "app.build"
    /// `context.app.namespace`.
    case appNamespace = "app.namespace"
    /// `context.device.manufacturer`.
    case deviceManufacturer = "device.manufacturer"
    /// `context.device.model`.
    case deviceModel = "device.model"
    /// `context.device.type`.
    case deviceType = "device.type"
    /// `context.device.is_emulator`.
    case deviceIsEmulator = "device.is_emulator"
    /// `context.os.name`.
    case osName = "os.name"
    /// `context.os.version`.
    case osVersion = "os.version"
    /// `context.screen.width`.
    case screenWidth = "screen.width"
    /// `context.screen.height`.
    case screenHeight = "screen.height"
    /// `context.screen.density`.
    case screenDensity = "screen.density"
    /// `context.network.type`.
    case networkType = "network.type"
    /// `context.locale`.
    case locale
    /// `context.timezone`.
    case timezone
}
