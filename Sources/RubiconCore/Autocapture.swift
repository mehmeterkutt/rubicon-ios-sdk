/// Event types the SDK captures by itself, switched with `autocapture.enabled` (Lifecycle 6). All
/// are on by default except `deepLinks`. Remote configuration can switch a type off but never on.
///
/// ```swift
/// config.autocapture.enabled.remove(.networkRequests)
/// ```
public enum Autocapture: String, Sendable, CaseIterable {
    /// `Application Opened` and `Application Backgrounded`.
    case appLifecycle = "app_lifecycle"
    /// `Application Installed` and `Application Updated`.
    case installUpdate = "install_update"
    /// `Session Started` and `Session Ended`.
    case sessions
    /// A screen view for each view controller shown (iOS Lifecycle 1, 2). Remove it in a SwiftUI
    /// app and call `screen` yourself.
    case screenViews = "screen_views"
    /// `Deep Link Opened`, off by default. The app forwards each link with `trackDeepLink`; the
    /// event carries the scheme, host, path, the five `utm_*` parameters and the referrer (iOS
    /// Lifecycle 3).
    case deepLinks = "deep_links"
    /// `Network Request` for the app's own HTTP calls; it takes effect only when the app forwards
    /// its `URLSession` delegate callbacks to `RubiconNetworkObserver`. A remote switch-off applies
    /// at once.
    case networkRequests = "network_requests"
}
