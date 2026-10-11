import Foundation

/// Turns whatever the developer passes as properties, traits or super properties into
/// `[String: PropertyValue]` in one pass, in the order of the iOS conversion table (iOS
/// Serialization 2; Public API 3, Event Model 3, Serialization 2 and 3).
///
/// It never traps and never keeps a reference to the caller's collections; a bad value costs only
/// that value, and a bad element of a collection only that element. What it dropped or changed is
/// returned as `PropertyProblem`s for the caller to log or, in debug, report
/// (`PropertyProblem.report`).
package enum PropertyNormalizer {
    package static let maxKeyLength = 255
    package static let maxNameLength = 255
    package static let maxStringLength = 1024
    package static let maxProperties = 256
    package static let maxDepth = 3

    package struct Result: Sendable, Equatable {
        package var values: [String: PropertyValue]
        package var problems: [PropertyProblem]
    }

    /// Normalizes a dictionary from the public API. Keys are strings by type; the iteration order
    /// of a Swift dictionary decides which 256 are kept when there are more.
    package static func normalize(_ properties: [String: Any]) -> Result {
        var problems: [PropertyProblem] = []
        var values: [String: PropertyValue] = [:]
        var extra = 0
        for (key, value) in properties {
            guard let name = checkKey(key, parent: "", &problems) else { continue }
            if values.count == maxProperties {
                extra += 1
                continue
            }
            if let normalized = normalizeValue(value, path: name, level: 1, &problems) {
                values[name] = normalized
            }
        }
        if extra > 0 { problems.append(PropertyProblem(.tooMany, path: "", count: extra)) }
        return Result(values: values, problems: problems)
    }

    /// Merges super properties into an event's normalized properties: the event's own key wins,
    /// and above `maxProperties` the super properties are dropped first (Event Model 1,
    /// Serialization 3).
    package static func mergeSuperProperties(own: [String: PropertyValue], superProperties: [String: PropertyValue])
        -> Result
    {
        var merged: [String: PropertyValue] = [:]
        let room = maxProperties - own.count
        var dropped = 0
        for (key, value) in superProperties where own[key] == nil {
            if merged.count < room { merged[key] = value } else { dropped += 1 }
        }
        merged.merge(own) { _, ownValue in ownValue }
        let problems = dropped > 0 ? [PropertyProblem(.tooMany, path: "", count: dropped)] : []
        return Result(values: merged, problems: problems)
    }

    /// An event or screen name: 1 to 255 characters and not blank; never trimmed (Serialization 3).
    package static func checkName(_ name: String) -> PropertyProblem? {
        if isBlank(name) || name.utf16.count > maxNameLength { return PropertyProblem(.invalidName, path: "") }
        return nil
    }

    // MARK: - Keys

    private static func checkKey(_ key: Any, parent: String, _ problems: inout [PropertyProblem]) -> String? {
        let problem: String
        if let text = key as? String {
            if isBlank(text) {
                problem = "blank"
            } else if text.utf16.count > maxKeyLength {
                problem = "\(text.utf16.count) characters"
            } else {
                return text
            }
        } else {
            problem = typeName(of: key)
        }
        problems.append(PropertyProblem(.invalidKey, path: parent, type: problem))
        return nil
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy { $0.isWhitespace }
    }

    // MARK: - Values

    /// `nil` means dropped; a problem was recorded. JSON `null` is `.null`, a real value.
    private static func normalizeValue(_ raw: Any, path: String, level: Int, _ problems: inout [PropertyProblem])
        -> PropertyValue?
    {
        func drop(_ kind: PropertyProblem.Kind, _ type: String? = nil) -> PropertyValue? {
            problems.append(PropertyProblem(kind, path: path, type: type ?? typeName(of: raw)))
            return nil
        }
        // An empty optional, Optional.none or NSNull, is JSON null; a wrapped value is unwrapped.
        guard let value = unwrap(raw) else { return .null }
        if value is NSNull { return .null }
        // 1. Booleans before any number check: NSNumber(1) and NSNumber(true) are otherwise alike.
        if Json.isBoolean(value), let number = value as? NSNumber { return .bool(number.boolValue) }
        // 2. Decimal before the generic NSNumber path: NSDecimalNumber is an NSNumber whose
        //    doubleValue loses the decimal text (19.990000000000002).
        if value is NSDecimalNumber || type(of: value) == Decimal.self, let decimal = value as? Decimal {
            if decimal.isNaN || !decimal.isFinite { return drop(.outOfRange, "Decimal") }
            return Double(decimal.description).map(PropertyValue.double) ?? drop(.outOfRange, "Decimal")
        }
        // 3. Every other number, resolved by its Objective-C type code.
        if let number = value as? NSNumber {
            switch String(cString: number.objCType) {
            case "c", "s", "i", "l", "q", "C", "S", "I", "L":
                return .int(number.int64Value)
            case "Q":
                return number.uint64Value <= UInt64(Int64.max)
                    ? .int(Int64(number.uint64Value)) : drop(.outOfRange, "UInt64")
            case "f":
                // Through its decimal text, so 0.1 as a Float is sent as 0.1, not 0.10000000149011612.
                let float = number.floatValue
                guard float.isFinite else { return drop(.notFinite, "Float") }
                return Double(String(float)).map(PropertyValue.double) ?? drop(.notFinite, "Float")
            case "d":
                let double = number.doubleValue
                return double.isFinite ? .double(double) : drop(.notFinite, "Double")
            default:
                return drop(.unsupportedType)
            }
        }
        switch value {
        case let string as String:
            return .string(truncate(string, path: path, &problems))
        case let character as Character:
            return .string(truncate(String(character), path: path, &problems))
        case let date as Date:
            return IsoDates.format(date).map(PropertyValue.string) ?? drop(.outOfRange, "Date")
        case let url as URL:
            return .string(truncate(url.absoluteString, path: path, &problems))
        case let dictionary as [String: Any]:
            guard level <= maxDepth else { return drop(.tooDeep) }
            return .object(object(dictionary.map { ($0.key as Any, $0.value) }, path: path, level: level, &problems))
        case let dictionary as [AnyHashable: Any]:
            guard level <= maxDepth else { return drop(.tooDeep) }
            return .object(object(dictionary.map { ($0.key.base, $0.value) }, path: path, level: level, &problems))
        case let array as [Any]:
            guard level <= maxDepth else { return drop(.tooDeep) }
            return .array(list(array, path: path, level: level, &problems))
        default:
            break
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .enum where mirror.children.isEmpty:
            // A payload-free enum is its case name (the Android `name` rule); a
            // CustomStringConvertible enum gives its description instead, as documented. An
            // `@objc` enum has no case names at runtime and describes itself as
            // `Type(rawValue: n)`; it is sent as its integer, as the documentation says.
            let described = String(describing: value)
            if described.contains("(rawValue:"), let raw = value as? any RawRepresentable {
                return normalizeValue(raw.rawValue, path: path, level: level, &problems)
            }
            return .string(truncate(described, path: path, &problems))
        case .set, .collection:
            guard level <= maxDepth else { return drop(.tooDeep) }
            return .array(list(mirror.children.map(\.value), path: path, level: level, &problems))
        default:
            return drop(.unsupportedType)
        }
    }

    private static func object(_ entries: [(Any, Any)], path: String, level: Int, _ problems: inout [PropertyProblem])
        -> [String: PropertyValue]
    {
        var copy: [String: PropertyValue] = [:]
        for (key, value) in entries {
            guard let name = checkKey(key, parent: path, &problems) else { continue }
            if let normalized = normalizeValue(value, path: "\(path).\(name)", level: level + 1, &problems) {
                copy[name] = normalized
            }
        }
        return copy
    }

    private static func list(_ items: [Any], path: String, level: Int, _ problems: inout [PropertyProblem])
        -> [PropertyValue]
    {
        var copy: [PropertyValue] = []
        copy.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if let normalized = normalizeValue(item, path: "\(path)[\(index)]", level: level + 1, &problems) {
                copy.append(normalized)
            }
        }
        return copy
    }

    // Cut to 1024 UTF-16 units, as on Android, never inside a surrogate pair, with no marker
    // (Serialization 2, 3). A Swift String never holds an unpaired surrogate: Foundation replaces
    // one with U+FFFD when an NSString is bridged.
    private static func truncate(_ value: String, path: String, _ problems: inout [PropertyProblem]) -> String {
        let units = value.utf16
        guard units.count > maxStringLength else { return value }
        problems.append(PropertyProblem(.truncated, path: path, type: "String"))
        var end = units.index(units.startIndex, offsetBy: maxStringLength)
        if UTF16.isLeadSurrogate(units[units.index(before: end)]) { end = units.index(before: end) }
        return String(decoding: units[units.startIndex..<end], as: UTF16.self)
    }

    private static func unwrap(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        guard let child = mirror.children.first else { return nil }
        return unwrap(child.value)
    }

    private static func typeName(of value: Any) -> String {
        guard let unwrapped = unwrap(value) else { return "nil" }
        let name = String(describing: type(of: unwrapped))
        // Foundation's private subclasses (`__NSCFNumber`, `__NSCFString`) read better by their public name.
        if name.hasPrefix("__NSCF") || name.hasPrefix("NSTagged") {
            if unwrapped is NSNumber { return "NSNumber" }
            if unwrapped is NSString { return "NSString" }
        }
        return name
    }
}
