import Foundation

/// A token returned when a listener is added; cancelling it removes the listener.
package protocol ListenerToken: Sendable {
    func cancel()
}

/// Connectivity as the uploader and the network trigger see it (Retry 6, iOS Retry 1). Connected
/// means the platform's path is satisfied or needs only a connection attempt; before the first
/// update the monitor is optimistic. Listeners are called on the thread that observed the change
/// and must not block.
package protocol NetworkMonitor: AnyObject, Sendable {
    /// Starts watching, once, from the writer at startup. Starting cannot fail on iOS.
    func start()

    var isConnected: Bool { get }

    func addListener(_ listener: @escaping @Sendable (_ connected: Bool) -> Void) -> any ListenerToken
}
