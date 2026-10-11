import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The Android `RemoteConfigTest`, ported.
final class RemoteHarness: @unchecked Sendable {
    let support = StoreTestSupport()
    let transport = FakeTransport()
    let flags = RuntimeFlags()
    lazy var code = code()
    lazy var store = deviceStore()

    func code(_ change: (inout AnalyticsConfiguration) -> Void = { _ in }) -> ConfigSnapshot {
        var config = AnalyticsConfiguration(apiKey: "rk_test")
        change(&config)
        return ConfigValidator.validate(config).snapshot ?? ConfigValidator.validate(
            AnalyticsConfiguration(apiKey: "rk_test")
        ).snapshot!
    }

    func remote(_ json: String, code: ConfigSnapshot? = nil) -> RemoteConfig {
        RemoteConfig.from(RemoteConfig.parseBody(json) ?? [:], code: code ?? self.code, log: support.log)
    }

    func deviceStore() -> DeviceStore {
        let store = DeviceStore(keyValueStore: support.files, log: support.log, clock: TestClock()) { "device-1" }
        store.load()
        return store
    }

    func client(store: DeviceStore? = nil, flags: RuntimeFlags? = nil, code: ConfigSnapshot? = nil)
        -> RemoteConfigClient
    {
        RemoteConfigClient(
            code: code ?? self.code, deviceStore: store ?? self.store, transport: transport, flags: flags ?? self.flags,
            log: support.log)
    }

    func ok(_ body: String, etag: String? = "\"v1\"") -> HttpResult { .success(code: 200, body: body, etag: etag) }
    var warnings: [RecordingLogger.Line] {
        support.test.logger.lines.filter { $0.level == .warn && $0.message.hasPrefix("REMOTE_CONFIG_INVALID_VALUE") }
    }
    var failedWarnings: Int {
        support.test.logger.lines.filter { $0.level == .warn && $0.message.hasPrefix("REMOTE_CONFIG_FAILED") }.count
    }
}

@Suite("RemoteConfig validation")
struct RemoteConfigValidationTests {
    let h = RemoteHarness()

    @Test("a full valid body restricts the code")
    func fullBody() {
        let code = h.code
        let remote = h.remote(
            #"{"enabled":false,"autocapture_off":["network_requests","sessions"],"flush_at":50,"flush_interval_ms":120000,"sample_rate":0.5,"diagnostics_sample_rate":0}"#,
            code: code)
        let restricted = remote.restrict(code)
        #expect(!remote.enabled)
        #expect(remote.autocaptureOff == [.networkRequests, .sessions])
        #expect(restricted.autocapture == code.autocapture.subtracting([.networkRequests, .sessions]))
        #expect(restricted.flushAt == 50)
        #expect(restricted.flushIntervalMs == 120_000)
        #expect(remote.sampleRate == 0.5)
        #expect(remote.diagnosticsSampleRate == 0.0)
        #expect(h.warnings.isEmpty)
    }

    @Test("an empty body changes nothing; remote cannot switch on an autocapture the code switched off")
    func emptyAndWidening() {
        let code = h.code
        #expect(h.remote("{}", code: code).restrict(code).autocapture == code.autocapture)
        #expect(h.remote("{}", code: code) == .none)
        let sessionsOnly = h.code { $0.autocapture.enabled = [.sessions] }
        #expect(
            h.remote(#"{"autocapture_off":[]}"#, code: sessionsOnly).restrict(sessionsOnly).autocapture == [.sessions])
    }

    @Test("flushing can only become less frequent; values outside the bounds are ignored")
    func flushing() {
        let code = h.code {
            $0.flush.at = 40
            $0.flush.intervalMs = 90_000
        }
        let lower = h.remote(#"{"flush_at":20,"flush_interval_ms":30000}"#, code: code).restrict(code)
        let higher = h.remote(#"{"flush_at":40,"flush_interval_ms":600000}"#, code: code).restrict(code)
        #expect(lower.flushAt == 40)
        #expect(lower.flushIntervalMs == 90_000)
        #expect(higher.flushAt == 40)
        #expect(higher.flushIntervalMs == 600_000)
        #expect(h.warnings.count == 2)

        let other = RemoteHarness()
        #expect(
            other.remote(
                #"{"flush_at":101,"flush_interval_ms":600001,"sample_rate":1.5,"diagnostics_sample_rate":-0.1}"#)
                == .none)
        #expect(other.warnings.count == 4)
    }

    @Test("diagnostics cannot be switched on when the code switched them off")
    func diagnostics() {
        let code = h.code { $0.logging.sendDiagnostics = false }
        #expect(h.remote(#"{"diagnostics_sample_rate":0.5}"#, code: code).diagnosticsSampleRate == nil)
        #expect(h.remote(#"{"diagnostics_sample_rate":0}"#, code: code).diagnosticsSampleRate == 0.0)
    }

    @Test(
        "values of the wrong type are ignored with a warning, the rest still applies; a list with a non-string entry is invalid as a whole"
    )
    func wrongTypes() {
        let remote = h.remote(
            #"{"enabled":"false","autocapture_off":"sessions","flush_at":50.5,"flush_interval_ms":"60000","sample_rate":true,"diagnostics_sample_rate":0.25}"#
        )
        #expect(remote.enabled)
        #expect(remote.autocaptureOff.isEmpty)
        #expect(remote.flushAt == nil)
        #expect(remote.flushIntervalMs == nil)
        #expect(remote.sampleRate == nil)
        #expect(remote.diagnosticsSampleRate == 0.25)
        #expect(h.warnings.count == 5)

        let other = RemoteHarness()
        #expect(other.remote(#"{"autocapture_off":["sessions",3]}"#).autocaptureOff.isEmpty)
        #expect(other.warnings.count == 1)
    }

    @Test("unknown keys and autocapture types are ignored quietly; whole-number rates are accepted")
    func unknownKeys() {
        let remote = h.remote(#"{"replay_rate":0.1,"autocapture_off":["taps","deep_links"]}"#)
        #expect(remote.autocaptureOff == [.deepLinks])
        #expect(h.warnings.isEmpty)
        #expect(h.support.test.logger.lines.contains { $0.level == .debug && $0.message.contains("\"replay_rate\"") })
        #expect(h.support.test.logger.lines.contains { $0.level == .debug && $0.message.contains("\"taps\"") })
        #expect(h.remote(#"{"sample_rate":1}"#).sampleRate == 1.0)
        #expect(h.remote(#"{"sample_rate":0}"#).sampleRate == 0.0)
    }

    @Test("a body that is not one JSON object is not parsed")
    func notAnObject() {
        for body in ["[1,2]", "{\"enabled\":", "<html>", "{} trailing"] {
            #expect(RemoteConfig.parseBody(body) == nil, Comment(rawValue: body))
        }
    }
}

@Suite("Sampling")
struct SamplingTests {
    @Test("is stable for a device id; rates of 0 and 1 are exact; a lower rate is inside every higher rate")
    func stable() {
        for i in 0..<100 {
            let id = "device-\(i)"
            let first = Sampling.isIn(id, rate: 0.5, purpose: .events)
            for _ in 0..<3 { #expect(Sampling.isIn(id, rate: 0.5, purpose: .events) == first) }
            if Sampling.isIn(id, rate: 0.2, purpose: .events) {
                #expect(Sampling.isIn(id, rate: 0.6, purpose: .events))
            }
        }
        #expect(Sampling.isIn("any", rate: 1.0, purpose: .events))
        #expect(!Sampling.isIn("any", rate: 0.0, purpose: .events))
    }

    @Test("splits a population close to the rate, and events and diagnostics draw independently")
    func population() {
        let ids = (0..<20_000).map { "0192e4a1-7c3f-7a2b-8d4e-\(String(format: "%012d", $0))" }
        for rate in [0.01, 0.1, 0.5, 0.9] {
            let share = Double(ids.filter { Sampling.isIn($0, rate: rate, purpose: .events) }.count) / Double(ids.count)
            #expect(abs(share - rate) < 0.015, "rate \(rate): \(share)")
        }
        let both = ids.prefix(10_000).filter {
            Sampling.isIn($0, rate: 0.5, purpose: .events) && Sampling.isIn($0, rate: 0.5, purpose: .diagnostics)
        }.count
        #expect(abs(Double(both) / 10_000 - 0.25) < 0.02)
    }
}

@Suite("RemoteConfigClient")
struct RemoteConfigClientTests {
    let h = RemoteHarness()

    @Test("200 saves the values and the ETag; a restart applies them")
    func save() throws {
        h.transport.enqueue(h.ok(#"{"flush_at":60,"autocapture_off":["screen_views"]}"#))
        h.client().fetch()
        let request = try #require(h.transport.requests.first)
        #expect(request.url.absoluteString == "https://api.rubicon.example/v1/config")
        #expect(request.headers.isEmpty)
        #expect(request.body == nil)
        #expect(request.method == .get)
        #expect(
            h.store.remoteConfig
                == RemoteConfigCache(
                    etag: "\"v1\"",
                    values: ["flush_at": .int(60), "autocapture_off": .array([.string("screen_views")])]))
        h.store.persist()

        let effective = h.client(store: h.deviceStore(), flags: RuntimeFlags()).startup()
        #expect(effective.snapshot.flushAt == 60)
        #expect(!effective.snapshot.autocapture.contains(.screenViews))
        #expect(effective.collecting)
    }

    @Test("the saved ETag is sent and 304 keeps the values; 404 deletes them")
    func etagAnd404() throws {
        let saved = RemoteConfigCache(etag: "\"v1\"", values: ["flush_at": .int(60)])
        h.store.updateRemoteConfig(saved)
        h.transport.enqueue(
            .httpError(code: 304, body: nil, retryAfterMs: nil), .httpError(code: 404, body: nil, retryAfterMs: nil))
        h.client().fetch()
        #expect(try #require(h.transport.requests.first).headers == ["If-None-Match": "\"v1\""])
        #expect(h.store.remoteConfig == saved)
        h.client().fetch()
        #expect(h.store.remoteConfig == nil)
        #expect(h.failedWarnings == 0)
    }

    @Test("5xx, a network failure or a malformed body keep the last valid values with one warning")
    func failures() {
        let saved = RemoteConfigCache(etag: "\"v1\"", values: ["flush_at": .int(60)])
        h.store.updateRemoteConfig(saved)
        h.transport.enqueue(
            .httpError(code: 503, body: nil, retryAfterMs: nil),
            .networkFailure(kind: .dns, cause: URLError(.cannotFindHost)),
            h.ok("<html>"), .success(code: 200))
        for _ in 0..<4 { h.client().fetch() }
        #expect(h.store.remoteConfig == saved)
        #expect(h.failedWarnings == 1)
    }

    @Test("the kill switch stops collection at once and stays off at the next launch; switching back on waits")
    func killSwitch() {
        h.transport.enqueue(h.ok(#"{"enabled":false}"#))
        h.client().fetch()
        #expect(!h.flags.isCollecting)
        h.store.persist()
        #expect(!h.client(store: h.deviceStore(), flags: RuntimeFlags()).startup().collecting)

        let other = RemoteHarness()
        other.store.updateRemoteConfig(RemoteConfigCache(etag: nil, values: ["enabled": .bool(false)]))
        let running = other.client()
        #expect(!running.startup().collecting)
        other.transport.enqueue(other.ok(#"{"enabled":true}"#))
        running.fetch()
        #expect(!other.flags.isCollecting)
        #expect(other.client(flags: RuntimeFlags()).startup().collecting)
    }

    @Test(
        "switching off network requests applies at once, other types at the next launch; code switches clear the flag at startup"
    )
    func networkRequests() {
        h.transport.enqueue(h.ok(#"{"autocapture_off":["network_requests","screen_views"]}"#))
        let running = h.client()
        let before = running.startup()
        running.fetch()
        #expect(!h.flags.isCapturingNetworkRequests)
        #expect(before.snapshot.autocapture.contains(.screenViews))

        let flags = RuntimeFlags()
        _ = h.client(flags: flags, code: h.code { $0.autocapture.enabled.remove(.networkRequests) }).startup()
        #expect(!flags.isCapturingNetworkRequests)
    }

    @Test("a device outside the sample rate collects nothing; diagnostics follow the code switch and their own rate")
    func sampling() {
        h.store.updateRemoteConfig(RemoteConfigCache(etag: nil, values: ["sample_rate": .int(0)]))
        let effective = h.client().startup()
        #expect(!effective.collecting)
        #expect(!h.flags.isCollecting)

        let other = RemoteHarness()
        #expect(other.client().startup().sendsDiagnostics)
        other.store.updateRemoteConfig(RemoteConfigCache(etag: nil, values: ["diagnostics_sample_rate": .int(0)]))
        #expect(!other.client().startup().sendsDiagnostics)
        #expect(!other.client(code: other.code { $0.logging.sendDiagnostics = false }).startup().sendsDiagnostics)
    }

    @Test("saved values are validated again against the code of this launch")
    func revalidated() {
        h.store.updateRemoteConfig(RemoteConfigCache(etag: nil, values: ["flush_at": .int(30)]))
        #expect(h.client(code: h.code { $0.flush.at = 50 }).startup().snapshot.flushAt == 50)
    }

    @Test("runtime flags only turn off")
    func flags() {
        let flags = RuntimeFlags(collecting: false, capturingNetworkRequests: true)
        #expect(!flags.isCollecting)
        #expect(flags.isCapturingNetworkRequests)
        flags.stopCapturingNetworkRequests()
        #expect(!flags.isCapturingNetworkRequests)
    }
}
