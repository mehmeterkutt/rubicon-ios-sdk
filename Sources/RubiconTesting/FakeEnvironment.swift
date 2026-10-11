import Foundation
import RubiconCore

/// A listener registration backed by a dictionary entry; cancelling removes it.
final class ListenerHandle: ListenerToken, @unchecked Sendable {
    private let remove: @Sendable () -> Void

    init(remove: @escaping @Sendable () -> Void) {
        self.remove = remove
    }

    func cancel() {
        remove()
    }
}

/// Connectivity the test switches; listeners hear only real changes.
package final class FakeNetworkMonitor: NetworkMonitor, @unchecked Sendable {
    private struct State {
        var connected: Bool
        var starts = 0
        var nextId = 0
        var listeners: [Int: @Sendable (Bool) -> Void] = [:]
    }

    // Guarded by `state`; listeners are called outside the lock.
    private let state: Locked<State>

    package init(connected: Bool = true) {
        state = Locked(State(connected: connected))
    }

    /// How many times the SDK started it.
    package var starts: Int { state.current.starts }

    package func start() {
        state.withLock { $0.starts += 1 }
    }

    package var isConnected: Bool { state.current.connected }

    package func addListener(_ listener: @escaping @Sendable (Bool) -> Void) -> any ListenerToken {
        let id: Int = state.withLock { s in
            s.nextId += 1
            s.listeners[s.nextId] = listener
            return s.nextId
        }
        return ListenerHandle { [state] in state.withLock { _ = $0.listeners.removeValue(forKey: id) } }
    }

    package func setConnected(_ value: Bool) {
        let listeners: [@Sendable (Bool) -> Void]? = state.withLock { s in
            if s.connected == value { return nil }
            s.connected = value
            return Array(s.listeners.values)
        }
        for listener in listeners ?? [] { listener(value) }
    }
}

/// Foreground, background and protected data the test switches; listeners hear only real changes.
package final class FakeLifecycleSource: LifecycleSource, @unchecked Sendable {
    private struct State {
        var foreground: Bool
        var protectedData: Bool
        var starts = 0
        var nextId = 0
        var listeners: [Int: @Sendable (LifecycleEvent) -> Void] = [:]
    }

    // Guarded by `state`; listeners are called outside the lock.
    private let state: Locked<State>

    package init(foreground: Bool = false, protectedDataAvailable: Bool = true) {
        state = Locked(State(foreground: foreground, protectedData: protectedDataAvailable))
    }

    package var starts: Int { state.current.starts }
    package var isForeground: Bool { state.current.foreground }
    package var isProtectedDataAvailable: Bool { state.current.protectedData }

    package func start() {
        state.withLock { $0.starts += 1 }
    }

    package func addListener(_ listener: @escaping @Sendable (LifecycleEvent) -> Void) -> any ListenerToken {
        let id: Int = state.withLock { s in
            s.nextId += 1
            s.listeners[s.nextId] = listener
            return s.nextId
        }
        return ListenerHandle { [state] in state.withLock { _ = $0.listeners.removeValue(forKey: id) } }
    }

    package func moveToForeground() {
        emit(.foreground) { s in
            if s.foreground { return false }
            s.foreground = true
            return true
        }
    }

    package func moveToBackground() {
        emit(.background) { s in
            if !s.foreground { return false }
            s.foreground = false
            return true
        }
    }

    /// What the platform does for a listener added while the app is already visible: the
    /// foreground is reported again without a state change.
    package func replayForeground() {
        emit(.foreground) { _ in true }
    }

    package func terminate() {
        emit(.willTerminate) { _ in true }
    }

    package func lockProtectedData() {
        emit(.protectedDataWillBecomeUnavailable) { s in
            if !s.protectedData { return false }
            s.protectedData = false
            return true
        }
    }

    package func unlockProtectedData() {
        emit(.protectedDataDidBecomeAvailable) { s in
            if s.protectedData { return false }
            s.protectedData = true
            return true
        }
    }

    private func emit(_ event: LifecycleEvent, if change: (inout State) -> Bool) {
        let listeners: [@Sendable (LifecycleEvent) -> Void]? = state.withLock { s in
            change(&s) ? Array(s.listeners.values) : nil
        }
        for listener in listeners ?? [] { listener(event) }
    }
}

/// A `ContextProvider` that returns what the test set and records the disabled fields it was given.
/// It leaves out those fields itself, as the real provider never reads them (Context 6).
package final class FakeContextProvider: ContextProvider, @unchecked Sendable {
    private struct State {
        var staticValues: StaticValues
        var callTimeValues: CallTimeValues
        var pendingUntilRefresh: Bool
        var staticReads = 0
        var callTimeReads = 0
        var refreshes = 0
        var lastDisabled: Set<ContextField> = []
    }

    // Guarded by `state`.
    private let state: Locked<State>

    package init(
        staticValues: StaticValues = .none, callTimeValues: CallTimeValues = .none,
        pendingUntilRefresh: Bool = false
    ) {
        state = Locked(
            State(staticValues: staticValues, callTimeValues: callTimeValues, pendingUntilRefresh: pendingUntilRefresh))
    }

    package var staticValues: StaticValues {
        get { state.current.staticValues }
        set { state.withLock { $0.staticValues = newValue } }
    }

    package var callTimeValues: CallTimeValues {
        get { state.current.callTimeValues }
        set { state.withLock { $0.callTimeValues = newValue } }
    }

    package var staticReads: Int { state.current.staticReads }
    package var callTimeReads: Int { state.current.callTimeReads }
    package var refreshes: Int { state.current.refreshes }
    /// The disabled fields of the last read.
    package var lastDisabled: Set<ContextField> { state.current.lastDisabled }

    package func staticValues(disabled: Set<ContextField>) -> StaticValues {
        let v: StaticValues = state.withLock { s in
            s.staticReads += 1
            s.lastDisabled = disabled
            return s.staticValues
        }
        func keep<T>(_ field: ContextField, _ value: T?) -> T? { disabled.contains(field) ? nil : value }
        return StaticValues(
            appName: keep(.appName, v.appName), appVersion: keep(.appVersion, v.appVersion),
            appBuild: keep(.appBuild, v.appBuild), appNamespace: keep(.appNamespace, v.appNamespace),
            deviceManufacturer: keep(.deviceManufacturer, v.deviceManufacturer),
            deviceModel: keep(.deviceModel, v.deviceModel), deviceType: keep(.deviceType, v.deviceType),
            deviceIsEmulator: keep(.deviceIsEmulator, v.deviceIsEmulator), osName: keep(.osName, v.osName),
            osVersion: keep(.osVersion, v.osVersion), screenWidth: keep(.screenWidth, v.screenWidth),
            screenHeight: keep(.screenHeight, v.screenHeight), screenDensity: keep(.screenDensity, v.screenDensity))
    }

    package func callTimeValues(disabled: Set<ContextField>) -> CallTimeValues {
        let (v, pending): (CallTimeValues, Bool) = state.withLock { s in
            s.callTimeReads += 1
            s.lastDisabled = disabled
            return (s.callTimeValues, s.pendingUntilRefresh && s.refreshes == 0)
        }
        if pending { return CallTimeValues(pending: true) }
        func keep<T>(_ field: ContextField, _ value: T?) -> T? { disabled.contains(field) ? nil : value }
        return CallTimeValues(
            networkType: keep(.networkType, v.networkType), locale: keep(.locale, v.locale),
            timezone: keep(.timezone, v.timezone))
    }

    package func refresh(disabled: Set<ContextField>) {
        state.withLock { s in
            s.refreshes += 1
            s.lastDisabled = disabled
        }
    }
}

/// Process facts the test sets.
package final class FakeProcessFacts: ProcessFacts, @unchecked Sendable {
    private struct State {
        var osVersion: String
        var appExtension: Bool
        var installed: InstalledApp?
    }

    // Guarded by `state`.
    private let state: Locked<State>

    package init(osVersion: String = "17.5.1", isAppExtension: Bool = false, installed: InstalledApp? = nil) {
        state = Locked(State(osVersion: osVersion, appExtension: isAppExtension, installed: installed))
    }

    package var osVersion: String { state.current.osVersion }
    package var isAppExtension: Bool { state.current.appExtension }

    package var installed: InstalledApp? {
        get { state.current.installed }
        set { state.withLock { $0.installed = newValue } }
    }

    package func installedApp() -> InstalledApp? {
        installed
    }
}

/// Returns scripted results in order and records every request. Once the script is used up it
/// returns `whenEmpty`.
package final class FakeTransport: HttpTransport, @unchecked Sendable {
    private struct State {
        var script: [HttpResult] = []
        var requests: [HttpRequest] = []
        var shutdowns = 0
    }

    private let whenEmpty: HttpResult
    // Guarded by `state`.
    private let state = Locked(State())

    package init(whenEmpty: HttpResult = .success(code: 200)) {
        self.whenEmpty = whenEmpty
    }

    /// The requests received so far, oldest first.
    package var requests: [HttpRequest] { state.current.requests }
    package var shutdowns: Int { state.current.shutdowns }

    package func enqueue(_ results: HttpResult...) {
        state.withLock { $0.script.append(contentsOf: results) }
    }

    package func execute(_ request: HttpRequest) -> HttpResult {
        state.withLock { s in
            s.requests.append(request)
            return s.script.isEmpty ? whenEmpty : s.script.removeFirst()
        }
    }

    package func shutdown() {
        state.withLock { $0.shutdowns += 1 }
    }
}
