import Foundation

/// How the `Rubicon` target sends the events it captures itself: automatic screen views and network
/// requests (Lifecycle 1, 5; iOS Lifecycle 1, 2, 5). Each event has `source == .auto` and is created
/// only while collecting; the writer drops it, uncounted, unless `gate` is in the effective set, so a
/// remote switch-off applies from the next launch (Lifecycle 6). Never traps: a bad name is a WARN
/// even in debug, since the call comes from the SDK's own callbacks.
package protocol AutomaticCapture: AnyObject, Sendable {
    func track(gate: Autocapture, name: String, properties: [String: Any])

    func screen(gate: Autocapture, name: String, properties: [String: Any])

    /// Whether a network request is captured now: `networkRequests` configured, not switched off
    /// remotely (at once, Lifecycle 6) and collecting. Read on every request; cheap.
    var capturesNetworkRequests: Bool { get }

    /// The host the SDK sends to, never captured.
    var sdkHost: String { get }

    var debug: Bool { get }

    var log: Log { get }
}
