import Foundation
import RubiconCore

#if canImport(UIKit)
    import UIKit
#endif

/// What the application tells the core (iOS Session 1, iOS Queue 2, iOS Disk 1), from the
/// `UIApplication` notifications observed on the main thread:
///
/// - protected data going away and coming back (the device locking with `complete` files, or a
///   process started before the first unlock), with `isProtectedDataAvailable` read at startup on
///   the main thread; off the main thread it is assumed available, and a locked file then shows up
///   as a permission error the stores treat as locked;
/// - `willTerminate`, a rare final chance to write the stores;
/// - the foreground pair, `willEnterForeground` and `didEnterBackground`, never the `active` pair,
///   with `applicationState` read at startup on the main thread: `.active` or `.inactive` is the
///   foreground at once, `.background` waits (iOS Session 1).
///
/// `attach()` is called by the factory for a new instance; `start()` is the writer's and does
/// nothing here, since the observers are registered on the main thread by `attach()`.
// The state is a `Locked` value; listeners are called outside the lock on the notification thread.
final class ApplicationLifecycleSource: LifecycleSource, @unchecked Sendable {
    private struct State {
        var foreground = false
        var protectedData = true
        var attached = false
        var nextId = 0
        var listeners: [Int: @Sendable (LifecycleEvent) -> Void] = [:]
    }

    private let center: NotificationCenter
    private let state = Locked(State())
    private let observers = Locked<[NSObjectProtocol]>([])

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    deinit {
        for observer in observers.current { center.removeObserver(observer) }
    }

    var isForeground: Bool { state.current.foreground }

    var isProtectedDataAvailable: Bool { state.current.protectedData }

    func start() {}

    func addListener(_ listener: @escaping @Sendable (LifecycleEvent) -> Void) -> any ListenerToken {
        let id: Int = state.withLock { s in
            s.nextId += 1
            s.listeners[s.nextId] = listener
            return s.nextId
        }
        return Handle { [state] in state.withLock { _ = $0.listeners.removeValue(forKey: id) } }
    }

    /// Registers the observers, on the main thread: at once when called there, else posted without
    /// waiting (Public API 9). Idempotent.
    func attach() {
        if Thread.isMainThread {
            register()
        } else {
            DispatchQueue.main.async { [self] in register() }
        }
    }

    private func register() {
        guard
            state.withLock({ s in
                if s.attached { return false }
                s.attached = true
                return true
            })
        else { return }
        #if canImport(UIKit)
            readInitialState()
            observe(UIApplication.willEnterForegroundNotification) { [weak self] in
                self?.change(.foreground) { $0.foreground = true }
            }
            observe(UIApplication.didEnterBackgroundNotification) { [weak self] in
                self?.change(.background) { $0.foreground = false }
            }
            observe(UIApplication.protectedDataWillBecomeUnavailableNotification) { [weak self] in
                self?.change(.protectedDataWillBecomeUnavailable) { $0.protectedData = false }
            }
            observe(UIApplication.protectedDataDidBecomeAvailableNotification) { [weak self] in
                self?.change(.protectedDataDidBecomeAvailable) { $0.protectedData = true }
            }
            observe(UIApplication.willTerminateNotification) { [weak self] in
                self?.emit(.willTerminate)
            }
        #endif
    }

    #if canImport(UIKit)
        // On the main thread, in an app: `UIApplication.shared` is unavailable in an extension, where
        // the factory never gets here (iOS Queue 2).
        // The startup read of iOS Session 1: `.active` or `.inactive` is the foreground, reported at
        // once; `.background` waits for the first `willEnterForeground`. Off the main thread nothing
        // is read and the app is assumed to be in the background until a notification arrives.
        private func readInitialState() {
            guard Thread.isMainThread, !Bundle.main.bundlePath.hasSuffix(".appex") else { return }
            // `register` runs on the main thread (checked above), which is what the actor requires.
            let (foreground, available) = MainActor.assumeIsolated {
                (
                    Self.isForeground(UIApplication.shared.applicationState),
                    UIApplication.shared.isProtectedDataAvailable
                )
            }
            state.withLock { $0.protectedData = available }
            if foreground { change(.foreground) { $0.foreground = true } }
        }

        static func isForeground(_ applicationState: UIApplication.State) -> Bool {
            applicationState != .background
        }

        private func observe(_ name: Notification.Name, _ handler: @escaping @Sendable () -> Void) {
            let observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in handler() }
            observers.withLock { $0.append(observer) }
        }
    #endif

    // A real change only: the same state twice tells nobody.
    private func change(_ event: LifecycleEvent, _ apply: @escaping (inout State) -> Void) {
        let changed: Bool = state.withLock { s in
            let before = (s.foreground, s.protectedData)
            apply(&s)
            return before != (s.foreground, s.protectedData)
        }
        if changed { emit(event) }
    }

    private func emit(_ event: LifecycleEvent) {
        let listeners = state.current.listeners.values
        for listener in listeners { listener(event) }
    }

    private struct Handle: ListenerToken {
        let remove: @Sendable () -> Void

        func cancel() { remove() }
    }
}
