import Foundation

/// What a deep link may reveal (Privacy 5b, iOS Lifecycle 3): scheme, host, path, the five `utm_*`
/// parameters and the referrer, a bundle identifier or a URL's host. Never another query parameter,
/// never the fragment; the list is fixed, because an extensible one invites tokens. The path is sent
/// as it is: tokens in a path are the app's to mask in `beforeSend`. Unknown or empty values are left
/// out.
package enum DeepLink {
    package static let eventName = "Deep Link Opened"
    package static let utmParameters = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"]

    package static func properties(url: URL, referrer: String?) -> [String: String] {
        var properties: [String: String] = [:]
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        put(&properties, "scheme", url.scheme)
        put(&properties, "host", components?.host ?? url.host)
        put(&properties, "path", components?.path ?? url.path)
        if let items = components?.queryItems {
            for name in utmParameters {
                put(&properties, name, items.first { $0.name == name }?.value)
            }
        }
        put(&properties, "referrer", referrer)
        return properties
    }

    /// The referrer of a universal link: the host of the page that linked, never its path or query.
    package static func referrer(of url: URL?) -> String? {
        url?.host
    }

    private static func put(_ properties: inout [String: String], _ key: String, _ value: String?) {
        guard let value, !value.allSatisfy(\.isWhitespace) else { return }
        properties[key] = value
    }
}
