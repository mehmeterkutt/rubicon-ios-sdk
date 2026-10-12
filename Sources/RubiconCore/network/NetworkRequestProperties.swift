import Foundation

/// The properties of `Network Request` (Lifecycle 1, Privacy 5c): only the method, the URL without
/// query or fragment, the status, the error type, the duration and the sizes; headers and bodies are
/// never read. Path segments that are all digits, a UUID or hexadecimal longer than 16 characters
/// become `:id` when masking is on.
package enum NetworkRequestProperties {
    package static let eventName = "Network Request"
    package static let mask = ":id"

    package static func build(
        method: String?, url: URL, statusCode: Int?, error: String?, durationMs: Int64, requestBytes: Int64?,
        responseBytes: Int64?, maskPathIds: Bool
    ) -> [String: Any] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = self.path(url, maskPathIds: maskPathIds)
        var properties: [String: Any] = [:]
        properties["method"] = method ?? "GET"
        properties["url"] = origin(components, url) + path
        if let host = components?.host ?? url.host, !host.isEmpty { properties["host"] = host }
        properties["path"] = path
        if let statusCode { properties["status_code"] = statusCode }
        if let error { properties["error"] = error }
        properties["duration_ms"] = durationMs
        if let requestBytes, requestBytes >= 0 { properties["request_bytes"] = requestBytes }
        if let responseBytes, responseBytes >= 0 { properties["response_bytes"] = responseBytes }
        return properties
    }

    /// The path as sent, with ids masked when asked; `/` for an empty path.
    package static func path(_ url: URL, maskPathIds: Bool) -> String {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let path = raw.isEmpty ? "/" : raw
        guard maskPathIds else { return path }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { isId(String($0)) ? mask : String($0) }
            .joined(separator: "/")
    }

    package static func isId(_ segment: String) -> Bool {
        if segment.isEmpty { return false }
        if segment.allSatisfy(\.isASCIIDigit) { return true }
        if isUUID(segment) { return true }
        return segment.count > 16 && segment.allSatisfy(\.isHexDigit)
    }

    private static func isUUID(_ text: String) -> Bool {
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        let lengths = [8, 4, 4, 4, 12]
        guard groups.count == 5 else { return false }
        for (group, length) in zip(groups, lengths) where group.count != length || !group.allSatisfy(\.isHexDigit) {
            return false
        }
        return true
    }

    // scheme://host[:port], the port only when it is not the scheme's default, IPv6 in brackets.
    private static func origin(_ components: URLComponents?, _ url: URL) -> String {
        let scheme = components?.scheme ?? url.scheme ?? "https"
        var host = components?.host ?? url.host ?? ""
        if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }
        var port = ""
        if let value = components?.port ?? url.port, value != defaultPort(scheme) { port = ":\(value)" }
        return "\(scheme)://\(host)\(port)"
    }

    private static func defaultPort(_ scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
