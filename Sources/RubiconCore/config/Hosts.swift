import Foundation

/// The `host` rules of Configuration 3 and Android log 3.1 (iOS Configuration 3): a base URL with
/// an `http` or `https` scheme, a host name and an optional path prefix, such as
/// `https://intranet.example.com/analytics`. Trailing slashes are removed so endpoints can be
/// appended: `{host}/v1/batch`, `{host}/v1/config`. Foundation's `URL(string:)` accepts almost
/// anything, so the checks go through `URLComponents`.
package enum Hosts {
    /// The normalized base URL text, or `nil` when `host` is not a valid one.
    package static func normalize(_ host: String) -> String? {
        guard !host.isEmpty, host == host.trimmingCharacters(in: .whitespacesAndNewlines),
            let components = URLComponents(string: host),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let name = components.host, !name.isEmpty,
            components.query == nil, components.fragment == nil, components.user == nil, components.password == nil
        else { return nil }
        var trimmed = Substring(host)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    /// The parsed form of a normalized host, for building requests.
    package static func url(_ normalizedHost: String) -> URL? {
        URL(string: normalizedHost)
    }

    /// Whether a normalized host sends in cleartext, which is logged as a WARN (Configuration 3).
    package static func isCleartext(_ normalizedHost: String) -> Bool {
        normalizedHost.lowercased().hasPrefix("http://")
    }
}
