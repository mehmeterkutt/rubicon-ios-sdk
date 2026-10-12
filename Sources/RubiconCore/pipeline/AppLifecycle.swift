import Foundation

/// The automatic app events (Lifecycle 1, 4, 6; iOS Lifecycle 4): `Application Installed` and
/// `Application Updated` on the first foreground of the process, `Application Opened` on every
/// foreground and `Application Backgrounded` on every background. It only decides; the writer
/// appends them. The platform reports the foreground and the file dates (step 7.4).
///
/// - A repeated signal (foreground while in the foreground) produces nothing, so the writer's startup
///   check and a replayed foreground do not open twice.
/// - The last seen version and build are written on the first foreground whatever the gates and the
///   consent say, so a later opt-in or a feature switched on later does not report a false update.
/// - Install against update without a record (iOS Lifecycle 4): the creation date of the `Library`
///   directory (`installTime`) and of the app bundle (`updateTime`) within 60 seconds of each other
///   is an install. The fallback for the day Apple does not confirm the bundle date under `C617.1`
///   compares `installTime` with now against a 24-hour threshold (`InstallRule.libraryDateOnly`).
///   When a needed date or the build cannot be read, nothing is written or produced and the check
///   runs again on the next first foreground.
///
/// Runs on the writer only.
package final class AppLifecycle {
    package struct AutoEvent: Sendable, Equatable {
        package let name: String
        package let properties: [String: PropertyValue]
    }

    /// How a first foreground without a version record tells an install from an update.
    package enum InstallRule: Sendable {
        /// `|installTime - updateTime| < 60 s` is an install; `updated_at` is the bundle date.
        case bundleDates
        /// `now - installTime < 24 h` is an install; `updated_at` is omitted.
        case libraryDateOnly
    }

    package static let installed = "Application Installed"
    package static let updated = "Application Updated"
    package static let opened = "Application Opened"
    package static let backgrounded = "Application Backgrounded"
    package static let fromBackground = "from_background"
    package static let version = "version"
    package static let build = "build"
    package static let previousVersion = "previous_version"
    package static let previousBuild = "previous_build"
    package static let installedAt = "installed_at"
    package static let updatedAt = "updated_at"
    package static let isDowngrade = "is_downgrade"

    /// iOS Lifecycle 4: the two dates of a fresh install are written seconds apart.
    package static let installWindowMillis: Int64 = 60_000
    /// The fallback threshold of iOS Lifecycle 4.
    package static let libraryDateWindowMillis: Int64 = 24 * 60 * 60 * 1000

    private let deviceStore: DeviceStore
    private let processFacts: any ProcessFacts
    private let clock: any Clock
    private let autocapture: Set<Autocapture>
    private let rule: InstallRule

    private var foreground = false
    private var openedBefore = false

    package init(
        deviceStore: DeviceStore, processFacts: any ProcessFacts, clock: any Clock, autocapture: Set<Autocapture>,
        rule: InstallRule = .bundleDates
    ) {
        self.deviceStore = deviceStore
        self.processFacts = processFacts
        self.clock = clock
        self.autocapture = autocapture
        self.rule = rule
    }

    /// The events of coming to the foreground, oldest first; `nil` when already in the foreground.
    package func onForeground() -> [AutoEvent]? {
        if foreground { return nil }
        foreground = true
        let first = !openedBefore
        openedBefore = true
        var events: [AutoEvent] = []
        if first, let event = checkInstall(), autocapture.contains(.installUpdate) { events.append(event) }
        if autocapture.contains(.appLifecycle) {
            events.append(AutoEvent(name: Self.opened, properties: [Self.fromBackground: .bool(!first)]))
        }
        return events
    }

    /// The events of going to the background; `nil` when not in the foreground.
    package func onBackground() -> [AutoEvent]? {
        if !foreground { return nil }
        foreground = false
        return autocapture.contains(.appLifecycle) ? [AutoEvent(name: Self.backgrounded, properties: [:])] : []
    }

    // Lifecycle 4: the install times tell a fresh install from an app that just added the SDK.
    private func checkInstall() -> AutoEvent? {
        guard let app = processFacts.installedApp(), let build = app.build, let installTime = app.installTime else {
            return nil
        }
        let updateTime: Date?
        let freshInstall: Bool
        switch rule {
        case .bundleDates:
            guard let bundleDate = app.updateTime else { return nil }
            updateTime = bundleDate
            freshInstall = abs(bundleDate.epochMillis - installTime.epochMillis) < Self.installWindowMillis
        case .libraryDateOnly:
            updateTime = nil
            freshInstall = clock.now().epochMillis - installTime.epochMillis < Self.libraryDateWindowMillis
        }
        let state = deviceStore.state
        let event: AutoEvent?
        if state?.lastBuild == nil && freshInstall {
            event = installedEvent(app, installTime: installTime)
        } else if state?.lastBuild == nil {
            event = updatedEvent(app, updateTime: updateTime, previousVersion: nil, previousBuild: nil)
        } else if state?.lastBuild != build {
            event = updatedEvent(
                app, updateTime: updateTime, previousVersion: state?.lastVersion, previousBuild: state?.lastBuild)
        } else {
            event = nil
        }
        deviceStore.update {
            with($0) {
                $0.lastVersion = app.version
                $0.lastBuild = build
            }
        }
        return event
    }

    private func installedEvent(_ app: InstalledApp, installTime: Date) -> AutoEvent {
        AutoEvent(
            name: Self.installed,
            properties: known([
                (Self.version, app.version.map(PropertyValue.string)),
                (Self.build, app.build.map(PropertyValue.string)),
                (Self.installedAt, IsoDates.format(installTime).map(PropertyValue.string)),
            ]))
    }

    private func updatedEvent(
        _ app: InstalledApp, updateTime: Date?, previousVersion: String?, previousBuild: String?
    ) -> AutoEvent {
        let downgrade = isLower(app.build, than: previousBuild)
        return AutoEvent(
            name: Self.updated,
            properties: known([
                (Self.version, app.version.map(PropertyValue.string)),
                (Self.build, app.build.map(PropertyValue.string)),
                (Self.previousVersion, previousVersion.map(PropertyValue.string)),
                (Self.previousBuild, previousBuild.map(PropertyValue.string)),
                (Self.updatedAt, updateTime.flatMap(IsoDates.format).map(PropertyValue.string)),
                (Self.isDowngrade, downgrade ? .bool(true) : nil),
            ]))
    }

    // Properties that are not known are left out, not sent as null.
    private func known(_ entries: [(String, PropertyValue?)]) -> [String: PropertyValue] {
        var properties: [String: PropertyValue] = [:]
        for (key, value) in entries {
            if let value { properties[key] = value }
        }
        return properties
    }

    private func isLower(_ build: String?, than previous: String?) -> Bool {
        guard let build, let now = Int64(build), let previous, let before = Int64(previous) else { return false }
        return now < before
    }
}
