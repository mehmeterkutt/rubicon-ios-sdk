import Foundation

/// The hosts network capture records (Privacy 5c, Android log 7.6): exact names, and `*.` followed by
/// at least two labels for every subdomain of a domain (`*.shop.com`, not `*.com`), ignoring case.
/// An invalid pattern (a scheme, a path, a port, another wildcard) is a developer error with `debug`
/// on and is ignored with `INVALID_CAPTURE_HOST` otherwise.
package struct HostPatterns: Sendable, Equatable {
    private let exact: Set<String>
    // ".shop.com" for "*.shop.com".
    private let suffixes: [String]

    package static func parse(_ hosts: Set<String>, debug: Bool, log: Log?) -> HostPatterns {
        var exact: Set<String> = []
        var suffixes: [String] = []
        for raw in hosts.sorted() {
            let pattern = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if pattern.hasPrefix("*."), isDomain(String(pattern.dropFirst(2)), minLabels: 2) {
                suffixes.append(String(pattern.dropFirst()))
            } else if isDomain(pattern, minLabels: 1) {
                exact.insert(pattern)
            } else {
                let message =
                    "The network capture host \"\(raw)\" is invalid: use a host name such as api.shop.com "
                    + "or a wildcard such as *.shop.com; it is ignored"
                if debug { log?.developerError(message) }
                log?.warn(.invalidCaptureHost) { message }
            }
        }
        return HostPatterns(exact: exact, suffixes: suffixes)
    }

    package func matches(_ host: String) -> Bool {
        let name = host.lowercased()
        return exact.contains(name) || suffixes.contains { name.hasSuffix($0) }
    }

    package var isEmpty: Bool { exact.isEmpty && suffixes.isEmpty }

    private static func isDomain(_ name: String, minLabels: Int) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= minLabels && labels.allSatisfy(isLabel)
    }

    // [a-z0-9]([a-z0-9-]*[a-z0-9])?
    private static func isLabel(_ label: Substring) -> Bool {
        guard let first = label.first, let last = label.last else { return false }
        func alnum(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        return alnum(first) && alnum(last) && label.allSatisfy { alnum($0) || $0 == "-" }
    }
}
