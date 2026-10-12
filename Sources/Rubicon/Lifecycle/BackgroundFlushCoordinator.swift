import Foundation
import RubiconCore

#if canImport(UIKit)
    import UIKit
#endif

/// The platform's background task around the background flush (iOS Queue 2): `begin` on
/// `didEnterBackground`, `end` when the uploader reports the drain done, on `willEnterForeground`,
/// or from the expiration handler, which first cancels the request in flight (the batch stays on
/// disk and Retry records `cancelled`). Foreground uploads are not wrapped.
protocol BackgroundTaskRunner: Sendable {
    /// Begins a task named `name`; `onExpire` runs on the main thread when the system reclaims it.
    /// Returns `nil` when no task could be begun (an app extension, or `UIApplication` is absent).
    func begin(name: String, onExpire: @escaping @Sendable () -> Void) -> BackgroundTaskHandle?

    func end(_ handle: BackgroundTaskHandle)
}

struct BackgroundTaskHandle: Equatable, Sendable {
    let id: Int
}

// The open task is guarded by `task`; the lifecycle listener and the uploader's callback both end it.
final class BackgroundFlushCoordinator: @unchecked Sendable {
    static let taskName = "rubicon.flush"

    private let control: any BackgroundFlushControl
    private let lifecycle: any LifecycleSource
    private let runner: any BackgroundTaskRunner
    private let task = Locked<BackgroundTaskHandle?>(nil)
    private let token = Locked<(any ListenerToken)?>(nil)

    init(
        control: any BackgroundFlushControl, lifecycle: any LifecycleSource,
        runner: any BackgroundTaskRunner = UIKitBackgroundTaskRunner()
    ) {
        self.control = control
        self.lifecycle = lifecycle
        self.runner = runner
    }

    /// Starts listening; the writer's own listener, added at its startup, sends the flush. The
    /// listener holds the coordinator, so it lives as long as the lifecycle source, the instance.
    func attach() {
        let token = lifecycle.addListener { [self] event in
            switch event {
            case .background: beginTask()
            case .foreground: endTask()
            default: break
            }
        }
        self.token.withLock { $0 = token }
    }

    /// The open task, for tests.
    var isTaskOpen: Bool { task.current != nil }

    private func beginTask() {
        guard task.current == nil else { return }
        guard
            let handle = runner.begin(
                name: Self.taskName,
                onExpire: { [self] in
                    // The system is about to kill a task that is still running: stop the request now.
                    control.expireBackgroundFlush()
                    endTask()
                })
        else { return }
        task.withLock { $0 = handle }
        control.beginBackgroundFlush { [self] in endTask() }
    }

    private func endTask() {
        let open: BackgroundTaskHandle? = task.withLock { slot in
            defer { slot = nil }
            return slot
        }
        if let open { runner.end(open) }
    }
}

/// `UIApplication.beginBackgroundTask(withName:expirationHandler:)`; absent outside UIKit and in app
/// extensions, where the factory never gets here.
struct UIKitBackgroundTaskRunner: BackgroundTaskRunner {
    func begin(name: String, onExpire: @escaping @Sendable () -> Void) -> BackgroundTaskHandle? {
        #if canImport(UIKit)
            guard !Bundle.main.bundlePath.hasSuffix(".appex") else { return nil }
            let identifier: UIBackgroundTaskIdentifier = run {
                UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: onExpire)
            }
            return identifier == .invalid ? nil : BackgroundTaskHandle(id: identifier.rawValue)
        #else
            return nil
        #endif
    }

    func end(_ handle: BackgroundTaskHandle) {
        #if canImport(UIKit)
            run { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: handle.id)) }
        #endif
    }

    #if canImport(UIKit)
        // Both calls are main-actor isolated; the notification thread is the main thread, and the
        // uploader's callback hops there and waits, which is a few microseconds on an idle main queue.
        private func run<T: Sendable>(_ body: @MainActor () -> T) -> T {
            if Thread.isMainThread {
                return MainActor.assumeIsolated { body() }
            }
            return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
        }
    #endif
}
