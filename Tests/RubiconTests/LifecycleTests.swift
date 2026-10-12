import Foundation
import RubiconTesting
import Testing

@testable import Rubicon
@testable import RubiconCore

#if canImport(UIKit)
    import UIKit
#endif

/// The lifecycle source, the background task and install detection (step 7.4).
@Suite("Lifecycle")
struct LifecycleTests {
    #if canImport(UIKit)
        @Test("the foreground pair produces the decided events once per change; the active pair is ignored")
        @MainActor
        func foregroundPair() {
            let center = NotificationCenter()
            let source = ApplicationLifecycleSource(center: center)
            source.attach()
            let events = Locked<[LifecycleEvent]>([])
            _ = source.addListener { event in events.withLock { $0.append(event) } }
            let wasForeground = source.isForeground
            if wasForeground { center.post(name: UIApplication.didEnterBackgroundNotification, object: nil) }
            events.withLock { $0 = [] }

            center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
            center.post(name: UIApplication.willResignActiveNotification, object: nil)
            center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            center.post(name: UIApplication.willEnterForegroundNotification, object: nil)

            #expect(events.current == [.foreground, .background, .foreground])
            #expect(source.isForeground)
        }

        @Test("the startup state: active and inactive are the foreground, background waits")
        func startupState() {
            #expect(ApplicationLifecycleSource.isForeground(.active))
            #expect(ApplicationLifecycleSource.isForeground(.inactive))
            #expect(!ApplicationLifecycleSource.isForeground(.background))
        }

        @Test("attach on the main thread reports the host's state at once, matching applicationState")
        @MainActor
        func attachReadsState() {
            let source = ApplicationLifecycleSource(center: NotificationCenter())
            source.attach()
            #expect(
                source.isForeground == ApplicationLifecycleSource.isForeground(UIApplication.shared.applicationState))
        }
    #endif

    @Test("off the main thread the app is assumed to be in the background until a notification arrives")
    func offMainAssumesBackground() async {
        let source = ApplicationLifecycleSource(center: NotificationCenter())
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                #expect(!source.isForeground)
                continuation.resume()
            }
        }
    }

    // MARK: the background task

    final class FakeRunner: BackgroundTaskRunner, @unchecked Sendable {
        let begun = Locked<[String]>([])
        let ended = Locked<[Int]>([])
        let expire = Locked<(@Sendable () -> Void)?>(nil)
        let refuse = Locked(false)

        func begin(name: String, onExpire: @escaping @Sendable () -> Void) -> BackgroundTaskHandle? {
            if refuse.current { return nil }
            let id: Int = begun.withLock {
                $0.append(name)
                return $0.count
            }
            expire.withLock { $0 = onExpire }
            return BackgroundTaskHandle(id: id)
        }

        func end(_ handle: BackgroundTaskHandle) {
            ended.withLock { $0.append(handle.id) }
        }
    }

    final class FakeControl: BackgroundFlushControl, @unchecked Sendable {
        let done = Locked<(@Sendable () -> Void)?>(nil)
        let begins = Locked(0)
        let expirations = Locked(0)

        func beginBackgroundFlush(onDone: @escaping @Sendable () -> Void) {
            begins.withLock { $0 += 1 }
            done.withLock { $0 = onDone }
        }

        func expireBackgroundFlush() {
            expirations.withLock { $0 += 1 }
        }
    }

    @Test("backgrounding begins the task and the uploader's done ends it")
    func beginAndEnd() {
        let lifecycle = FakeLifecycleSource(foreground: true)
        let runner = FakeRunner()
        let control = FakeControl()
        let coordinator = BackgroundFlushCoordinator(control: control, lifecycle: lifecycle, runner: runner)
        coordinator.attach()

        lifecycle.moveToBackground()

        #expect(runner.begun.current == ["rubicon.flush"])
        #expect(control.begins.current == 1)
        #expect(coordinator.isTaskOpen)
        control.done.current?()
        #expect(runner.ended.current == [1])
        #expect(!coordinator.isTaskOpen)
        control.done.current?()
        #expect(runner.ended.current == [1])
    }

    @Test("expiration cancels the request in flight and ends the task; a late done ends nothing twice")
    func expiration() {
        let lifecycle = FakeLifecycleSource(foreground: true)
        let runner = FakeRunner()
        let control = FakeControl()
        let coordinator = BackgroundFlushCoordinator(control: control, lifecycle: lifecycle, runner: runner)
        coordinator.attach()
        lifecycle.moveToBackground()
        #expect(coordinator.isTaskOpen)

        runner.expire.current?()

        #expect(control.expirations.current == 1)
        #expect(runner.ended.current == [1])
        control.done.current?()
        #expect(runner.ended.current == [1])
    }

    @Test("returning to the foreground ends an open task; a refused task begins no flush bracket")
    func foregroundEndsTask() {
        let lifecycle = FakeLifecycleSource(foreground: true)
        let runner = FakeRunner()
        let control = FakeControl()
        let coordinator = BackgroundFlushCoordinator(control: control, lifecycle: lifecycle, runner: runner)
        coordinator.attach()
        lifecycle.moveToBackground()
        lifecycle.moveToForeground()
        #expect(runner.ended.current == [1])
        #expect(!coordinator.isTaskOpen)

        runner.refuse.withLock { $0 = true }
        lifecycle.moveToBackground()
        #expect(runner.begun.current.count == 1)
        #expect(control.begins.current == 1)
    }

    #if canImport(UIKit)
        @Test("the UIKit runner never traps; the xctest host on the simulator refuses a task, an app grants one")
        @MainActor
        func realRunner() {
            let runner = UIKitBackgroundTaskRunner()
            // A test host answers `.invalid`, which the runner reports as nil; the consumer app's UI
            // tests of step 8.1 see a real task and its expiration.
            let handle = runner.begin(name: "rubicon.flush") {}
            if let handle { runner.end(handle) }
        }
    #endif

    // MARK: install and update dates

    @Test("the install and update times are the creation dates of the Library directory and the bundle")
    func installDates() throws {
        let root = TestPlatform.temporaryDirectory()
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let bundleURL = root.appendingPathComponent("App.app", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let installed = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = Date(timeIntervalSince1970: 1_700_500_000)
        var values = URLResourceValues()
        values.creationDate = installed
        var libraryURL = library
        try libraryURL.setResourceValues(values)
        values.creationDate = updated
        var appURL = bundleURL
        try appURL.setResourceValues(values)
        let bundle = try #require(Bundle(url: bundleURL))

        let app = try #require(IOSProcessFacts(bundle: bundle, libraryURL: library).installedApp())

        #expect(app.installTime == installed)
        #expect(app.updateTime == updated)
        #expect(app.version == nil && app.build == nil)
    }

    @Test("a date that cannot be read is nil, so the core writes nothing and tries again")
    func missingDate() throws {
        let root = TestPlatform.temporaryDirectory()
        let bundleURL = root.appendingPathComponent("App.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let bundle = try #require(Bundle(url: bundleURL))

        let app = try #require(
            IOSProcessFacts(bundle: bundle, libraryURL: root.appendingPathComponent("Missing")).installedApp())

        #expect(app.installTime == nil)
        #expect(app.updateTime != nil)
    }

    @Test("the real process facts read the running app's dates")
    func realDates() throws {
        let app = try #require(IOSProcessFacts(bundle: .main).installedApp())
        #expect(app.installTime != nil)
        #expect(app.updateTime != nil)
    }
}
