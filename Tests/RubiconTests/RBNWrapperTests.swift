import Foundation
import RubiconTesting
import Testing

@testable import Rubicon
@testable import RubiconCore
@testable import RubiconObjC

/// The Objective-C wrapper from the Swift side (step 7.7): the conversions, the configuration
/// mapping and the boxed blocks through a real instance. The Objective-C target holds the compile
/// test and the selector-level checks. One instance per process, so the suite is serialized.
extension ProcessWideSuites {
    @Suite("RBNWrapper", .serialized)
    struct RBNWrapperTests {
        final class Fixture: @unchecked Sendable {
            let root = TestPlatform.temporaryDirectory().appendingPathComponent("rubicon", isDirectory: true)
            let server: TestHTTPServer
            let lines = Locked<[(RBNLogLevel, String)]>([])
            let updates = Locked<[RBNEventUpdate]>([])

            init() throws {
                RBNAnalytics.resetForTests()
                server = try TestHTTPServer()
                server.respond(to: "/v1/config", with: .init(status: 404))
            }

            deinit {
                RBNAnalytics.resetForTests()
                server.stop()
                try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            }

            func configuration(configure: (RBNConfiguration) -> Void = { _ in }) -> RBNConfiguration {
                let config = RBNConfiguration(apiKey: "rk_objc")
                config.host = server.hostString
                config.debug = false
                config.logging.sendDiagnostics = false
                config.logging.logger = { [lines] level, message, _ in lines.withLock { $0.append((level, message)) } }
                config.logging.eventObserver = { [updates] update in updates.withLock { $0.append(update) } }
                configure(config)
                return config
            }

            func make(configure: (RBNConfiguration) -> Void = { _ in }) -> RBNAnalytics {
                RBNAnalytics.make(configuration: configuration(configure: configure), bundle: .main, storageRoot: root)
            }

            func flush(_ analytics: any Analytics, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
                FlushDiagnostics.flush(
                    analytics, server: server, messages: { lines.current.map(\.1) }, sourceLocation: sourceLocation)
            }

            func messages(containing code: Code) -> [String] {
                lines.current.map(\.1).filter { $0.contains(code.rawValue) }
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

            func events(_ request: TestHTTPServer.RecordedRequest) throws -> [[String: Any]] {
                let bytes =
                    request.header("Content-Encoding") == "gzip" ? try Gzip.decompress(request.body) : request.body
                let body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                return body?["batch"] as? [[String: Any]] ?? []
            }

            func event(named name: String, seconds: Double = 5) throws -> [String: Any]? {
                try uploads(seconds: seconds).flatMap(events).first { $0["event"] as? String == name }
            }

            /// Whether a decoded JSON number is a boolean (`NSNumber` keeps the distinction).
            static func isBool(_ value: Any?) -> Bool {
                guard let number = value as? NSNumber else { return false }
                return CFGetTypeID(number) == CFBooleanGetTypeID()
            }

            func wait(seconds: Double = 5, until condition: () -> Bool) -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    if condition() { return true }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                return condition()
            }
        }

        // MARK: Enums

        @Test("every enum round-trips through its Objective-C mirror")
        func enumsRoundTrip() {
            for level in LogLevel.allCases { #expect(RBNLogLevel(level).swift == level) }
            for type in Autocapture.allCases { #expect(RBNAutocapture(type).swift == type) }
            for field in ContextField.allCases { #expect(RBNContextField(field).swift == field) }
            for consent in Consent.allCases { #expect(RBNConsent(consent).swift == consent) }
            for reason in DropReason.allCases { #expect(RBNDropReason(reason).name == reason.rawValue) }
            #expect(RBNEventSource(.app) == .app)
            #expect(RBNEventSource(.auto) == .auto)
            #expect(RBNLogLevel.allCases.count == LogLevel.allCases.count)
            #expect(RBNAutocapture.allCases.count == Autocapture.allCases.count)
            #expect(RBNContextField.allCases.count == ContextField.allCases.count)
            #expect(RBNConsent.allCases.count == Consent.allCases.count)
            #expect(RBNDropReason.allCases.count == DropReason.allCases.count)
            #expect(RBNEventSource.allCases.count == EventSource.allCases.count)
        }

        // MARK: Configuration

        @Test("the configuration starts with the Swift defaults and every setter reaches the Swift value")
        func configurationMapping() {
            let config = RBNConfiguration(apiKey: "rk_objc")
            let defaults = AnalyticsConfiguration(apiKey: "rk_objc")
            let unchanged = config.swift(hookLog: RBNHookLog())
            #expect(unchanged.host == defaults.host)
            #expect(unchanged.autocapture.enabled == defaults.autocapture.enabled)
            #expect(unchanged.beforeSend.isEmpty)
            #expect(unchanged.logging.logger == nil)
            #expect(config.apiKey == "rk_objc")
            #expect(config.flush.at == defaults.flush.at)
            #expect(config.flush.intervalMs == defaults.flush.intervalMs)
            #expect(config.session.backgroundTimeoutMs == defaults.session.backgroundTimeoutMs)
            #expect(config.autocapture.isEnabled(.appLifecycle))
            #expect(!config.autocapture.isEnabled(.deepLinks))
            #expect(!config.context.isDisabled(.locale))
            #expect(config.privacy.defaultConsent == .granted)
            #expect(config.privacy.persistConsent)
            #expect(config.logging.level == .warn)
            #expect(config.logging.logger == nil)
            #expect(config.logging.eventObserver == nil)
            #expect(config.logging.sendDiagnostics)
            #expect(config.network.headers.isEmpty)
            #expect(config.beforeSendCount == 0)

            config.host = "https://collect.example.com"
            config.debug = true
            config.flush.at = 7
            config.flush.intervalMs = 5_000
            config.flush.immediateEvents = ["Purchase Completed"]
            config.session.backgroundTimeoutMs = 20_000
            config.autocapture.disable(.networkRequests)
            config.autocapture.enable(.deepLinks)
            config.context.disable(.locale)
            config.context.disable(.timezone)
            config.context.enable(.timezone)
            config.privacy.defaultConsent = .pending
            config.privacy.persistConsent = false
            config.logging.level = .debug
            config.logging.logger = { _, _, _ in }
            config.logging.eventObserver = { _ in }
            config.logging.sendDiagnostics = false
            config.network.headers = ["X-Gateway": "a"]
            config.addBeforeSend { $0 }
            config.addBeforeSend { _ in nil }

            let swift = config.swift(hookLog: RBNHookLog())
            #expect(swift.host == "https://collect.example.com")
            #expect(swift.debug)
            #expect(swift.flush.at == 7)
            #expect(swift.flush.intervalMs == 5_000)
            #expect(swift.flush.immediateEvents == ["Purchase Completed"])
            #expect(swift.session.backgroundTimeoutMs == 20_000)
            #expect(swift.autocapture.enabled == Set(Autocapture.allCases).subtracting([.networkRequests]))
            #expect(swift.context.disabledFields == [.locale])
            #expect(swift.privacy.defaultConsent == .pending)
            #expect(!swift.privacy.persistConsent)
            #expect(swift.logging.level == .debug)
            #expect(swift.logging.logger != nil)
            #expect(swift.logging.eventObserver != nil)
            #expect(!swift.logging.sendDiagnostics)
            #expect(swift.network.headers == ["X-Gateway": "a"])
            #expect(swift.beforeSend.count == 2)
            #expect(config.beforeSendCount == 2)
            config.removeAllBeforeSend()
            #expect(config.beforeSendCount == 0)
            #expect(config.autocapture.isEnabled(.deepLinks))
            #expect(config.context.isDisabled(.locale))
            #expect(!config.context.isDisabled(.timezone))
        }

        // MARK: Event views

        @Test("a hook sees the typed view with the fixed fields, and its name and property changes reach the wire")
        func hookChangesReachTheWire() throws {
            let f = try Fixture()
            let seen = Locked<[String: Any]>([:])
            let analytics = f.make { config in
                config.addBeforeSend { event in
                    guard let track = event as? RBNTrackEvent, track.source == .app else { return event }
                    seen.withLock {
                        $0["messageId"] = track.messageId
                        $0["deviceId"] = track.deviceId
                        $0["userId"] = track.userId as Any
                        $0["context"] = track.context
                        $0["properties"] = track.properties
                        $0["timestamp"] = track.timestamp
                    }
                    track.name = "Order Placed"
                    var properties = track.properties
                    properties["flag"] = NSNumber(value: true)
                    properties["count"] = NSNumber(value: 1)
                    properties.removeValue(forKey: "secret")
                    track.properties = properties
                    return track
                }
            }

            analytics.trackEvent("Purchase Completed", properties: ["amount": 49.9, "secret": "x"])
            #expect(f.flush(analytics.analytics))

            let event = try #require(try f.event(named: "Order Placed"))
            let properties = try #require(event["properties"] as? [String: Any])
            #expect(properties["amount"] as? Double == 49.9)
            #expect(properties["flag"] as? Bool == true)
            #expect(Fixture.isBool(properties["flag"]))
            #expect(properties["count"] as? Int == 1)
            #expect(!Fixture.isBool(properties["count"]))
            #expect(properties["secret"] == nil)
            let fields = seen.current
            #expect((fields["messageId"] as? String)?.count == 36)
            #expect(fields["deviceId"] as? String == analytics.deviceId)
            #expect(fields["userId"] is NSNull || fields["userId"] == nil || (fields["userId"] as? String) == nil)
            let context = try #require(fields["context"] as? [String: Any])
            #expect((context["library"] as? [String: Any])?["name"] as? String == "rubicon-ios")
            #expect((context["os"] as? [String: Any])?["name"] != nil)
            #expect((fields["properties"] as? [String: Any])?["secret"] as? String == "x")
            #expect(fields["timestamp"] is Date)
        }

        @Test("screen and identify events have their own views; traits set through the view are validated")
        func screenAndIdentifyViews() throws {
            let f = try Fixture()
            let kinds = Locked<[String]>([])
            let analytics = f.make { config in
                config.addBeforeSend { event in
                    kinds.withLock { $0.append(String(describing: type(of: event))) }
                    if let screen = event as? RBNScreenEvent, screen.source == .app {
                        screen.name = "Checkout Screen"
                    }
                    if let identify = event as? RBNIdentifyEvent {
                        var traits = identify.traits
                        traits["plan"] = "pro"
                        traits["bad"] = NSObject()
                        identify.traits = traits
                    }
                    return event
                }
            }

            analytics.trackScreen("Checkout", properties: ["step": 2])
            analytics.identifyUser("user-1", traits: ["email": "a@b.c"])
            #expect(f.flush(analytics.analytics))

            let all = try f.uploads().flatMap(f.events)
            let screen = try #require(all.first { $0["type"] as? String == "screen" })
            #expect(screen["name"] as? String == "Checkout Screen")
            let identify = try #require(all.first { $0["type"] as? String == "identify" })
            let traits = try #require(identify["traits"] as? [String: Any])
            #expect(traits["plan"] as? String == "pro")
            #expect(traits["email"] as? String == "a@b.c")
            #expect(traits["bad"] == nil)
            #expect(identify["user_id"] as? String == "user-1")
            #expect(kinds.current.contains("RBNScreenEvent"))
            #expect(kinds.current.contains("RBNIdentifyEvent"))
        }

        @Test("the event observer receives queued, sent and dropped as RBNEventUpdate")
        func observerUpdates() throws {
            let f = try Fixture()
            let analytics = f.make { config in
                config.addBeforeSend { event in
                    if let track = event as? RBNTrackEvent, track.name == "Dropped" { return nil }
                    return event
                }
            }

            analytics.trackEvent("Kept")
            analytics.trackEvent("Dropped")
            #expect(f.flush(analytics.analytics))
            #expect(f.wait { f.updates.current.contains { $0.kind == .sent } })

            let updates = f.updates.current
            let queued = try #require(
                updates.first { $0.kind == .queued && ($0.event as? RBNTrackEvent)?.name == "Kept" })
            #expect(queued.messageIds == [queued.event?.messageId ?? ""])
            #expect(queued.dropReasonName == "")
            #expect(queued.description.hasPrefix("queued("))
            let dropped = try #require(updates.first { $0.kind == .dropped })
            #expect(dropped.dropReason == .beforeSend)
            #expect(dropped.dropReasonName == "before_send")
            #expect(dropped.event == nil)
            #expect(dropped.messageIds.count == 1)
            #expect(dropped.description == "dropped(1 events, before_send)")
            let sent = try #require(updates.first { $0.kind == .sent })
            #expect(sent.messageIds.contains(queued.messageIds[0]))
            #expect(sent.description.hasPrefix("sent("))
        }

        // MARK: Raising blocks

        @Test("a beforeSend block that raises drops the event with before_send and logs HOOK_THREW once")
        func hookRaises() throws {
            let f = try Fixture()
            let analytics = f.make { config in
                config.addBeforeSend { event in
                    if let track = event as? RBNTrackEvent, track.name == "Boom" {
                        NSException(name: .internalInconsistencyException, reason: "secret detail", userInfo: nil)
                            .raise()
                    }
                    return event
                }
            }

            analytics.trackEvent("Boom")
            analytics.trackEvent("Boom")
            analytics.trackEvent("Fine")
            #expect(f.flush(analytics.analytics))

            let names = try f.uploads().flatMap(f.events).compactMap { $0["event"] as? String }
            #expect(names.contains("Fine"))
            #expect(!names.contains("Boom"))
            let threw = f.messages(containing: .hookThrew)
            #expect(threw.count == 1)
            #expect(threw.first?.contains("NSInternalInconsistencyException") == true)
            #expect(threw.first?.contains("secret detail") == false)
            #expect(
                f.wait { f.updates.current.filter { $0.kind == .dropped && $0.dropReason == .beforeSend }.count == 2 })
        }

        @Test(
            "a logger block that raises is replaced by the default sink with LOGGER_THREW, also when it raises during make"
        )
        func loggerRaises() throws {
            let f = try Fixture()
            let calls = Locked(0)
            let analytics = f.make { config in
                config.logging.level = .info
                config.logging.logger = { _, _, _ in
                    calls.withLock { $0 += 1 }
                    NSException(name: .genericException, reason: nil, userInfo: nil).raise()
                }
            }

            // The INFO line of `make` already raised, before the instance existed.
            #expect(calls.current == 1)
            analytics.trackEvent("After")
            #expect(f.flush(analytics.analytics))
            #expect(calls.current == 1)
        }

        @Test("an observer block that raises is switched off with OBSERVER_THREW")
        func observerRaises() throws {
            let f = try Fixture()
            let calls = Locked(0)
            let analytics = f.make { config in
                config.logging.eventObserver = { _ in
                    calls.withLock { $0 += 1 }
                    NSException(name: .genericException, reason: nil, userInfo: nil).raise()
                }
            }

            analytics.trackEvent("One")
            analytics.trackEvent("Two")
            #expect(f.flush(analytics.analytics))

            #expect(f.messages(containing: .observerThrew).count == 1)
            #expect(calls.current == 1)
        }

        // MARK: Forwarding

        @Test("every verb forwards: identity, super properties, consent, deep links, flush and the version")
        func verbsForward() throws {
            let f = try Fixture()
            let analytics = f.make { $0.autocapture.enable(.deepLinks) }

            let second = RBNAnalytics.make(configuration: f.configuration(), bundle: .main, storageRoot: f.root)
            let sameInstance = (second.analytics as? DefaultAnalytics) === (analytics.analytics as? DefaultAnalytics)
            #expect(sameInstance)
            #expect(second === analytics)
            #expect(analytics.analytics is DefaultAnalytics)
            #expect(RBNAnalytics.sdkVersion == RubiconAnalytics.version)
            #expect(analytics.deviceId.count == 36)
            #expect(!analytics.isOptedOut)

            analytics.registerSuperProperty("tier", value: "gold")
            analytics.registerSuperProperty("none", value: NSNull())
            analytics.unregisterSuperProperty("none")
            analytics.identifyUser("user-7")
            analytics.trackEvent("Plain")
            analytics.trackScreen("Home")
            analytics.trackDeepLink(URL(string: "rubicon://offer/1?code=x")!, referrer: "com.apple.mobilesafari")
            let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
            activity.webpageURL = URL(string: "https://example.com/offer/2")
            analytics.trackDeepLink(withActivity: activity)
            analytics.flush()
            #expect(f.flush(analytics.analytics))

            let all = try f.uploads().flatMap(f.events)
            let plain = try #require(all.first { $0["event"] as? String == "Plain" })
            #expect(plain["user_id"] as? String == "user-7")
            let properties = plain["properties"] as? [String: Any]
            #expect(properties?["tier"] as? String == "gold")
            #expect(properties?["none"] == nil)
            #expect(all.contains { $0["type"] as? String == "screen" && $0["name"] as? String == "Home" })
            #expect(all.filter { $0["event"] as? String == "Deep Link Opened" }.count == 2)

            analytics.optOut()
            #expect(analytics.isOptedOut)
            analytics.optIn()
            #expect(!analytics.isOptedOut)
            let before = analytics.deviceId
            analytics.reset()
            analytics.clearLocalData()
            #expect(f.wait { analytics.deviceId != before })
        }

        @Test("the network observer wraps the Swift one with the same two delegate methods")
        func networkObserver() throws {
            let f = try Fixture()
            let analytics = f.make()
            let observer = RBNNetworkObserver(analytics: analytics, hosts: ["127.0.0.1"])
            let masked = RBNNetworkObserver(analytics: analytics, hosts: ["*.example.com"], maskPathIds: false)
            _ = masked

            let session = URLSession(configuration: .ephemeral)
            let task = session.dataTask(with: f.server.url(path: "/ping"))
            observer.urlSession(session, task: task, didCompleteWithError: nil)
            observer.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
            session.invalidateAndCancel()
            // Without metrics nothing is sent; the forwarding is what is under test, the rules have their own.
            #expect(f.updates.current.allSatisfy { ($0.event as? RBNTrackEvent)?.name != "Network Request" })
        }
    }
}
