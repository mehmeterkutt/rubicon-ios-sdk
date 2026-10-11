import Foundation
import Testing

@testable import RubiconCore

/// A test fake conforms to the protocol in a few lines (iOS Public API 4).
private final class RecordingAnalytics: Analytics, @unchecked Sendable {
    // Guarded by `calls`.
    let calls = Locked<[String]>([])
    func track(_ name: String, properties: [String: Any]) { calls.withLock { $0.append("track \(name)") } }
    func screen(_ name: String, properties: [String: Any]) { calls.withLock { $0.append("screen \(name)") } }
    func identify(_ userId: String, traits: [String: Any]) { calls.withLock { $0.append("identify \(userId)") } }
    func reset() { calls.withLock { $0.append("reset") } }
    func register(_ key: String, value: Any) { calls.withLock { $0.append("register \(key)") } }
    func unregister(_ key: String) { calls.withLock { $0.append("unregister \(key)") } }
    func flush() { calls.withLock { $0.append("flush") } }
    func optOut() { calls.withLock { $0.append("optOut") } }
    func optIn() { calls.withLock { $0.append("optIn") } }
    var isOptedOut: Bool { false }
    func clearLocalData() { calls.withLock { $0.append("clearLocalData") } }
    var deviceId: String { "fake" }
    func trackDeepLink(_ url: URL, referrer: String?) {
        calls.withLock { $0.append("deepLink \(url) \(referrer ?? "-")") }
    }
    func trackDeepLink(_ activity: NSUserActivity) { calls.withLock { $0.append("activity \(activity.activityType)") } }
}

@Suite("Analytics protocol and NoOpAnalytics")
struct NoOpAnalyticsTests {
    let analytics: any Analytics = NoOpAnalytics()

    private func callEverything(_ analytics: any Analytics, _ i: Int) throws {
        analytics.track("Event \(i)", properties: ["i": i])
        analytics.track("Event \(i)")
        analytics.screen("screen_\(i)")
        analytics.identify("user-\(i)", traits: ["plan": "pro"])
        analytics.identify("user-\(i)")
        analytics.register("key_\(i)", value: i)
        analytics.unregister("key_\(i)")
        analytics.flush()
        analytics.optOut()
        analytics.optIn()
        _ = analytics.isOptedOut
        _ = analytics.deviceId
        analytics.clearLocalData()
        analytics.reset()
        analytics.trackDeepLink(try #require(URL(string: "myapp://a/b?utm_source=x")))
        analytics.trackDeepLink(try #require(URL(string: "https://a.com/b")), referrer: "com.apple.mobilesafari")
        analytics.trackDeepLink(NSUserActivity(activityType: "NSUserActivityTypeBrowsingWeb"))
    }

    @Test("every method returns without doing anything; it reports opted out and no id")
    func acceptsEverything() throws {
        try callEverything(analytics, 0)
        #expect(analytics.isOptedOut)
        #expect(analytics.deviceId == "")
        analytics.optIn()
        #expect(analytics.isOptedOut)
        analytics.clearLocalData()
        #expect(analytics.deviceId == "")
        #expect(String(describing: analytics) == "NoOpAnalytics")
    }

    @Test("input the real instance rejects does not trap")
    func hostileInput() {
        let unsupported: [String: Any] = ["at": Data(), "nan": Double.nan, "self": NSObject()]
        analytics.track("", properties: unsupported)
        analytics.screen(String(repeating: " ", count: 300), properties: unsupported)
        analytics.identify("", traits: unsupported)
        analytics.register("", value: NSObject())
        analytics.unregister("")
    }

    @Test("calls from many threads at once never trap")
    func manyThreads() {
        let group = DispatchGroup()
        let failures = Locked(0)
        for thread in 0..<8 {
            group.enter()
            Thread { [analytics] in
                for i in 0..<1_000 {
                    do { try callEverything(analytics, thread * 1_000 + i) } catch { failures.withLock { $0 += 1 } }
                }
                group.leave()
            }.start()
        }
        #expect(group.wait(timeout: .now() + 30) == .success)
        #expect(failures.current == 0)
    }

    @Test("a fake conforms in a few lines and the default arguments forward")
    func fake() throws {
        let fake = RecordingAnalytics()
        let analytics: any Analytics = fake

        analytics.track("A")
        analytics.screen("S")
        analytics.identify("u")
        analytics.trackDeepLink(try #require(URL(string: "myapp://x")))

        #expect(fake.calls.current == ["track A", "screen S", "identify u", "deepLink myapp://x -"])
        #expect(!analytics.isOptedOut)
        #expect(analytics.deviceId == "fake")
    }
}
