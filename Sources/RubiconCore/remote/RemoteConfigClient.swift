import Foundation

/// Remote configuration (Configuration 1): values saved by the last launch restrict the code's
/// configuration at startup, and one background fetch per launch saves new values for the next one.
///
/// - `startup()` runs once, after `DeviceStore.load`, and gives the snapshot the SDK runs with.
/// - `fetch()` runs once per launch in the background: `GET {host}/v1/config` with `If-None-Match`,
///   also while consent is pending or the user opted out, since it carries no personal data
///   (Privacy 4). Only `enabled = false` and switching off `network_requests` take effect at once
///   (`RuntimeFlags`).
/// - A failure keeps the saved values and never stops the SDK (rule 4); a 404 means "no remote
///   values" and deletes them.
package final class RemoteConfigClient: Sendable {
    /// What the SDK runs with until the next launch.
    package struct Effective: Sendable {
        package var snapshot: ConfigSnapshot
        /// `false` when the kill switch is on or the device is outside `sample_rate`.
        package var collecting: Bool
        /// Whether `SDK Diagnostics` is sent: on in code and inside `diagnostics_sample_rate`.
        package var sendsDiagnostics: Bool
    }

    private static let notModified = 304
    private static let notFound = 404

    private let code: ConfigSnapshot
    private let deviceStore: DeviceStore
    private let transport: any HttpTransport
    private let flags: RuntimeFlags
    private let log: Log

    package init(
        code: ConfigSnapshot, deviceStore: DeviceStore, transport: any HttpTransport, flags: RuntimeFlags, log: Log
    ) {
        self.code = code
        self.deviceStore = deviceStore
        self.transport = transport
        self.flags = flags
        self.log = log
    }

    package func startup() -> Effective {
        let remote = deviceStore.remoteConfig.map { RemoteConfig.from($0.values, code: code, log: log) } ?? .none
        let snapshot = remote.restrict(code)
        let deviceId = deviceStore.state?.deviceId ?? ""
        let sampled = Sampling.isIn(deviceId, rate: remote.sampleRate ?? 1.0, purpose: .events)
        let collecting = remote.enabled && sampled
        let diagnostics =
            snapshot.sendDiagnostics
            && Sampling.isIn(deviceId, rate: remote.diagnosticsSampleRate ?? 1.0, purpose: .diagnostics)
        if !collecting { flags.stopCollecting() }
        if !snapshot.autocapture.contains(.networkRequests) { flags.stopCapturingNetworkRequests() }
        if !remote.enabled {
            log.info { "Remote configuration has switched the SDK off; nothing is collected or sent" }
        } else if !sampled {
            log.info { "This device is outside the remote sample rate; nothing is collected or sent" }
        }
        return Effective(snapshot: snapshot, collecting: collecting, sendsDiagnostics: diagnostics)
    }

    package func fetch() {
        var headers: [String: String] = [:]
        if let etag = deviceStore.remoteConfig?.etag { headers[Headers.ifNoneMatch] = etag }
        switch transport.execute(HttpRequest(method: .get, url: code.configURL, headers: headers)) {
        case .success(_, let body, let etag):
            guard let values = body.flatMap(RemoteConfig.parseBody) else {
                failed("the response is not a JSON object")
                return
            }
            deviceStore.updateRemoteConfig(RemoteConfigCache(etag: etag, values: values))
            applyNow(RemoteConfig.from(values, code: code, log: log))
            log.debug { "Remote configuration saved; it applies at the next launch" }
        case .httpError(let status, _, _):
            switch status {
            case Self.notModified:
                log.debug { "Remote configuration unchanged" }
            case Self.notFound:
                deviceStore.updateRemoteConfig(nil)
                log.debug { "No remote configuration for this key (404)" }
            default:
                failed("HTTP \(status)")
            }
        case .networkFailure(let kind, _):
            failed(kind.rawValue)
        }
    }

    private func applyNow(_ remote: RemoteConfig) {
        if !remote.enabled && flags.isCollecting {
            flags.stopCollecting()
            log.info { "Remote configuration switched the SDK off; collection and uploads stop now" }
        }
        if remote.autocaptureOff.contains(.networkRequests) && flags.isCapturingNetworkRequests {
            flags.stopCapturingNetworkRequests()
            log.info { "Remote configuration switched off network request capture" }
        }
    }

    private func failed(_ reason: String) {
        log.warn(.remoteConfigFailed) {
            "Could not fetch the remote configuration (\(reason)); the last valid values are kept"
        }
    }
}
