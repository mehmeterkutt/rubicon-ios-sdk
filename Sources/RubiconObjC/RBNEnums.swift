import Foundation
import Rubicon
import RubiconCore

/// The log levels (Logging 2), the mirror of `LogLevel`.
@objc public enum RBNLogLevel: Int, Sendable, CaseIterable {
    /// Everything, for development.
    case debug
    /// The SDK's milestones, such as the host it sends to.
    case info
    /// Something was dropped or replaced; the SDK carries on (the default).
    case warn
    /// The SDK could not do what was asked.
    case error
    /// Nothing is written.
    case off

    var swift: LogLevel {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warn: return .warn
        case .error: return .error
        case .off: return .off
        }
    }

    init(_ level: LogLevel) {
        switch level {
        case .debug: self = .debug
        case .info: self = .info
        case .warn: self = .warn
        case .error: self = .error
        case .off: self = .off
        }
    }
}

/// The automatic event types (Lifecycle 6), the mirror of `Autocapture`.
@objc public enum RBNAutocapture: Int, Sendable, CaseIterable {
    /// `Application Opened` and `Application Backgrounded`.
    case appLifecycle
    /// `Application Installed` and `Application Updated`.
    case installUpdate
    /// Session ids and `Session Started`.
    case sessions
    /// A screen view for each view controller that appears.
    case screenViews
    /// `Deep Link Opened` for the links you pass in; off by default.
    case deepLinks
    /// `Network Request` through `RBNNetworkObserver`.
    case networkRequests

    var swift: Autocapture {
        switch self {
        case .appLifecycle: return .appLifecycle
        case .installUpdate: return .installUpdate
        case .sessions: return .sessions
        case .screenViews: return .screenViews
        case .deepLinks: return .deepLinks
        case .networkRequests: return .networkRequests
        }
    }

    init(_ type: Autocapture) {
        switch type {
        case .appLifecycle: self = .appLifecycle
        case .installUpdate: self = .installUpdate
        case .sessions: self = .sessions
        case .screenViews: self = .screenViews
        case .deepLinks: self = .deepLinks
        case .networkRequests: self = .networkRequests
        }
    }
}

/// The context fields that can be switched off (Context 6), the mirror of `ContextField`.
@objc public enum RBNContextField: Int, Sendable, CaseIterable {
    /// `app.name`.
    case appName
    /// `app.version`.
    case appVersion
    /// `app.build`.
    case appBuild
    /// `app.namespace`, the bundle identifier.
    case appNamespace
    /// `device.manufacturer`, always Apple.
    case deviceManufacturer
    /// `device.model`, the hardware identifier.
    case deviceModel
    /// `device.type`, phone or tablet.
    case deviceType
    /// `device.is_emulator`, the simulator.
    case deviceIsEmulator
    /// `os.name`.
    case osName
    /// `os.version`.
    case osVersion
    /// `screen.width` in points.
    case screenWidth
    /// `screen.height` in points.
    case screenHeight
    /// `screen.density`, the scale factor.
    case screenDensity
    /// `network.type`: wifi, cellular, none or unknown.
    case networkType
    /// `locale`, language and region.
    case locale
    /// `timezone`, the identifier.
    case timezone

    var swift: ContextField {
        switch self {
        case .appName: return .appName
        case .appVersion: return .appVersion
        case .appBuild: return .appBuild
        case .appNamespace: return .appNamespace
        case .deviceManufacturer: return .deviceManufacturer
        case .deviceModel: return .deviceModel
        case .deviceType: return .deviceType
        case .deviceIsEmulator: return .deviceIsEmulator
        case .osName: return .osName
        case .osVersion: return .osVersion
        case .screenWidth: return .screenWidth
        case .screenHeight: return .screenHeight
        case .screenDensity: return .screenDensity
        case .networkType: return .networkType
        case .locale: return .locale
        case .timezone: return .timezone
        }
    }

    init(_ field: ContextField) {
        switch field {
        case .appName: self = .appName
        case .appVersion: self = .appVersion
        case .appBuild: self = .appBuild
        case .appNamespace: self = .appNamespace
        case .deviceManufacturer: self = .deviceManufacturer
        case .deviceModel: self = .deviceModel
        case .deviceType: self = .deviceType
        case .deviceIsEmulator: self = .deviceIsEmulator
        case .osName: self = .osName
        case .osVersion: self = .osVersion
        case .screenWidth: self = .screenWidth
        case .screenHeight: self = .screenHeight
        case .screenDensity: self = .screenDensity
        case .networkType: self = .networkType
        case .locale: self = .locale
        case .timezone: self = .timezone
        }
    }
}

/// The starting consent (Privacy 4), the mirror of `Consent`.
@objc public enum RBNConsent: Int, Sendable, CaseIterable {
    /// Collect from the first call.
    case granted
    /// Collect nothing until `optIn` is called.
    case pending

    var swift: Consent { self == .pending ? .pending : .granted }

    init(_ consent: Consent) { self = consent == .pending ? .pending : .granted }
}

/// Who created an event (Lifecycle 5), the mirror of `EventSource`.
@objc public enum RBNEventSource: Int, Sendable, CaseIterable {
    /// One of your calls.
    case app
    /// Captured by the SDK.
    case auto

    init(_ source: EventSource) { self = source == .auto ? .auto : .app }
}

/// Why an event was dropped (Queue 5), the mirror of `DropReason`.
@objc public enum RBNDropReason: Int, Sendable, CaseIterable {
    /// The queue was at its limit; the oldest events went.
    case queueFull
    /// Older than the retention window.
    case expired
    /// Too many events were pending in memory.
    case backpressure
    /// A `beforeSend` block returned `nil` or raised.
    case beforeSend
    /// The event could not be written.
    case storageError
    /// The stored event could not be read back.
    case corrupt
    /// Stored under another API key.
    case apiKeyChanged
    /// Larger than one event may be.
    case oversize
    /// The server refused the event for good.
    case rejected
    /// The server kept failing until the retry limit.
    case retryExhausted

    init(_ reason: DropReason) {
        switch reason {
        case .queueFull: self = .queueFull
        case .expired: self = .expired
        case .backpressure: self = .backpressure
        case .beforeSend: self = .beforeSend
        case .storageError: self = .storageError
        case .corrupt: self = .corrupt
        case .apiKeyChanged: self = .apiKeyChanged
        case .oversize: self = .oversize
        case .rejected: self = .rejected
        case .retryExhausted: self = .retryExhausted
        }
    }

    /// The wire name of the reason, such as `queue_full`; from Objective-C, read
    /// `RBNEventUpdate.dropReasonName`.
    public var name: String {
        switch self {
        case .queueFull: return DropReason.queueFull.rawValue
        case .expired: return DropReason.expired.rawValue
        case .backpressure: return DropReason.backpressure.rawValue
        case .beforeSend: return DropReason.beforeSend.rawValue
        case .storageError: return DropReason.storageError.rawValue
        case .corrupt: return DropReason.corrupt.rawValue
        case .apiKeyChanged: return DropReason.apiKeyChanged.rawValue
        case .oversize: return DropReason.oversize.rawValue
        case .rejected: return DropReason.rejected.rawValue
        case .retryExhausted: return DropReason.retryExhausted.rawValue
        }
    }
}

/// What became of events (Logging 4c), the mirror of the cases of `EventUpdate`.
@objc public enum RBNEventUpdateKind: Int, Sendable, CaseIterable {
    /// Stored on disk, with the event.
    case queued
    /// Accepted by the server, with the message ids.
    case sent
    /// Gone, with the message ids and the reason.
    case dropped
}
