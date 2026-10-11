import Foundation

/// What the SDK measured when an event was created (Event Model 1, Context 3 and 4; iOS Context
/// 1). Hooks can read it, for example to drop events from the simulator, but never change it; a
/// field that must not be sent is switched off with `context.disabledFields`. A value that could
/// not be read, or was switched off, is `nil` and is not sent.
///
/// ```swift
/// config.beforeSend = [{ event in event.context.device.isEmulator == true ? nil : event }]
/// ```
public struct EventContext: Sendable, Equatable {
    /// The app that sent the event.
    public let app: AppContext
    /// The device.
    public let device: DeviceContext
    /// The operating system.
    public let os: OsContext
    /// The display.
    public let screen: ScreenContext
    /// The network at the time of the event.
    public let network: NetworkContext
    /// The app's language and the device region, such as `tr-TR`.
    public let locale: String?
    /// The device time zone, such as `Europe/Istanbul`.
    public let timezone: String?
    /// The session the event belongs to; `nil` when there is none, such as in the background.
    public let session: SessionContext?
    /// This SDK; always present.
    public let library: LibraryContext

    package init(
        app: AppContext, device: DeviceContext, os: OsContext, screen: ScreenContext, network: NetworkContext,
        locale: String?, timezone: String?, session: SessionContext?, library: LibraryContext
    ) {
        self.app = app
        self.device = device
        self.os = os
        self.screen = screen
        self.network = network
        self.locale = locale
        self.timezone = timezone
        self.session = session
        self.library = library
    }
}

extension EventContext: CustomStringConvertible {
    /// The library only: never measured values.
    public var description: String { "EventContext(library: \(library.name) \(library.version))" }
}

/// The app that sent the event.
public struct AppContext: Sendable, Equatable {
    /// The app's name, such as `Rubicon`.
    public let name: String?
    /// The version users see, such as `1.4.0`.
    public let version: String?
    /// The build number, such as `140`.
    public let build: String?
    /// The bundle identifier, such as `com.rubicon.demo`.
    public let namespace: String?

    package init(name: String?, version: String?, build: String?, namespace: String?) {
        self.name = name
        self.version = version
        self.build = build
        self.namespace = namespace
    }
}

/// The device.
public struct DeviceContext: Sendable, Equatable {
    /// `Apple`.
    public let manufacturer: String?
    /// The machine identifier, such as `iPhone16,2`.
    public let model: String?
    /// `phone`, `tablet` or `tv`.
    public let type: String?
    /// Whether the app runs in the simulator.
    public let isEmulator: Bool?

    package init(manufacturer: String?, model: String?, type: String?, isEmulator: Bool?) {
        self.manufacturer = manufacturer
        self.model = model
        self.type = type
        self.isEmulator = isEmulator
    }
}

/// The operating system. iOS has no API level (iOS Context 1).
public struct OsContext: Sendable, Equatable {
    /// `iOS`.
    public let name: String?
    /// The version users see, such as `17.5.1`.
    public let version: String?

    package init(name: String?, version: String?) {
        self.name = name
        self.version = version
    }
}

/// The display.
public struct ScreenContext: Sendable, Equatable {
    /// In pixels, the short side.
    public let width: Int?
    /// In pixels, the long side.
    public let height: Int?
    /// Pixels per point, such as `3.0`.
    public let density: Double?

    package init(width: Int?, height: Int?, density: Double?) {
        self.width = width
        self.height = height
        self.density = density
    }
}

/// The network when the event was created. iOS does not collect the carrier (iOS Context 1).
public struct NetworkContext: Sendable, Equatable {
    /// `wifi`, `cellular` or `ethernet`.
    public let type: String?

    package init(type: String?) {
        self.type = type
    }
}

/// The session an event belongs to (Session 2).
public struct SessionContext: Sendable, Equatable {
    /// A UUIDv7.
    public let id: String
    /// When the session started.
    public let startedAt: Date

    package init(id: String, startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }
}

/// The SDK that sent the event; always present.
public struct LibraryContext: Sendable, Equatable {
    /// `rubicon-ios`.
    public let name: String
    /// The SDK version, such as `0.1.0`.
    public let version: String

    package init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}
