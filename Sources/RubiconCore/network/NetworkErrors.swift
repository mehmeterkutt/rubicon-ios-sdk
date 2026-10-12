import Foundation

/// The `error` of a failed captured call (Lifecycle 1, iOS HTTP 3): a fixed short value for the
/// common failures, `url_error_<code>` for any other `URLError`, `unknown` for anything else. Never
/// a message, which can carry URLs or data. The Android spelling `canceled` is kept.
package enum NetworkErrors {
    package static func name(for error: any Error) -> String {
        guard let urlError = error as? URLError else { return "unknown" }
        switch urlError.code {
        case .cancelled: return "canceled"
        case .timedOut: return "timeout"
        case .cannotFindHost, .dnsLookupFailed: return "unknown_host"
        case .cannotConnectToHost, .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return "connect"
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return "tls"
        default: return "url_error_\(urlError.code.rawValue)"
        }
    }
}
