import Foundation

/// Something the normalizer dropped or changed. It names the property's `path` and the value's
/// `type`, never the value itself (Logging 4a).
package struct PropertyProblem: Sendable, Equatable, CustomStringConvertible {
    package enum Kind: Sendable, CaseIterable {
        /// A value of a type the SDK does not send.
        case unsupportedType
        /// NaN or an infinity.
        case notFinite
        /// A number or date that cannot be sent without losing it: a `UInt64` beyond `Int64`, a
        /// `Decimal` that is not finite, a year beyond 0000 to 9999.
        case outOfRange
        /// A key that is not a string, is blank, or is longer than 255 characters.
        case invalidKey
        /// A dictionary or array nested deeper than 3 levels.
        case tooDeep
        /// A string longer than 1024 characters, cut to 1024. Logged once per key, never a developer error.
        case truncated
        /// More than 256 properties; the extra ones were dropped, super properties first.
        case tooMany
        /// An event or screen name that is blank or longer than 255 characters.
        case invalidName

        package var code: Code {
            switch self {
            case .unsupportedType, .notFinite, .outOfRange, .invalidKey, .tooDeep: return .propertyDropped
            case .truncated: return .propertyTruncated
            case .tooMany: return .tooManyProperties
            case .invalidName: return .invalidEventName
            }
        }

        /// Whether `debug` turns it into a developer error (Serialization 2, 3).
        package var isDeveloperError: Bool {
            self != .truncated
        }
    }

    package var kind: Kind
    /// The key, with nested keys after dots and array positions in brackets: `cart.items[2]`.
    /// Empty for the event name and for a problem about the whole dictionary.
    package var path: String
    /// The type name of the offending value or key, when there is one.
    package var type: String?
    /// For `tooMany`: how many properties were dropped.
    package var count: Int

    package init(_ kind: Kind, path: String, type: String? = nil, count: Int = 0) {
        self.kind = kind
        self.path = path
        self.type = type
        self.count = count
    }

    /// The log line and developer error message: keys and types only.
    package var message: String {
        let type = type ?? "value"
        switch kind {
        case .unsupportedType: return "Property \"\(path)\" dropped: \(type) is not supported."
        case .notFinite: return "Property \"\(path)\" dropped: NaN and infinity are not supported."
        case .outOfRange: return "Property \"\(path)\" dropped: this \(type) cannot be sent without losing its value."
        case .invalidKey:
            let location = path.isEmpty ? "" : " in \"\(path)\""
            return "Property key\(location) dropped: keys are non-blank strings of at most 255 characters (\(type))."
        case .tooDeep: return "Property \"\(path)\" dropped: values nest at most 3 levels deep."
        case .truncated: return "Property \"\(path)\" truncated to 1024 characters."
        case .tooMany:
            return "\(count) properties dropped: an event has at most 256, super properties are dropped first."
        case .invalidName: return "Event dropped: its name is blank or longer than 255 characters."
        }
    }

    package var description: String { "PropertyProblem(\(kind), \"\(path)\")" }

    /// Logs `problems` with their codes and, with `debug`, reports each developer error first
    /// (`assertionFailure` in a debug build; the line is logged after it in a release build, so the
    /// outcome is the same as with `debug` off). A truncation is only logged, once per key.
    package static func report(_ problems: [PropertyProblem], debug: Bool, log: Log) {
        for problem in problems {
            if debug && problem.kind.isDeveloperError { log.developerError(problem.message) }
            let repeatKey = problem.kind == .truncated ? problem.path : nil
            log.warn(problem.kind.code, repeatKey: repeatKey) { problem.message }
        }
    }
}
