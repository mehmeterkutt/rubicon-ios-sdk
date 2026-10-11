import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("Fake clocks and random")
struct FakeClocksTests {
    @Test("the wall clock moves only when told, in both directions")
    func wallClock() {
        let clock = TestClock(start: Date(epochMillis: 1_000))

        #expect(clock.now().epochMillis == 1_000)
        clock.advance(byMillis: 500)
        #expect(clock.now().epochMillis == 1_500)
        clock.advance(byMillis: -2_000)
        #expect(clock.now().epochMillis == -500)
        clock.set(Date(epochMillis: 42))
        #expect(clock.now().epochMillis == 42)
    }

    @Test("the default starts are fixed instants")
    func defaults() {
        #expect(TestClock().now() == TestClock.defaultStart)
        #expect(TestClock.defaultStart.epochMillis == 1_759_147_200_000)
        #expect(TestElapsedClock().elapsedMillis() == TestElapsedClock.defaultStart)
    }

    @Test("the elapsed clock moves forward")
    func elapsed() {
        let clock = TestElapsedClock(start: 10)
        clock.advance(byMillis: 5)
        #expect(clock.elapsedMillis() == 15)
    }

    @Test("the same seed gives the same sequence, another seed another")
    func seeded() {
        let a = SeededRandom(seed: 7)
        let b = SeededRandom(seed: 7)
        #expect((0..<5).map { _ in a.nextUInt64() } == (0..<5).map { _ in b.nextUInt64() })
        #expect(SeededRandom(seed: 7).nextUInt64() != SeededRandom(seed: 8).nextUInt64())
        #expect(a.seed == 7)
    }

    @Test("the scripted source returns its values in order, then zero")
    func scripted() {
        let random = ScriptedRandom([3, 2])
        #expect([random.nextUInt64(), random.nextUInt64(), random.nextUInt64()] == [3, 2, 0])
    }

    @Test("epoch milliseconds round-trip through Date")
    func epochMillis() {
        #expect(Date(epochMillis: 1_759_147_200_123).epochMillis == 1_759_147_200_123)
        #expect(Date(timeIntervalSince1970: 0.0016).epochMillis == 2)
    }
}

@Suite("Fake network monitor and lifecycle")
struct FakeSignalsTests {
    @Test("network listeners hear only changes, until removed")
    func network() {
        let monitor = FakeNetworkMonitor(connected: true)
        let heard = Locked<[Bool]>([])
        let token = monitor.addListener { value in heard.withLock { $0.append(value) } }
        monitor.start()

        monitor.setConnected(true)
        monitor.setConnected(false)
        monitor.setConnected(false)
        monitor.setConnected(true)
        token.cancel()
        monitor.setConnected(false)

        #expect(heard.current == [false, true])
        #expect(!monitor.isConnected)
        #expect(monitor.starts == 1)
    }

    @Test("lifecycle listeners hear only changes, plus replays and termination")
    func lifecycle() {
        let source = FakeLifecycleSource()
        let heard = Locked<[LifecycleEvent]>([])
        let token = source.addListener { event in heard.withLock { $0.append(event) } }

        source.moveToBackground()
        source.moveToForeground()
        source.moveToForeground()
        source.replayForeground()
        source.moveToBackground()
        source.lockProtectedData()
        source.lockProtectedData()
        source.unlockProtectedData()
        source.terminate()
        token.cancel()
        source.moveToForeground()

        #expect(
            heard.current == [
                .foreground, .foreground, .background, .protectedDataWillBecomeUnavailable,
                .protectedDataDidBecomeAvailable, .willTerminate,
            ])
        #expect(source.isForeground)
        #expect(source.isProtectedDataAvailable)
    }
}

@Suite("Fake context provider, process facts and TestPlatform")
struct FakeEnvironmentTests {
    @Test("the context provider returns what the test set, leaves out disabled fields and counts reads")
    func contextProvider() {
        let provider = FakeContextProvider(staticValues: StaticValues(deviceModel: "iPhone16,2", osName: "iOS"))
        provider.callTimeValues = CallTimeValues(networkType: "wifi", timezone: "Europe/Istanbul")

        let statics = provider.staticValues(disabled: [.deviceModel])
        let callTime = provider.callTimeValues(disabled: [.networkType])
        _ = provider.callTimeValues(disabled: [])

        #expect(statics.osName == "iOS")
        #expect(statics.deviceModel == nil)
        #expect(callTime.timezone == "Europe/Istanbul")
        #expect(callTime.networkType == nil)
        #expect(provider.lastDisabled.isEmpty)
        #expect(provider.staticReads == 1)
        #expect(provider.callTimeReads == 2)
    }

    @Test("call-time values are pending until the first refresh when asked")
    func pending() {
        let provider = FakeContextProvider(callTimeValues: CallTimeValues(locale: "tr-TR"), pendingUntilRefresh: true)

        #expect(provider.callTimeValues(disabled: []).pending)
        provider.refresh(disabled: [.locale])
        let values = provider.callTimeValues(disabled: [])

        #expect(!values.pending)
        #expect(values.locale == "tr-TR")
        #expect(provider.refreshes == 1)
    }

    @Test("process facts report what the test set")
    func processFacts() {
        let facts = FakeProcessFacts(osVersion: "15.0", isAppExtension: true)
        #expect(facts.osVersion == "15.0")
        #expect(facts.isAppExtension)
        #expect(facts.installedApp() == nil)
        let app = InstalledApp(version: "1.4.0", build: "140", installTime: Date(epochMillis: 1), updateTime: nil)
        facts.installed = app
        #expect(facts.installedApp() == app)
    }

    @Test("ContextField has the sixteen iOS fields with their wire names")
    func contextFields() {
        #expect(ContextField.allCases.count == 16)
        #expect(ContextField.networkType.rawValue == "network.type")
        #expect(ContextField(rawValue: "os.api_level") == nil)
        #expect(ContextField(rawValue: "network.carrier") == nil)
    }

    @Test("TestPlatform wires its fakes into the platform and owns a fresh directory")
    func testPlatform() {
        let test = TestPlatform()
        defer { test.cleanUp() }
        let platform = test.platform

        #expect(platform.clock as AnyObject === test.clock)
        #expect(platform.elapsedClock as AnyObject === test.elapsedClock)
        #expect(platform.scheduler as AnyObject === test.scheduler)
        #expect(platform.networkMonitor === test.networkMonitor)
        #expect(platform.lifecycleSource === test.lifecycleSource)
        #expect(platform.contextProvider as AnyObject === test.contextProvider)
        #expect(platform.processFacts as AnyObject === test.processFacts)
        #expect(platform.fileSystem as AnyObject === test.fileSystem)
        let transport = platform.transportFactory(TransportSettings(apiKey: "k"), platform)
        #expect(transport as AnyObject === test.transport)
        #expect(platform.storageRoot == test.storageRoot)
        #expect(FileManager.default.fileExists(atPath: test.storageRoot.path))
        #expect(test.storageRoot != TestPlatform().storageRoot)
    }

    @Test("a part can be replaced")
    func replacePart() {
        let clock = TestClock(start: Date(epochMillis: 0))
        let test = TestPlatform(clock: clock)
        defer { test.cleanUp() }
        #expect(test.platform.clock.now().epochMillis == 0)
    }
}
