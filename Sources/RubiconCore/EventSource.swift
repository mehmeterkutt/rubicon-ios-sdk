/// Who created an event (Lifecycle 5): sent as `"source": "app"` or `"source": "auto"`. Only the
/// SDK sets it. Values may be added in minor versions; a `switch` over it should keep a `default`.
public enum EventSource: String, Sendable, CaseIterable {
    /// A call by the app: `track`, `screen` or `identify`.
    case app
    /// Captured by the SDK itself, such as `Application Opened` or an automatic screen view.
    case auto
}
