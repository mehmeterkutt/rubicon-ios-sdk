import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

extension RealWorldSuites {
    /// The port of the Android `CoreIntegrationTest` and `StressTest`: the real core over real files, the
    /// real transport against `TestHTTPServer`, real queues and clocks. One instance per process, so the
    /// suite is serialized and every test resets the instance.
    @Suite("Core integration", .serialized)
    struct CoreIntegrationTests {
        final class Fixture: @unchecked Sendable {
            let root = TestPlatform.temporaryDirectory()
            let server: TestHTTPServer
            let logger = RecordingLogger()
            let developerErrors = Locked<[String]>([])

            init() throws {
                RubiconCore.resetForTests()
                server = try IntegrationSupport.server()
            }

            deinit {
                RubiconCore.resetForTests()
                server.stop()
                try? FileManager.default.removeItem(at: root)
            }

            func platform(network: FakeNetworkMonitor = FakeNetworkMonitor()) -> Platform {
                IntegrationSupport.platform(
                    root: root, network: network, logger: logger, developerErrors: developerErrors)
            }

            func config(_ configure: (inout AnalyticsConfiguration) -> Void = { _ in }) -> AnalyticsConfiguration {
                IntegrationSupport.config(server, configure: configure)
            }

            func create(
                network: FakeNetworkMonitor = FakeNetworkMonitor(),
                configure: (inout AnalyticsConfiguration) -> Void = { _ in },
                onCreated: (any AutomaticCapture) -> Void = { _ in }
            ) -> any Analytics {
                RubiconCore.create(
                    configuration: config(configure), platform: platform(network: network), onCreated: onCreated)
            }

            func flush(_ analytics: any Analytics, _ timeoutMs: Int64 = 10_000) -> Bool {
                RubiconCore.flushBlocking(analytics, timeoutMs: timeoutMs)
            }

            func uploads(_ count: Int, seconds: Double = 5) -> [TestHTTPServer.RecordedRequest] {
                IntegrationSupport.waitForUploads(server, count: count, seconds: seconds)
            }

            func logged(_ level: LogLevel, _ code: Code) -> Bool {
                logger.lines.contains { $0.level == level && $0.message.hasPrefix("\(code.rawValue):") }
            }
        }

        @Test("tracked events reach the server through real files")
        func trackedEventsReachServer() throws {
            let f = try Fixture()
            let analytics = f.create()

            analytics.identify("user-42", traits: ["plan": "pro"])
            analytics.track("Signed Up", properties: ["method": "email"])
            analytics.screen("checkout")

            #expect(f.flush(analytics))
            let request = try #require(f.uploads(1).first)
            #expect(request.header("Authorization") == "Bearer \(IntegrationSupport.apiKey)")
            #expect(try IntegrationSupport.names(request) == ["identify", "Signed Up", "screen"])
            let events = try IntegrationSupport.events(request)
            #expect(events.allSatisfy { IntegrationSupport.string($0, "user_id") == "user-42" })
            #expect(IntegrationSupport.string(try #require(events.first), "device_id") == analytics.deviceId)
            #expect(analytics.deviceId.count == 36)
        }

        @Test("automatic events are sent with source auto, only while their type is enabled")
        func automaticEvents() throws {
            let f = try Fixture()
            var capture: (any AutomaticCapture)?
            let analytics = f.create(onCreated: { capture = $0 })
            let attached = try #require(capture)

            attached.screen(gate: .screenViews, name: "Checkout", properties: ["name_source": "class"])
            // deepLinks is off by default (Lifecycle 6).
            attached.track(gate: .deepLinks, name: "Deep Link Opened", properties: ["scheme": "https"])

            #expect(f.flush(analytics))
            let events = try IntegrationSupport.events(try #require(f.uploads(1).first))
            #expect(events.map { IntegrationSupport.string($0, "type") } == ["screen"])
            #expect(IntegrationSupport.string(try #require(events.first), "name") == "Checkout")
            #expect(IntegrationSupport.string(try #require(events.first), "source") == "auto")
        }

        @Test("a bad automatic name only warns, even in debug")
        func badAutomaticName() throws {
            let f = try Fixture()
            var capture: (any AutomaticCapture)?
            _ = f.create(configure: { $0.debug = true }, onCreated: { capture = $0 })

            try #require(capture).screen(gate: .screenViews, name: "", properties: [:])

            #expect(f.logged(.warn, .invalidEventName))
            #expect(f.developerErrors.current.isEmpty)
        }

        @Test("network capture follows the configuration and the consent, and knows the SDK's host")
        func networkCapture() throws {
            let f = try Fixture()
            var capture: (any AutomaticCapture)?
            let analytics = f.create(onCreated: { capture = $0 })
            let attached = try #require(capture)

            #expect(attached.capturesNetworkRequests)
            #expect(attached.sdkHost == "127.0.0.1")
            // Before the stores are loaded an opt-out waits, and the writer discards what came in between.
            #expect(f.flush(analytics))
            analytics.optOut()
            #expect(!attached.capturesNetworkRequests)

            RubiconCore.resetForTests()
            _ = f.create(configure: { $0.autocapture.enabled.remove(.networkRequests) }, onCreated: { capture = $0 })
            #expect(try #require(capture).capturesNetworkRequests == false)
        }

        @Test("automatic capture is attached once, to a new instance only")
        func attachedOnce() throws {
            let f = try Fixture()
            var attached = 0
            _ = f.create(onCreated: { _ in attached += 1 })
            _ = f.create(onCreated: { _ in attached += 1 })
            RubiconCore.resetForTests()
            _ = f.create(configure: { $0.host = "not a host" }, onCreated: { _ in attached += 1 })

            #expect(attached == 1)
        }

        @Test("offline then online")
        func offlineThenOnline() throws {
            let f = try Fixture()
            let network = FakeNetworkMonitor(connected: false)
            let analytics = f.create(network: network)

            analytics.track("Offline")
            #expect(!f.flush(analytics, 500))
            #expect(IntegrationSupport.uploads(f.server).isEmpty)

            network.setConnected(true)

            #expect(f.flush(analytics))
            #expect(try IntegrationSupport.names(try #require(f.uploads(1).first)) == ["Offline"])
        }

        @Test("503 then 200 sends the same batch again")
        func retried() throws {
            let f = try Fixture()
            f.server.enqueue(.init(status: 503, headers: ["Retry-After": "1"]))
            let analytics = f.create()

            analytics.track("Retried")

            #expect(f.flush(analytics, 15_000))
            let uploads = f.uploads(2)
            try #require(uploads.count == 2)
            let first = try IntegrationSupport.events(uploads[0]).map { IntegrationSupport.string($0, "message_id") }
            let second = try IntegrationSupport.events(uploads[1]).map { IntegrationSupport.string($0, "message_id") }
            #expect(first == second)
        }

        @Test("a restart sends what the previous process left")
        func restart() throws {
            let f = try Fixture()
            let offline = FakeNetworkMonitor(connected: false)
            let first = f.create(network: offline)
            first.track("Left", properties: ["n": 1])
            first.track("Left", properties: ["n": 2])
            #expect(!f.flush(first, 500))
            let firstDeviceId = first.deviceId
            RubiconCore.resetForTests()

            let second = f.create()

            #expect(f.flush(second))
            #expect(try IntegrationSupport.names(try #require(f.uploads(1).first)) == ["Left", "Left"])
            #expect(second.deviceId == firstDeviceId)
        }

        @Test("a crash leftover is recovered and its whole lines are sent")
        func crashLeftover() throws {
            let f = try Fixture()
            let dir = f.root.appendingPathComponent(
                "events/v1/\(Hashing.sha256Hex(IntegrationSupport.apiKey).prefix(16))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let text =
                #"{"type":"track","event":"Before Crash","source":"app","message_id":"a","timestamp":\#(now)}"# + "\n"
                + #"{"type":"track","event":"Half"#
            try Data(text.utf8).write(to: dir.appendingPathComponent("0000000004.tmp"))
            let analytics = f.create()

            #expect(f.flush(analytics))
            #expect(try IntegrationSupport.names(try #require(f.uploads(1).first)) == ["Before Crash"])
        }

        @Test("a second instance returns the first in release and is a developer error in debug")
        func secondInstance() throws {
            let f = try Fixture()
            let first = f.create()

            let second = f.create()

            let firstInstance = try #require(first as? DefaultAnalytics)
            #expect(firstInstance === (second as? DefaultAnalytics))
            #expect(f.logged(.error, .secondInstance))
            _ = f.create { $0.debug = true }
            #expect(f.developerErrors.current.contains { $0.contains("second time") })
        }

        @Test("an unusable configuration gives the no-op instance in release and a developer error in debug")
        func unusableConfiguration() throws {
            let f = try Fixture()

            let analytics = RubiconCore.create(
                configuration: AnalyticsConfiguration(apiKey: " "), platform: f.platform())

            #expect(analytics is NoOpAnalytics)
            #expect(f.logged(.error, .invalidApiKey))
            var debug = AnalyticsConfiguration(apiKey: " ")
            debug.debug = true
            #expect(RubiconCore.create(configuration: debug, platform: f.platform()) is NoOpAnalytics)
            #expect(!f.developerErrors.current.isEmpty)
        }

        @Test("an invalid event name is dropped in release and a developer error in debug")
        func invalidEventName() throws {
            let f = try Fixture()
            let analytics = f.create()

            analytics.track(" ")
            analytics.track("Valid")

            #expect(f.flush(analytics))
            #expect(try IntegrationSupport.names(try #require(f.uploads(1).first)) == ["Valid"])
            RubiconCore.resetForTests()
            f.create { $0.debug = true }.track("")
            #expect(f.developerErrors.current.count == 1)
        }

        @Test("opted out, nothing new is sent and the choice survives a restart")
        func optedOut() throws {
            let f = try Fixture()
            let analytics = f.create()
            analytics.optOut()
            analytics.track("Hidden")
            _ = f.flush(analytics, 1_000)
            RubiconCore.resetForTests()

            let restarted = f.create()

            #expect(restarted.isOptedOut)
            restarted.track("Still hidden")
            _ = f.flush(restarted, 1_000)
            #expect(IntegrationSupport.uploads(f.server).isEmpty)
        }

        @Test("deep links go through the public API with the utm allowlist and the gate")
        func deepLinks() throws {
            let f = try Fixture()
            let analytics = f.create { $0.autocapture.enabled.insert(.deepLinks) }
            let url = try #require(URL(string: "https://shop.example.com/invite/abc?utm_source=mail&token=secret"))
            let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
            activity.webpageURL = url
            activity.referrerURL = URL(string: "https://news.example.org/a")
            let other = NSUserActivity(activityType: "com.example.other")
            other.webpageURL = url

            analytics.trackDeepLink(url, referrer: "com.apple.mobilemail")
            analytics.trackDeepLink(activity)
            analytics.trackDeepLink(other)

            #expect(f.flush(analytics))
            let events = try IntegrationSupport.events(try #require(f.uploads(1).first))
            #expect(events.map { IntegrationSupport.string($0, "event") } == ["Deep Link Opened", "Deep Link Opened"])
            #expect(events.allSatisfy { IntegrationSupport.string($0, "source") == "auto" })
            guard case .object(let first)? = events.first?["properties"],
                case .object(let second)? = events.last?["properties"]
            else {
                Issue.record("no properties")
                return
            }
            #expect(first["utm_source"] == .string("mail"))
            #expect(first["token"] == nil)
            #expect(first["referrer"] == .string("com.apple.mobilemail"))
            #expect(second["referrer"] == .string("news.example.org"))
        }

        /// About a minute of real queues and HTTP: nightly and on demand (`RUBICON_STRESS=1`), not in
        /// every `check.sh` run (plan section 15, step 6.7). No `.timeLimit` trait: it needs iOS 16 and
        /// the package deploys to iOS 15; the nightly job's `timeout-minutes` bounds the run instead.
        @Test(
            "16 threads times 5000 mixed calls",
            .enabled(if: ProcessInfo.processInfo.environment["RUBICON_STRESS"] != nil))
        func stress() throws {
            let f = try Fixture()
            let backpressure = Locked<[String]>([])
            let analytics = f.create {
                $0.flush.at = 100
                $0.logging.eventObserver = { update in
                    if case .dropped(let ids, .backpressure) = update {
                        backpressure.withLock { $0.append(contentsOf: ids) }
                    }
                }
            }
            let threads = 16
            let calls = 5000
            let tracked = Locked(0)

            DispatchQueue.concurrentPerform(iterations: threads) { thread in
                var own = 0
                for i in 0..<calls {
                    if i % 50 == 0 {
                        analytics.register("thread_\(thread)", value: i)
                    } else if i % 1000 == 999 {
                        analytics.flush()
                    } else if i % 7 == 0 {
                        analytics.screen("screen_\(thread)", properties: ["t": thread, "i": i])
                        own += 1
                    } else {
                        analytics.track("E", properties: ["t": thread, "i": i])
                        own += 1
                    }
                }
                tracked.withLock { $0 += own }
            }
            #expect(f.flush(analytics, 120_000), "everything was sent")

            let received = try IntegrationSupport.uploads(f.server).flatMap { try IntegrationSupport.events($0) }
            let ids = received.compactMap { IntegrationSupport.string($0, "message_id") }
            #expect(ids.count == Set(ids).count, "no event arrives twice")

            // Per-thread order: the i of each thread's events only grows.
            var orders: [Int: [Int]] = [:]
            for event in received {
                guard case .object(let properties)? = event["properties"], case .number(let t)? = properties["t"],
                    case .number(let i)? = properties["i"]
                else { continue }
                orders[Int(t), default: []].append(Int(i))
            }
            for (thread, order) in orders {
                #expect(order == order.sorted(), "order of thread \(thread)")
            }

            let device = DeviceStore(
                keyValueStore: FileKeyValueStore(root: f.root, fileSystem: PosixFileSystem()),
                log: Log(level: .off, logger: nil, platformLogger: noOpLogger), clock: TestClock(),
                newDeviceId: { "unused" })
            device.load()
            let dropped = device.state?.diagnostics.dropped ?? [:]
            #expect(!received.isEmpty, "events reached the server")
            // Tight loops on 16 threads outrun any writer: most calls end as backpressure or queue_full,
            // which is the bounded behaviour Queue 1 and 5 decide. What matters is that nothing is lost
            // without being counted.
            #expect(backpressure.current.count == dropped["backpressure"] ?? 0, "backpressure counted exactly")
            #expect(
                tracked.current == received.count + dropped.values.reduce(0, +),
                "every event was sent or counted: \(dropped)")
        }
    }
}
