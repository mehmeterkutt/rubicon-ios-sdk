import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("Configuration defaults and enums")
struct ConfigurationDefaultsTests {
    @Test("every setting has its decided default")
    func defaults() {
        let config = AnalyticsConfiguration(apiKey: "rk_test")

        #expect(config.apiKey == "rk_test")
        #expect(config.host == "https://api.rubicon.example")
        #expect(config.host == AnalyticsConfiguration.defaultHost)
        #expect(config.debug == AnalyticsConfiguration.defaultDebug)
        #expect(config.flush.at == 30)
        #expect(config.flush.intervalMs == 60_000)
        #expect(config.flush.immediateEvents.isEmpty)
        #expect(config.session.backgroundTimeoutMs == 300_000)
        #expect(config.autocapture.enabled == Set(Autocapture.allCases).subtracting([.deepLinks]))
        #expect(config.context.disabledFields.isEmpty)
        #expect(config.privacy.defaultConsent == .granted)
        #expect(config.privacy.persistConsent)
        #expect(config.logging.level == .warn)
        #expect(config.logging.logger == nil)
        #expect(config.logging.sendDiagnostics)
        #expect(config.network.headers.isEmpty)
    }

    @Test("the debug default follows the build configuration")
    func debugDefault() {
        #if DEBUG
            #expect(AnalyticsConfiguration.defaultDebug)
        #else
            #expect(!AnalyticsConfiguration.defaultDebug)
        #endif
    }

    @Test("the default configuration validates without issues")
    func defaultValidates() throws {
        let result = ConfigValidator.validate(AnalyticsConfiguration(apiKey: "rk_test"))
        let snapshot = try #require(result.snapshot)

        #expect(result.issues.isEmpty)
        #expect(snapshot.batchURL.absoluteString == "https://api.rubicon.example/v1/batch")
        #expect(snapshot.configURL.absoluteString == "https://api.rubicon.example/v1/config")
        #expect(snapshot.flushAt == 30)
        #expect(snapshot.autocapture == Set(Autocapture.allCases).subtracting([.deepLinks]))
    }

    @Test("the enums hold the decided values and wire names")
    func enums() {
        #expect(
            Autocapture.allCases.map(\.rawValue) == [
                "app_lifecycle", "install_update", "sessions", "screen_views", "deep_links", "network_requests",
            ])
        #expect(Consent.allCases.map(\.rawValue) == ["granted", "pending"])
        #expect(ContextField.allCases.count == 16)
        #expect(!ContextField.allCases.contains { $0.rawValue.hasPrefix("library") })
    }

    @Test("descriptions never show the key or header values")
    func descriptions() throws {
        var config = AnalyticsConfiguration(apiKey: "rk_live_secret")
        config.network.headers = ["X-Gateway-Token": "token-123"]
        let snapshot = try #require(ConfigValidator.validate(config).snapshot)

        #expect(config.description == "AnalyticsConfiguration(host: https://api.rubicon.example)")
        #expect(!snapshot.description.contains("rk_live_secret"))
        #expect(!snapshot.description.contains("token-123"))
    }
}

@Suite("Configuration validation")
struct ConfigValidatorTests {
    let test = TestPlatform()
    let counted = Locked<[Code]>([])

    private func log() -> Log {
        Log(
            level: .debug, logger: nil, platformLogger: test.logger.asLogger,
            issues: { [counted] code in counted.withLock { $0.append(code) } },
            developerError: { [test] message in test.developerErrors.withLock { $0.append(message) } })
    }

    private func config(_ change: (inout AnalyticsConfiguration) -> Void = { _ in }) -> AnalyticsConfiguration {
        var config = AnalyticsConfiguration(apiKey: "rk_test")
        change(&config)
        return config
    }

    // Validates and reports as the factory will.
    private func start(_ config: AnalyticsConfiguration, debug: Bool) -> ConfigSnapshot? {
        let result = ConfigValidator.validate(config)
        result.report(debug: debug, log: log())
        return result.snapshot
    }

    @Test("flush.at accepts 1 to 100 and is clamped outside, with one WARN and a developer error in debug")
    func flushAt() throws {
        #expect(try #require(start(config { $0.flush.at = 1 }, debug: true)).flushAt == 1)
        #expect(try #require(start(config { $0.flush.at = 100 }, debug: true)).flushAt == 100)
        #expect(counted.current.isEmpty)
        #expect(test.developerErrors.current.isEmpty)

        #expect(try #require(start(config { $0.flush.at = 0 }, debug: false)).flushAt == 1)
        #expect(try #require(start(config { $0.flush.at = 101 }, debug: false)).flushAt == 100)
        #expect(try #require(start(config { $0.flush.at = Int.min }, debug: false)).flushAt == 1)
        #expect(counted.current == [.settingOutOfBounds, .settingOutOfBounds, .settingOutOfBounds])
        #expect(test.logger.lines.allSatisfy { $0.level == .warn || $0.level == .debug })
        #expect(test.developerErrors.current.isEmpty)

        _ = start(config { $0.flush.at = 0 }, debug: true)
        #expect(test.developerErrors.current == ["flush.at is 0, outside 1 to 100; 1 is used."])
    }

    @Test("flush.intervalMs and session.backgroundTimeoutMs bounds")
    func intervalsAndTimeouts() throws {
        #expect(try #require(start(config { $0.flush.intervalMs = 1_000 }, debug: true)).flushIntervalMs == 1_000)
        #expect(try #require(start(config { $0.flush.intervalMs = 600_000 }, debug: true)).flushIntervalMs == 600_000)
        #expect(try #require(start(config { $0.flush.intervalMs = 999 }, debug: false)).flushIntervalMs == 1_000)
        #expect(try #require(start(config { $0.flush.intervalMs = 600_001 }, debug: false)).flushIntervalMs == 600_000)
        #expect(
            try #require(start(config { $0.session.backgroundTimeoutMs = 10_000 }, debug: true))
                .sessionBackgroundTimeoutMs == 10_000)
        #expect(
            try #require(start(config { $0.session.backgroundTimeoutMs = 7_200_000 }, debug: true))
                .sessionBackgroundTimeoutMs == 7_200_000)
        #expect(
            try #require(start(config { $0.session.backgroundTimeoutMs = 9_999 }, debug: false))
                .sessionBackgroundTimeoutMs == 10_000)
        #expect(
            try #require(start(config { $0.session.backgroundTimeoutMs = 7_200_001 }, debug: false))
                .sessionBackgroundTimeoutMs == 7_200_000)
        #expect(counted.current.count == 4)
        _ = start(config { $0.session.backgroundTimeoutMs = 1 }, debug: true)
        #expect(test.developerErrors.current.count == 1)
    }

    @Test(
        "a blank key stops the SDK with an ERROR in release and a developer error in debug",
        arguments: ["", " ", "\t\n"])
    func blankKey(key: String) {
        #expect(start(AnalyticsConfiguration(apiKey: key), debug: false) == nil)
        #expect(counted.current == [.invalidApiKey])
        #expect(test.logger.lines.map(\.level) == [.error])
        _ = start(AnalyticsConfiguration(apiKey: key), debug: true)
        #expect(test.developerErrors.current == ["The API key is blank; the SDK does nothing."])
    }

    @Test("the key never appears in a log line")
    func keyNeverLogged() throws {
        let snapshot = try #require(start(config { $0.flush.at = 0 }, debug: false))
        #expect(snapshot.apiKey == "rk_test")
        var secret = AnalyticsConfiguration(apiKey: "rk_live_secret")
        secret.flush.at = 0
        _ = start(secret, debug: false)
        #expect(!test.logger.messages.contains { $0.contains("rk_live_secret") })
    }

    @Test(
        "a base URL is accepted and its trailing slash removed",
        arguments: [
            ("https://api.example.com", "https://api.example.com"),
            ("https://api.example.com/", "https://api.example.com"),
            ("https://intranet.example.com/analytics", "https://intranet.example.com/analytics"),
            ("https://intranet.example.com/analytics/", "https://intranet.example.com/analytics"),
            ("https://api.example.com:8443", "https://api.example.com:8443"),
            ("HTTPS://api.example.com", "HTTPS://api.example.com"),
            ("https://10.0.0.5", "https://10.0.0.5"),
        ])
    func validHosts(input: String, expected: String) throws {
        let snapshot = try #require(start(config { $0.host = input }, debug: true))
        #expect(snapshot.host == expected)
        #expect(snapshot.batchURL.absoluteString == "\(expected)/v1/batch")
        #expect(test.developerErrors.current.isEmpty)
    }

    @Test(
        "an invalid host stops the SDK in release and is a developer error in debug",
        arguments: [
            "", "api.example.com", "ftp://api.example.com", "https://", "https:///path",
            "https://api.example.com?key=1",
            "https://api.example.com/#part", "https://user:pass@api.example.com", " https://api.example.com",
            "https://api.example.com ", "not a url", "https://exa mple.com",
        ])
    func invalidHosts(input: String) {
        #expect(start(config { $0.host = input }, debug: false) == nil, Comment(rawValue: input))
        #expect(counted.current == [.invalidHost])
        #expect(test.logger.lines.map(\.level) == [.error])
        _ = start(config { $0.host = input }, debug: true)
        #expect(test.developerErrors.current.count == 1)
    }

    @Test("http works with a WARN that mentions App Transport Security, in release and in debug")
    func cleartext() throws {
        let snapshot = try #require(start(config { $0.host = "http://10.0.2.2:8080" }, debug: true))
        #expect(snapshot.host == "http://10.0.2.2:8080")
        #expect(counted.current == [.cleartextHost])
        #expect(test.logger.lines.map(\.level) == [.warn])
        #expect(test.logger.messages.first?.contains("App Transport Security") == true)
        #expect(test.developerErrors.current.isEmpty)
        #expect(start(config { $0.host = "http://localhost:8080/" }, debug: false) != nil)
    }

    @Test(
        "a reserved header is ignored with a WARN in release and is a developer error in debug",
        arguments: [
            "Authorization", "authorization", "AUTHORIZATION", "Content-Type", "Content-Encoding", "Content-Length",
            "User-Agent", "Host", "If-None-Match", "X-Rubicon-Version", "x-rubicon-anything",
        ])
    func reservedHeaders(name: String) throws {
        let snapshot = try #require(
            start(config { $0.network.headers = [name: "v", "X-Gateway-Token": "t"] }, debug: false))
        #expect(snapshot.headers == ["X-Gateway-Token": "t"])
        #expect(counted.current == [.reservedHeader])
        _ = start(config { $0.network.headers = [name: "v"] }, debug: true)
        #expect(test.developerErrors.current.count == 1)
    }

    @Test("other headers are kept and their values never logged")
    func otherHeaders() throws {
        let snapshot = try #require(
            start(
                config { $0.network.headers = ["X-Gateway-Token": "token-123", "Authorization": "secret-456"] },
                debug: false))
        #expect(snapshot.headers == ["X-Gateway-Token": "token-123"])
        #expect(!test.logger.messages.contains { $0.contains("secret-456") || $0.contains("token-123") })
    }

    @Test("later changes to the caller's value never reach the snapshot")
    func valueSemantics() throws {
        var config = config {
            $0.flush.immediateEvents = ["Purchase"]
            $0.network.headers = ["X-A": "1"]
        }
        let snapshot = try #require(start(config, debug: true))

        config.flush.at = 5
        config.host = "https://other.example.com"
        config.flush.immediateEvents.insert("Signup")
        config.network.headers["X-B"] = "2"

        #expect(snapshot.flushAt == 30)
        #expect(snapshot.host == "https://api.rubicon.example")
        #expect(snapshot.immediateEvents == ["Purchase"])
        #expect(snapshot.headers == ["X-A": "1"])
    }

    @Test("every value reaches the snapshot")
    func everyValue() throws {
        let marker = Locked(0)
        let customLogger: RubiconLogger = { _, _, _ in marker.withLock { $0 += 1 } }
        let snapshot = try #require(
            start(
                config {
                    $0.debug = true
                    $0.flush.immediateEvents = ["Purchase"]
                    $0.autocapture.enabled = [.deepLinks]
                    $0.context.disabledFields = [.locale]
                    $0.privacy.defaultConsent = .pending
                    $0.privacy.persistConsent = false
                    $0.logging.level = .debug
                    $0.logging.logger = customLogger
                    $0.logging.sendDiagnostics = false
                }, debug: true))

        #expect(snapshot.debug)
        #expect(snapshot.autocapture == [.deepLinks])
        #expect(snapshot.disabledFields == [.locale])
        #expect(snapshot.defaultConsent == .pending)
        #expect(!snapshot.persistConsent)
        #expect(snapshot.logLevel == .debug)
        snapshot.logger?(.info, "x", nil)
        #expect(marker.current == 1)
        #expect(!snapshot.sendDiagnostics)
    }
}

@Suite("Hosts and Headers")
struct HostsTests {
    @Test("isReserved ignores case and covers the X-Rubicon- prefix")
    func reserved() {
        #expect(Headers.isReserved("authorization"))
        #expect(Headers.isReserved("X-RUBICON-Anything"))
        #expect(!Headers.isReserved("X-Gateway-Token"))
        #expect(!Headers.isReserved("Accept"))
    }

    @Test("cleartext detection is case-insensitive")
    func cleartext() {
        #expect(Hosts.isCleartext("HTTP://a"))
        #expect(!Hosts.isCleartext("https://a"))
    }
}
