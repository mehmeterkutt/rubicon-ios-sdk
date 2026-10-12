import Foundation
import RubiconCore

/// Until step 7.2: always connected, no changes (the Android stand-in of log row 7.1).
final class AlwaysConnectedNetworkMonitor: NetworkMonitor, Sendable {
    func start() {}

    var isConnected: Bool { true }

    func addListener(_ listener: @escaping @Sendable (Bool) -> Void) -> any ListenerToken {
        NoListenerToken()
    }
}

/// Until step 7.3: no context values at all; every field is omitted (Context 3).
final class StaticContextProvider: ContextProvider, Sendable {
    func staticValues(disabled: Set<ContextField>) -> StaticValues { .none }

    func callTimeValues(disabled: Set<ContextField>) -> CallTimeValues { .none }

    func refresh(disabled: Set<ContextField>) {}
}

struct NoListenerToken: ListenerToken {
    func cancel() {}
}
