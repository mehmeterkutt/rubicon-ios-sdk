/// A validated property, trait or super property value: what the SDK keeps after the dictionary a
/// caller passed has been checked and copied on the calling thread (iOS Public API 5). Hooks see
/// `Event.properties` as `[String: PropertyValue]`, so `true` and `1` are never confused and the
/// event is `Sendable` without further promises.
///
/// ```swift
/// var copy = event
/// copy.properties["tenant"] = .string(tenants.current())
/// if case let .double(amount)? = copy.properties["amount"], amount > 100 { ... }
/// ```
public enum PropertyValue: Sendable, Equatable {
    /// A string of at most 1024 characters.
    case string(String)
    /// A whole number; every integer type is widened to `Int64`.
    case int(Int64)
    /// A finite floating-point number.
    case double(Double)
    /// A boolean, told apart from a number at the boundary.
    case bool(Bool)
    /// JSON `null`: `NSNull` or an empty optional at the call.
    case null
    /// A list; nested at most three levels deep.
    case array([PropertyValue])
    /// An object with string keys; nested at most three levels deep.
    case object([String: PropertyValue])
}
