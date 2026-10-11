import Foundation

/// Facts about the running process and operating system (HTTP 5, iOS Queue 2, iOS Lifecycle 4).
/// Named `ProcessFacts` because Foundation already owns `ProcessInfo`.
package protocol ProcessFacts: Sendable {
    /// Operating system version for the User-Agent, for example `17.5.1`.
    var osVersion: String { get }

    /// `true` inside an app extension, where the SDK is a no-op (iOS Queue 2).
    var isAppExtension: Bool { get }

    /// The installed app, for install and update detection, read on the writer at the first
    /// foreground; `nil` when it cannot be read.
    func installedApp() -> InstalledApp?
}

/// The app's version and the two file dates of iOS Lifecycle 4; a date is `nil` when it could not be
/// read, in which case no install or update event is produced.
package struct InstalledApp: Sendable, Equatable {
    package var version: String?
    /// `CFBundleVersion`, like `context.app.build`.
    package var build: String?
    /// Creation date of the `Library` directory, kept across updates.
    package var installTime: Date?
    /// Creation date of the app bundle, replaced on every update.
    package var updateTime: Date?

    package init(version: String?, build: String?, installTime: Date?, updateTime: Date?) {
        self.version = version
        self.build = build
        self.installTime = installTime
        self.updateTime = updateTime
    }
}
