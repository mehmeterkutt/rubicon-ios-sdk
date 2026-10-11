import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The port of the Android `AppLifecycleTest` (Lifecycle 1, 4 and 6) with the iOS install rule of
/// iOS Lifecycle 4; the Android test names are kept.
@Suite("AppLifecycle")
struct AppLifecycleTests {
    // 2025-09-29T11:56:40Z
    static let installTime = Date(epochMillis: 1_759_147_000_000)

    let support = StoreTestSupport()
    let clock = TestClock(start: Date(epochMillis: 1_759_147_000_000))
    let processFacts = FakeProcessFacts()

    func deviceStore() -> DeviceStore {
        let store = DeviceStore(
            keyValueStore: support.files, log: support.log, clock: clock, newDeviceId: support.newDeviceId)
        store.load()
        return store
    }

    func lifecycle(
        store: DeviceStore? = nil, autocapture: Set<Autocapture> = Set(Autocapture.allCases),
        rule: AppLifecycle.InstallRule = .bundleDates
    ) -> AppLifecycle {
        AppLifecycle(
            deviceStore: store ?? deviceStore(), processFacts: processFacts, clock: clock, autocapture: autocapture,
            rule: rule)
    }

    func app(_ version: String?, _ build: String?, installed: Date = installTime, updated: Date? = nil) -> InstalledApp
    {
        InstalledApp(version: version, build: build, installTime: installed, updateTime: updated ?? installed)
    }

    func record(_ version: String?, _ build: String?) {
        let store = deviceStore()
        store.update {
            with($0) {
                $0.lastVersion = version
                $0.lastBuild = build
            }
        }
        store.persist()
    }

    func firstForeground(store: DeviceStore? = nil, rule: AppLifecycle.InstallRule = .bundleDates) throws
        -> AppLifecycle.AutoEvent
    {
        try #require(lifecycle(store: store, rule: rule).onForeground()?.first)
    }

    func later(_ seconds: TimeInterval) -> Date { Self.installTime.addingTimeInterval(seconds) }

    // MARK: install and update

    @Test("first launch reports an install with the install time")
    func firstLaunch() throws {
        processFacts.installed = app("1.4.0", "140")
        let store = deviceStore()

        let event = try firstForeground(store: store)

        #expect(event.name == AppLifecycle.installed)
        #expect(
            event.properties == [
                "version": .string("1.4.0"), "build": .string("140"),
                "installed_at": .string("2025-09-29T11:56:40.000Z"),
            ])
        #expect(store.state?.lastVersion == "1.4.0")
        #expect(store.state?.lastBuild == "140")
    }

    @Test("two dates within 60 seconds are still an install")
    func withinWindow() throws {
        processFacts.installed = app("1.4.0", "140", updated: later(59))
        #expect(try firstForeground().name == AppLifecycle.installed)
    }

    @Test("no record and differing install times is an update with no previous version")
    func noRecordUpdate() throws {
        processFacts.installed = app("2.0.0", "200", updated: later(86_400))

        let event = try firstForeground()

        #expect(event.name == AppLifecycle.updated)
        #expect(
            event.properties == [
                "version": .string("2.0.0"), "build": .string("200"), "updated_at": .string("2025-09-30T11:56:40.000Z"),
            ])
    }

    @Test("a different build is an update with the previous version")
    func differentBuild() throws {
        record("1.4.0", "140")
        processFacts.installed = app("1.5.0", "150", updated: later(1))

        let event = try firstForeground()

        #expect(event.name == AppLifecycle.updated)
        #expect(event.properties["previous_version"] == .string("1.4.0"))
        #expect(event.properties["previous_build"] == .string("140"))
        #expect(event.properties["is_downgrade"] == nil)
    }

    @Test("a lower build is a downgrade")
    func downgrade() throws {
        record("1.5.0", "150")
        processFacts.installed = app("1.4.0", "140", updated: later(1))

        let event = try firstForeground()

        #expect(event.name == AppLifecycle.updated)
        #expect(event.properties["is_downgrade"] == .bool(true))
    }

    @Test("the same build reports nothing, only the open")
    func sameBuild() {
        record("1.4.0", "140")
        processFacts.installed = app("1.4.0", "140", updated: later(1))

        #expect(lifecycle().onForeground()?.map(\.name) == [AppLifecycle.opened])
    }

    @Test("a reinstall after the data was removed is a fresh install")
    func reinstall() throws {
        record("1.4.0", "140")
        _ = support.files.delete(DeviceStore.fileName)
        processFacts.installed = app("1.4.0", "140", installed: later(1_000))

        #expect(try firstForeground().name == AppLifecycle.installed)
    }

    @Test("only the first foreground of the process checks")
    func onlyFirst() {
        processFacts.installed = app("1.4.0", "140")
        let lifecycle = lifecycle()
        _ = lifecycle.onForeground()
        _ = lifecycle.onBackground()
        processFacts.installed = app("1.5.0", "150", updated: later(1))

        #expect(lifecycle.onForeground()?.map(\.name) == [AppLifecycle.opened])
    }

    @Test("with the gate off nothing is reported but the record is still written")
    func gateOff() {
        processFacts.installed = app("1.4.0", "140")
        let store = deviceStore()

        let events = lifecycle(store: store, autocapture: [.appLifecycle]).onForeground()

        #expect(events?.map(\.name) == [AppLifecycle.opened])
        #expect(store.state?.lastBuild == "140")
    }

    @Test("an unreadable package reports nothing and writes nothing")
    func unreadablePackage() {
        processFacts.installed = nil
        let store = deviceStore()

        #expect(lifecycle(store: store).onForeground()?.map(\.name) == [AppLifecycle.opened])
        #expect(store.state?.lastBuild == nil)
    }

    @Test("a missing file date reports nothing, writes nothing, and the next first foreground checks again")
    func missingDate() {
        processFacts.installed = InstalledApp(
            version: "1.4.0", build: "140", installTime: Self.installTime, updateTime: nil)
        let store = deviceStore()

        #expect(lifecycle(store: store).onForeground()?.map(\.name) == [AppLifecycle.opened])
        #expect(store.state?.lastBuild == nil)

        processFacts.installed = app("1.4.0", "140")
        #expect(lifecycle(store: store).onForeground()?.map(\.name) == [AppLifecycle.installed, AppLifecycle.opened])
    }

    @Test("the Library-date fallback tells an install by age and omits updated_at")
    func libraryDateFallback() throws {
        processFacts.installed = InstalledApp(
            version: "1.4.0", build: "140", installTime: Self.installTime, updateTime: nil)
        clock.set(later(3_600))
        #expect(try firstForeground(rule: .libraryDateOnly).name == AppLifecycle.installed)

        processFacts.installed = InstalledApp(
            version: "2.0.0", build: "200", installTime: Self.installTime, updateTime: nil)
        clock.set(later(86_400))
        let update = try firstForeground(rule: .libraryDateOnly)
        #expect(update.name == AppLifecycle.updated)
        #expect(update.properties["updated_at"] == nil)
    }

    // MARK: open and background

    @Test("the first open is not from the background, later ones are")
    func fromBackground() throws {
        let lifecycle = lifecycle(autocapture: [.appLifecycle])

        let first = try #require(lifecycle.onForeground()?.first)
        let background = try #require(lifecycle.onBackground()?.first)
        let second = try #require(lifecycle.onForeground()?.first)

        #expect(first.properties == ["from_background": .bool(false)])
        #expect(background.name == AppLifecycle.backgrounded)
        #expect(background.properties == [:])
        #expect(second.properties == ["from_background": .bool(true)])
    }

    @Test("a repeated signal produces nothing")
    func repeatedSignal() {
        let lifecycle = lifecycle()

        #expect(lifecycle.onBackground() == nil)
        _ = lifecycle.onForeground()
        #expect(lifecycle.onForeground() == nil)
    }

    @Test("with appLifecycle off the transitions are still followed, without events")
    func appLifecycleOff() {
        let lifecycle = lifecycle(autocapture: [])

        #expect(lifecycle.onForeground() == [])
        #expect(lifecycle.onBackground() == [])
        #expect(lifecycle.onBackground() == nil)
    }
}
