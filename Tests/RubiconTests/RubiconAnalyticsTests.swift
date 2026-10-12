import Foundation
import RubiconTesting
import Testing
import os

@testable import Rubicon
@testable import RubiconCore

#if canImport(UIKit)
    import UIKit
#endif

/// The factory and the iOS platform (step 7.1). On the simulator the whole path runs: real files
/// under a temporary root, the real transport against `TestHTTPServer`; on macOS the same, without
/// UIKit's notifications. One instance per process, so the suite is serialized.
extension ProcessWideSuites {
    @Suite("RubiconAnalytics", .serialized)
    struct RubiconAnalyticsTests {
        final class Fixture: @unchecked Sendable {
            let root = TestPlatform.temporaryDirectory().appendingPathComponent("rubicon", isDirectory: true)
            let server: TestHTTPServer
            let logger = RecordingLogger()

            init() throws {
                RubiconAnalytics.resetForTests()
                server = try TestHTTPServer()
                server.respond(to: "/v1/config", with: .init(status: 404))
            }

            deinit {
                RubiconAnalytics.resetForTests()
                server.stop()
                try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            }

            func config(level: LogLevel = .warn, configure: (inout AnalyticsConfiguration) -> Void = { _ in })
                -> AnalyticsConfiguration
            {
                var config = AnalyticsConfiguration(apiKey: "rk_ios")
                config.host = server.hostString
                config.logging.sendDiagnostics = false
                config.logging.level = level
                config.logging.logger = logger.asLogger
                config.debug = false
                configure(&config)
                return config
            }

            func make(bundle: Bundle = .main, configure: (inout AnalyticsConfiguration) -> Void = { _ in })
                -> any Analytics
            {
                RubiconAnalytics.make(configuration: config(configure: configure), bundle: bundle, storageRoot: root)
            }

            func uploads(seconds: Double = 5) -> [TestHTTPServer.RecordedRequest] {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    let uploads = server.requests.filter { $0.path == "/v1/batch" }
                    if !uploads.isEmpty { return uploads }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                return server.requests.filter { $0.path == "/v1/batch" }
            }

            /// A bundle whose path ends in `.appex`, what an extension's `Bundle.main` reports.
            func extensionBundle() throws -> Bundle {
                let url = TestPlatform.temporaryDirectory().appendingPathComponent("Widget.appex", isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return try #require(Bundle(url: url))
            }
        }

        @Test("the factory returns a working instance that stores under the root and uploads")
        func workingInstance() throws {
            let f = try Fixture()
            let analytics = f.make()

            #expect(analytics is DefaultAnalytics)
            analytics.track("Opened")
            #expect(RubiconCore.flushBlocking(analytics, timeoutMs: 10_000))

            let upload = try #require(f.uploads().first)
            #expect(upload.header("Authorization") == "Bearer rk_ios")
            #expect(upload.header("User-Agent")?.hasPrefix("rubicon-ios/\(RubiconAnalytics.version) (iOS ") == true)
            #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("device.json").path))
            #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("person.json").path))
            #expect(analytics.deviceId.count == 36)
        }

        @Test("the directory is excluded from backup and keeps the host's protection class")
        func directoryAttributes() throws {
            let f = try Fixture()
            let analytics = f.make()
            analytics.track("Opened")
            #expect(RubiconCore.flushBlocking(analytics, timeoutMs: 10_000))

            let values = try f.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true)
            #if canImport(UIKit)
                // Nothing set by the SDK: whatever the host's default is, never `.complete` (iOS Disk 1).
                let protection = try f.root.appendingPathComponent("device.json").resourceValues(forKeys: [
                    .fileProtectionKey
                ])
                #expect(protection.fileProtection != .complete)
            #endif
        }

        @Test("a bundle path ending in .appex returns the no-op with one INFO line and no files")
        func appExtension() throws {
            let f = try Fixture()

            let analytics = f.make(bundle: try f.extensionBundle()) { $0.logging.level = .info }

            #expect(analytics is NoOpAnalytics)
            #expect(f.logger.lines.filter { $0.level == .info && $0.message.contains("app extension") }.count == 1)
            #expect(!FileManager.default.fileExists(atPath: f.root.path))
            #expect(analytics.isOptedOut)
            #expect(analytics.deviceId == "")
        }

        @Test("building the platform touches no file")
        func platformTouchesNoFile() throws {
            let f = try Fixture()

            _ = IOSPlatform.make(bundle: .main, processFacts: IOSProcessFacts(bundle: .main), storageRoot: f.root)

            #expect(!FileManager.default.fileExists(atPath: f.root.path))
        }

        @Test("the default storage root is Application Support/rubicon")
        func storageRoot() {
            let root = IOSPlatform.storageRoot()
            #expect(root.lastPathComponent == "rubicon")
            #expect(root.deletingLastPathComponent().lastPathComponent == "Application Support")
        }

        @Test("a developer's logger is never replaced; without one the INFO line goes to the sink")
        func loggerKept() throws {
            let f = try Fixture()
            _ = f.make { $0.logging.level = .info }

            #expect(f.logger.messages.contains { $0.hasPrefix("Sending to") })
        }
    }
}
@Suite("iOS platform parts")
struct PlatformPartsTests {
    @Test("the sink maps the levels to unified logging and names an error by domain and code")
    func sinkMapping() {
        let written = Locked<[(OSLogType, String)]>([])
        let sink = OSLogSink { type, text in written.withLock { $0.append((type, text)) } }
        let logger = sink.rubiconLogger

        logger(.debug, "d", nil)
        logger(.info, "i", nil)
        logger(.warn, "w", nil)
        logger(
            .error, "e",
            NSError(
                domain: "NSURLErrorDomain", code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "https://secret.example/x"]))
        logger(.off, "never", nil)

        let lines = written.current
        #expect(lines.map(\.0) == [.debug, .info, .default, .error])
        #expect(lines.map(\.1) == ["d", "i", "w", "e [NSURLErrorDomain -1001]"])
        #expect(!lines.contains { $0.1.contains("secret") })
        #expect(OSLogSink.subsystem == "com.rubicon.analytics")
        #expect(OSLogSink.category == "Rubicon")
    }

    @Test("the OS version drops a zero patch, the extension check reads the bundle path")
    func processFacts() throws {
        #expect(
            IOSProcessFacts.format(OperatingSystemVersion(majorVersion: 17, minorVersion: 5, patchVersion: 1))
                == "17.5.1")
        #expect(
            IOSProcessFacts.format(OperatingSystemVersion(majorVersion: 18, minorVersion: 0, patchVersion: 0)) == "18.0"
        )
        let facts = IOSProcessFacts(bundle: .main)
        #expect(!facts.isAppExtension)
        #expect(!facts.osVersion.isEmpty)
        let url = TestPlatform.temporaryDirectory().appendingPathComponent("Share.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(IOSProcessFacts(bundle: try #require(Bundle(url: url))).isAppExtension)
    }

    @Test("the uptime clock never moves back and counts milliseconds")
    func uptimeClock() {
        let clock = UptimeClock()
        let first = clock.elapsedMillis()
        Thread.sleep(forTimeInterval: 0.011)
        let second = clock.elapsedMillis()
        #expect(second - first >= 10)
        #expect(first > 0)
    }

    @Test("the system random source gives different values")
    func random() {
        let random = SystemRandom()
        let values = Set((0..<8).map { _ in random.nextUInt64() })
        #expect(values.count > 1)
    }

    #if canImport(UIKit)
        @Test("protected-data and termination notifications reach the listeners once per change")
        @MainActor
        func notifications() async throws {
            let center = NotificationCenter()
            let source = ApplicationLifecycleSource(center: center)
            let events = Locked<[LifecycleEvent]>([])
            source.attach()
            // The simulator's test host reports protected data unavailable; start from a known state.
            center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
            #expect(source.isProtectedDataAvailable)
            _ = source.addListener { event in events.withLock { $0.append(event) } }

            center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
            center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
            #expect(!source.isProtectedDataAvailable)
            center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
            #expect(source.isProtectedDataAvailable)
            center.post(name: UIApplication.willTerminateNotification, object: nil)

            #expect(
                events.current == [
                    .protectedDataWillBecomeUnavailable, .protectedDataDidBecomeAvailable, .willTerminate,
                ])
        }

        @Test("attach off the main thread registers on it without waiting")
        func attachOffMain() async throws {
            let center = NotificationCenter()
            let source = ApplicationLifecycleSource(center: center)
            let events = Locked<[LifecycleEvent]>([])
            _ = source.addListener { event in events.withLock { $0.append(event) } }

            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    source.attach()
                    continuation.resume()
                }
            }
            await MainActor.run {}
            center.post(name: UIApplication.willTerminateNotification, object: nil)

            // The registration on the main thread may report the host's foreground first (7.4).
            #expect(events.current.last == .willTerminate)
            #expect(events.current.filter { $0 == .willTerminate }.count == 1)
        }
    #endif
}
