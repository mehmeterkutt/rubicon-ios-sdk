import Foundation
import Network
import RubiconCore

/// One `NWPathMonitor` for the whole instance (Retry 6, Context 2; iOS Retry 1, iOS Context 2): it
/// decides whether to try an upload, wakes the uploader when the network returns, ends a network
/// wait, and gives `network.type` to the context.
///
/// - Started once by the writer, on its own serial queue, never cancelled. Starting cannot fail and
///   needs no permission, so the Android fallbacks do not exist here.
/// - Connected means the last path is `.satisfied` or `.requiresConnection` (an on-demand VPN that the
///   SDK's own request would open). Before the first update the monitor is optimistic.
/// - `isExpensive` and `isConstrained` are not used. The handler must not block: it updates two
///   values and calls the listeners, which only send a message.
// The state is a `Locked` value; `pathUpdateHandler` runs on `queue` and the listeners outside the lock.
final class PathNetworkMonitor: NetworkMonitor, @unchecked Sendable {
    /// What a path says, reduced to what the SDK keeps (iOS Retry 1, iOS Context 1).
    struct Reading: Equatable, Sendable {
        var connected: Bool
        /// `wifi`, `cellular` or `ethernet`; `nil` when unknown or offline.
        var networkType: String?

        static func of(status: NWPath.Status, interfaces: [NWInterface.InterfaceType]) -> Reading {
            let connected = status == .satisfied || status == .requiresConnection
            let type: String?
            if interfaces.contains(.wifi) {
                type = "wifi"
            } else if interfaces.contains(.cellular) {
                type = "cellular"
            } else if interfaces.contains(.wiredEthernet) {
                type = "ethernet"
            } else {
                type = nil
            }
            return Reading(connected: connected, networkType: connected ? type : nil)
        }
    }

    private struct State {
        var reading: Reading?
        var started = false
        var nextId = 0
        var listeners: [Int: @Sendable (Bool) -> Void] = [:]
    }

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.rubicon.analytics.network")
    private let state = Locked(State())

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
    }

    /// Starts the monitor once; later calls do nothing.
    func start() {
        guard
            state.withLock({ s in
                if s.started { return false }
                s.started = true
                return true
            })
        else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.apply(Reading.of(status: path.status, interfaces: path.availableInterfaces.map(\.type)))
        }
        monitor.start(queue: queue)
    }

    /// Optimistic until the first path arrives (iOS Retry 1).
    var isConnected: Bool { state.current.reading?.connected ?? true }

    /// The current network type for the context cache; `nil` before the first path or when offline.
    var networkType: String? { state.current.reading?.networkType }

    /// `true` once a path was delivered; for the simulator test.
    var hasPath: Bool { state.current.reading != nil }

    func addListener(_ listener: @escaping @Sendable (Bool) -> Void) -> any ListenerToken {
        let id: Int = state.withLock { s in
            s.nextId += 1
            s.listeners[s.nextId] = listener
            return s.nextId
        }
        return Handle { [state] in state.withLock { _ = $0.listeners.removeValue(forKey: id) } }
    }

    /// Takes a path reading; `pathUpdateHandler` calls it, and tests do directly. Listeners hear a
    /// change of connectivity only, not of type.
    func apply(_ reading: Reading) {
        let (changed, listeners): (Bool, [@Sendable (Bool) -> Void]) = state.withLock { s in
            // Optimistic until the first path: a first path that is connected changes nothing.
            let before = s.reading?.connected ?? true
            s.reading = reading
            return (before != reading.connected, Array(s.listeners.values))
        }
        if changed {
            for listener in listeners { listener(reading.connected) }
        }
    }

    private struct Handle: ListenerToken {
        let remove: @Sendable () -> Void

        func cancel() { remove() }
    }
}
