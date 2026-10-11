import Foundation

@testable import RubiconCore

/// The independent parser of the tests: `JSONDecoder` is a separate implementation from
/// `JSONSerialization` on Darwin (plan section 5). Structural comparison ignores key order,
/// spacing and escaping; numbers compare as doubles, as the backend parses them.
enum JSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// The same tree as a `PropertyValue` tree would render, numbers as doubles.
    init(_ value: PropertyValue) {
        switch value {
        case .string(let s): self = .string(s)
        case .int(let i): self = .number(Double(i))
        case .double(let d): self = .number(d)
        case .bool(let b): self = .bool(b)
        case .null: self = .null
        case .array(let items): self = .array(items.map(JSONValue.init))
        case .object(let entries): self = .object(entries.mapValues(JSONValue.init))
        }
    }
}
