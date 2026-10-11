import Foundation

/// Why `Json.write` refused a tree: a bug in the caller, since the normalizer never produces it.
package enum JsonError: Error, Equatable {
    /// NaN or an infinity, which JSON cannot carry; the normalizer drops them (Serialization 2).
    case notFinite(path: String)
}

/// The only code in the SDK that touches `JSONSerialization` (iOS Serialization 1), as all five
/// reference SDKs do. Writing takes a `PropertyValue` tree, which keeps `true` and `1` apart because
/// the conversion to Foundation objects starts from the typed enum. Known behaviours of the writer,
/// each pinned by a test so that a Foundation change is noticed:
///
/// - `null` is written as `null`: `{"coupon":null}`;
/// - a whole-number `Double` is written as an integer: `50.0` becomes `50`, as on Android;
/// - `/` is escaped as `\/`, which is valid JSON; tests compare JSON structurally, never as text;
/// - a non-integral double carries seventeen significant digits: `49.9` becomes `49.899999999999999`
///   and `1e21` becomes `1e+21`, where Android writes `49.9` and `1.0E21`. The values are the same
///   IEEE doubles; the backend parses numbers as doubles and never compares raw text;
/// - NaN and infinity never reach the writer; `write` throws `JsonError` for them.
///
/// Reading exists only for the three store files (Disk 7) and for the corruption and age check of
/// stored lines (Disk 3, 5); events are never parsed back into objects. `JsonFields` reads each
/// field with a type check and never falls back to a default.
package enum Json {
    /// A compact JSON object for `object`, keys sorted: one event line, or a store file.
    package static func write(_ object: [String: PropertyValue]) throws(JsonError) -> String {
        let foundation = try toFoundation(.object(object), path: "")
        do {
            let data = try JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        } catch {
            // Only a non-finite number makes JSONSerialization refuse a tree of these types, and
            // those are caught above; anything else would be a Foundation bug.
            throw JsonError.notFinite(path: "")
        }
    }

    /// Parses `text` as one JSON object; `nil` when it is not valid JSON, not an object, or has
    /// anything but whitespace after the object.
    package static func readObject(_ text: String) -> JsonFields? {
        guard let data = text.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data, options: []),
            let object = value as? [String: Any]
        else { return nil }
        return JsonFields(object)
    }

    /// The `PropertyValue` for a value `JSONSerialization` parsed; `nil` for anything it never
    /// produces.
    package static func fromFoundation(_ value: Any) -> PropertyValue? {
        switch value {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if isBoolean(number) { return .bool(number.boolValue) }
            if let integral = integral(number) { return .int(integral) }
            return .double(number.doubleValue)
        case let array as [Any]:
            var out: [PropertyValue] = []
            out.reserveCapacity(array.count)
            for element in array {
                guard let converted = fromFoundation(element) else { return nil }
                out.append(converted)
            }
            return .array(out)
        case let object as [String: Any]:
            var out: [String: PropertyValue] = [:]
            for (key, element) in object {
                guard let converted = fromFoundation(element) else { return nil }
                out[key] = converted
            }
            return .object(out)
        default:
            return nil
        }
    }

    /// `true` for Foundation's two boolean singletons, however the value was created (iOS Public API 5).
    package static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// The whole number an `NSNumber` holds, or `nil` for a boolean, a fraction or a value beyond `Int64`.
    package static func integral(_ number: NSNumber) -> Int64? {
        if isBoolean(number) { return nil }
        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q", "C", "S", "I", "L":
            return number.int64Value
        case "Q":
            // An unsigned 64-bit value above Int64.max reads back negative through int64Value.
            return number.uint64Value <= UInt64(Int64.max) ? Int64(number.uint64Value) : nil
        default:
            return nil
        }
    }

    private static func toFoundation(_ value: PropertyValue, path: String) throws(JsonError) -> Any {
        switch value {
        case .null: return NSNull()
        case .string(let s): return s
        case .int(let i): return NSNumber(value: i)
        case .bool(let b): return NSNumber(value: b)
        case .double(let d):
            if !d.isFinite { throw JsonError.notFinite(path: path) }
            return NSNumber(value: d)
        case .array(let items):
            var out: [Any] = []
            out.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                out.append(try toFoundation(item, path: "\(path)[\(index)]"))
            }
            return out
        case .object(let entries):
            var out: [String: Any] = [:]
            for (key, entry) in entries {
                out[key] = try toFoundation(entry, path: path.isEmpty ? key : "\(path).\(key)")
            }
            return out
        }
    }
}

/// Typed, checked access to a parsed JSON object. Every getter returns `nil` when the key is
/// missing, holds JSON `null`, or holds a value of another type; nothing is coerced, so a string
/// `"123"` is not a number and a number is not a string.
package struct JsonFields {
    private let object: [String: Any]

    init(_ object: [String: Any]) {
        self.object = object
    }

    package func has(_ key: String) -> Bool {
        object[key] != nil
    }

    /// Whether `key` is present with the JSON value `null`.
    package func isNull(_ key: String) -> Bool {
        object[key] is NSNull
    }

    package var keys: Set<String> {
        Set(object.keys)
    }

    package func string(_ key: String) -> String? {
        value(key) as? String
    }

    package func bool(_ key: String) -> Bool? {
        guard let number = value(key) as? NSNumber, Json.isBoolean(number) else { return nil }
        return number.boolValue
    }

    /// An integral number that fits an `Int64`; `1.5` and `1.0E30` give `nil`.
    package func int64(_ key: String) -> Int64? {
        guard let number = value(key) as? NSNumber else { return nil }
        return Json.integral(number)
    }

    /// An integral number that fits an `Int`.
    package func int(_ key: String) -> Int? {
        int64(key).flatMap { Int(exactly: $0) }
    }

    /// Any number but a boolean, as a `Double`.
    package func double(_ key: String) -> Double? {
        guard let number = value(key) as? NSNumber, !Json.isBoolean(number) else { return nil }
        return number.doubleValue
    }

    package func fields(_ key: String) -> JsonFields? {
        (value(key) as? [String: Any]).map(JsonFields.init)
    }

    /// A nested object as property values; `nil` when absent or not an object.
    package func object(_ key: String) -> [String: PropertyValue]? {
        guard let nested = value(key) as? [String: Any] else { return nil }
        if case .object(let values)? = Json.fromFoundation(nested) { return values }
        return nil
    }

    /// The whole object as property values.
    package func toPropertyValues() -> [String: PropertyValue] {
        if case .object(let values)? = Json.fromFoundation(object) { return values }
        return [:]
    }

    private func value(_ key: String) -> Any? {
        guard let raw = object[key], !(raw is NSNull) else { return nil }
        return raw
    }
}
